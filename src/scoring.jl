struct Embedding
    text::String
    handle::RustWorker.Model
end

function contentoffset(::Type{WET{U,C,L}}) where {U,C,L}
    # WET fields: 1=uri, 2=content, 3=languages, 4=date, 5=length, 6=score
    # Snippet fields: 1=bytes, 2=length
    fieldoffset(WET{U,C,L}, 2) + fieldoffset(Snippet{C}, 1)
end

function safe_length(ptr::Ptr{UInt8}, len::Int)
    len <= 0 && return 0
    last_start = len
    while last_start > 0 && (unsafe_load(ptr, last_start) & 0xc0) == 0x80
        last_start -= 1
    end
    if last_start > 0 && (unsafe_load(ptr, last_start) & 0x80) != 0
        b = unsafe_load(ptr, last_start)
        needed = (b & 0xe0) == 0xc0 ? 2 :
                 (b & 0xf0) == 0xe0 ? 3 :
                 (b & 0xf8) == 0xf0 ? 4 : 1
        if len - last_start + 1 < needed
            return last_start - 1
        end
    end
    return len
end

function embedding(text::AbstractString, model::AbstractString)
    value = String(text)
    source = String(model)
    Embedding(value, RustWorker.open(source, value))
end

embedding(text::AbstractString; vecpath="minishlab/potion-multilingual-128M") = embedding(text, vecpath)
embedding(uri::URI; vecpath="minishlab/potion-multilingual-128M") = embedding(gettext(uri), vecpath)

distance(first::Embedding, second::AbstractString) = RustWorker.score(second, first.handle)
distance(first::Embedding, second::Embedding) = distance(first, second.text)

function distance(source::Embedding, wet::WET{U,C,L}) where {U,C,L}
    scores = Float64[0.0]
    pointers = UInt[0]
    lengths = UInt[0]
    reference = Ref(wet)

    GC.@preserve reference pointers lengths scores begin
        ptr = Base.unsafe_convert(Ptr{WET{U,C,L}}, reference) + contentoffset(WET{U,C,L})
        pointers[firstindex(pointers)] = UInt(ptr)
        lengths[firstindex(lengths)] = safe_length(Ptr{UInt8}(ptr), wet.content.length)
        RustWorker.score!(scores, pointers, lengths, source.handle)
    end

    first(scores)
end

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

function RustWorker.score(entry::RustWorker.AC, wet::WET{U,C,L}) where {U,C,L}
    reference = Ref(wet)
    GC.@preserve reference begin
        ptr = Base.unsafe_convert(Ptr{WET{U,C,L}}, reference) + contentoffset(WET{U,C,L})
        RustWorker.score(entry, Ptr{UInt8}(ptr), safe_length(Ptr{UInt8}(ptr), wet.content.length))
    end
end

function score(source::Embedding, wet::WET)
    s = distance(source, wet)
    update(s, wet)
end

function score!(scores, pointers, lengths, source::Embedding, batch::AbstractVector{T}) where {T<:WET}
    resize!(scores, length(batch))
    resize!(pointers, length(batch))
    resize!(lengths, length(batch))
    references = Ref.(batch)

    GC.@preserve references pointers lengths scores begin
        foreach(eachindex(batch)) do i
            ptr = Base.unsafe_convert(Ptr{T}, references[i]) + contentoffset(T)
            pointers[i] = UInt(ptr)
            lengths[i] = safe_length(Ptr{UInt8}(ptr), batch[i].content.length)
        end

        RustWorker.score!(scores, pointers, lengths, source.handle)
    end

    scores
end

function publish!(filtered, batch, scores, threshold)
    foreach(eachindex(batch, scores)) do i
        candidate = update(scores[i], batch[i])
        candidate.score <= 1.0 - threshold && put!(filtered, candidate)
    end
    empty!(batch)
    filtered
end

function publish!(filtered, batch, scores, pointers, lengths, source, threshold)
    score!(scores, pointers, lengths, source, batch)
    publish!(filtered, batch, scores, threshold)
    filtered
end

function relevant!(source::Embedding, pages::Channel{T}; capacity=Threads.nthreads() * 10, threshold=0.6, batchsize=64) where {T<:WET}
    Channel{T}(capacity) do filtered
        tasks = [
            Threads.@spawn begin
                batch = T[]
                scores = Float64[]
                pointers = UInt[]
                lengths = UInt[]

                for wet in pages
                    push!(batch, wet)
                    length(batch) == batchsize || continue
                    publish!(filtered, batch, scores, pointers, lengths, source, threshold)
                end

                isempty(batch) || publish!(filtered, batch, scores, pointers, lengths, source, threshold)
            end
            for _ in 1:Threads.nthreads()
        ]
        foreach(wait, tasks)
    end
end
