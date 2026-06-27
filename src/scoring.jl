mutable struct Embedding
    text::String
    vecpath::String
    handle::Union{Nothing,RustWorker.Model}
    lock::ReentrantLock
end

# The model (and its query encoding) is loaded once, lazily, on first scoring — so a stage that
# receives no candidates never touches the network. Double-checked locking keeps it thread-safe.
function handle!(source::Embedding)
    isnothing(source.handle) || return source.handle
    lock(source.lock) do
        isnothing(source.handle) && (source.handle = RustWorker.open(source.vecpath, source.text))
        source.handle
    end
end

function contentoffset(::Type{WET{U,C,L}}) where {U,C,L}
    # WET fields: 1=uri, 2=content, 3=languages, 4=date, 5=length, 6=score
    # Snippet fields: 1=bytes, 2=length
    fieldoffset(WET{U,C,L}, 2) + fieldoffset(Snippet{C}, 1)
end

# Largest length <= len that ends on a UTF-8 character boundary, for a raw content pointer.
function utf8boundary(ptr::Ptr{UInt8}, len::Integer)
    len <= 0 && return 0
    start = len
    while start > 0 && (unsafe_load(ptr, start) & 0xc0) == 0x80
        start -= 1
    end
    start == 0 && return len
    lead = unsafe_load(ptr, start)
    (lead & 0x80) == 0 && return len
    needed = (lead & 0xe0) == 0xc0 ? 2 :
             (lead & 0xf0) == 0xe0 ? 3 :
             (lead & 0xf8) == 0xf0 ? 4 : 1
    len - start + 1 < needed ? start - 1 : len
end

embedding(text::AbstractString; vecpath="minishlab/potion-multilingual-128M") = Embedding(String(text), String(vecpath), nothing, ReentrantLock())
embedding(uri::URI; vecpath="minishlab/potion-multilingual-128M") = embedding(plaintext(uri); vecpath)

distance(first::Embedding, second::AbstractString) = RustWorker.score(second, handle!(first))
distance(first::Embedding, second::Embedding) = distance(first, second.text)

function distance(source::Embedding, wet::WET{U,C,L}) where {U,C,L}
    scores = Float64[0.0]
    pointers = UInt[0]
    lengths = UInt[0]
    reference = Ref(wet)

    GC.@preserve reference pointers lengths scores begin
        ptr = Base.unsafe_convert(Ptr{WET{U,C,L}}, reference) + contentoffset(WET{U,C,L})
        pointers[firstindex(pointers)] = UInt(ptr)
        lengths[firstindex(lengths)] = utf8boundary(Ptr{UInt8}(ptr), wet.content.length)
        RustWorker.score!(scores, pointers, lengths, handle!(source))
    end

    first(scores)
end

score(source::Embedding, wet::WET) = rescore(wet, distance(source, wet))

distance(string1::AbstractString, string2::AbstractString; vecpath="minishlab/potion-multilingual-128M") =
    distance(embedding(string1; vecpath), string2)

similarity(first::Embedding, second::AbstractString) = 1.0 - distance(first, second)
similarity(first::Embedding, second::Embedding) = 1.0 - distance(first, second)
similarity(first::Embedding, wet::WET) = 1.0 - distance(first, wet)
similarity(string1::AbstractString, string2::AbstractString; vecpath="minishlab/potion-multilingual-128M") =
    similarity(embedding(string1; vecpath), string2)

isrelevant(first::Embedding, second::AbstractString; threshold=0.6) = similarity(first, second) >= threshold
isrelevant(first::Embedding, second::Embedding; threshold=0.6) = similarity(first, second) >= threshold
isrelevant(first::Embedding, wet::WET; threshold=0.6) = similarity(first, wet) >= threshold
isrelevant(text::AbstractString, second::Embedding; threshold=0.6) = isrelevant(second, text; threshold)

function isrelevant(string1::AbstractString, string2::AbstractString; threshold=0.6, vecpath="minishlab/potion-multilingual-128M")
    similarity(string1, string2; vecpath) >= threshold
end

# `scratch` is a reusable box: writing the by-value WET into it lets us take a pointer to its
# inline content without allocating a fresh box per call. The hot loop owns one scratch and
# reuses it across every record; the convenience method allocates one per call.
function score(entry::AC, wet::WET{U,C,L}, scratch::Base.RefValue{WET{U,C,L}}) where {U,C,L}
    scratch[] = wet
    GC.@preserve scratch begin
        ptr = Ptr{UInt8}(Base.unsafe_convert(Ptr{WET{U,C,L}}, scratch) + contentoffset(WET{U,C,L}))
        score(entry, ptr, utf8boundary(ptr, wet.content.length))
    end
end
score(entry::AC, wet::WET{U,C,L}) where {U,C,L} = score(entry, wet, Ref{WET{U,C,L}}())

function score!(scores, pointers, lengths, source::Embedding, batch::AbstractVector{T}) where {T<:WET}
    resize!(scores, length(batch))
    resize!(pointers, length(batch))
    resize!(lengths, length(batch))

    # WETs are isbits, so the batch stores them inline — point straight at each one, no per-element box.
    GC.@preserve batch pointers lengths scores begin
        foreach(eachindex(batch)) do i
            ptr = Ptr{UInt8}(pointer(batch, i) + contentoffset(T))
            pointers[i] = UInt(ptr)
            lengths[i] = utf8boundary(ptr, batch[i].content.length)
        end

        RustWorker.score!(scores, pointers, lengths, handle!(source))
    end

    scores
end

