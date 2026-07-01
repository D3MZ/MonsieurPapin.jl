# Embedding scoring, backed by the native-Julia Model2Vec.jl package
# (https://github.com/D3MZ/Model2Vec.jl). This replaces the former Rust FFI path (RustWorker.jl
# -> deps/model2vec_rs_worker): it is faster and (for WordPiece models) allocation-free — see
# test/benchmarks.jl's "Model2Vec head-to-head" test, which is what justified the switch and now
# guards against regression. The Rust worker binary itself is left in place (used only by that
# test's direct comparison, not by production code), mirroring how src/ahocorasick.jl already
# stopped calling into Rust while the shared worker stuck around for the AC head-to-head test.
import Model2Vec
const _M2V = Model2Vec

mutable struct Embedding
    text::String
    vecpath::String
    model::Union{Nothing,_M2V.StaticModel}
    scratch::Any # concrete Model2Vec.Scratch subtype, set alongside `model`
    queryvec::Union{Nothing,Vector{Float32}}
    lock::ReentrantLock
end

# `Model2Vec.load` only reads local model2vec snapshot directories (no HF download) -- resolve a
# "org/repo" vecpath to its already-cached local snapshot, erroring clearly rather than silently
# falling back to a network fetch.
function hubsnapshot(repo::AbstractString)
    base = joinpath(homedir(), ".cache", "huggingface", "hub", "models--" * replace(repo, "/" => "--"), "snapshots")
    isdir(base) || error("scoring.jl: $repo not found in local HF cache ($base); download it first")
    snaps = readdir(base)
    isempty(snaps) && error("scoring.jl: $repo's snapshot directory is empty ($base)")
    joinpath(base, first(snaps))
end

# The model (and its query encoding) is loaded once, lazily, on first scoring — so a stage that
# receives no candidates never touches disk. Double-checked locking keeps it thread-safe.
function handle!(source::Embedding)
    isnothing(source.model) || return source
    lock(source.lock) do
        if isnothing(source.model)
            model = _M2V.load(hubsnapshot(source.vecpath))
            # cosinedistance below assumes unit-norm embeddings (dot product == cosine similarity)
            model.normalize || error("scoring.jl: $(source.vecpath) has normalize=false; cosinedistance's dot-product shortcut requires unit-norm embeddings")
            scratch = _M2V.Scratch(model)
            source.model = model
            source.scratch = scratch
            source.queryvec = copy(_M2V.encode!(scratch, model, source.text))
        end
    end
    source
end

@inline function cosinedistance(query::Vector{Float32}, candidate::AbstractVector{Float32})
    dot = 0.0
    @inbounds for k in eachindex(query, candidate)
        dot += Float64(query[k]) * Float64(candidate[k])
    end
    # Embeddings are L2-normalized by model2vec (config normalize=true, asserted in handle!), so
    # ||query||=||candidate||=1 and the dot product alone is the cosine similarity.
    1.0 - dot
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

embedding(text::AbstractString; vecpath="minishlab/potion-multilingual-128M") = Embedding(String(text), String(vecpath), nothing, nothing, nothing, ReentrantLock())
embedding(uri::URI; vecpath="minishlab/potion-multilingual-128M") = embedding(plaintext(uri); vecpath)

function distance(first::Embedding, second::AbstractString)
    handle!(first)
    v = _M2V.encode!(first.scratch, first.model, second)
    cosinedistance(first.queryvec, v)
end
distance(first::Embedding, second::Embedding) = distance(first, second.text)

# Zero-copy: builds a StringView directly over the WET's inline content bytes (no String
# materialized) in the common case. `utf8boundary` only fixes the truncation tail; crawled WET
# content can still carry interior invalid UTF-8 (mojibake/mixed encodings — see wets.jl's
# `decode`), which the Unigram backend's Unicode.normalize call cannot tolerate, so fall back to
# the sanitized, allocating `content(wet)` for the rare record where that matters.
function distance(source::Embedding, wet::WET{U,C,L}) where {U,C,L}
    handle!(source)
    reference = Ref(wet)
    result = GC.@preserve reference begin
        ptr = Ptr{UInt8}(Base.unsafe_convert(Ptr{WET{U,C,L}}, reference) + contentoffset(WET{U,C,L}))
        len = utf8boundary(ptr, wet.content.length)
        text = StringViews.StringView(unsafe_wrap(Vector{UInt8}, ptr, len))
        if isvalid(text)
            v = _M2V.encode!(source.scratch, source.model, text)
            cosinedistance(source.queryvec, v)
        else
            nothing
        end
    end
    result === nothing || return result
    v = _M2V.encode!(source.scratch, source.model, content(wet))
    cosinedistance(source.queryvec, v)
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

# `scratch` is explicit (not `source.scratch`) because `Model2Vec.Scratch` is a mutable buffer
# meant for sequential reuse by one caller — concurrent callers (e.g. `select`/`embed!` in
# core.jl, which spawns several worker tasks against one shared `Embedding`) must each pass their
# own scratch, or they'll race on the same buffer. `handle!(source)` still loads `source.model`
# once (read-only after that, safe to share).
function score!(scores, pointers, lengths, source::Embedding, batch::AbstractVector{T}, scratch) where {T<:WET}
    handle!(source)
    resize!(scores, length(batch))
    resize!(pointers, length(batch)) # unused by the native path; kept so callers don't need to change
    resize!(lengths, length(batch))

    GC.@preserve batch begin
        @inbounds for i in eachindex(batch, scores)
            ptr = Ptr{UInt8}(pointer(batch, i) + contentoffset(T))
            len = utf8boundary(ptr, batch[i].content.length)
            text = StringViews.StringView(unsafe_wrap(Vector{UInt8}, ptr, len))
            scores[i] = if isvalid(text)
                v = _M2V.encode!(scratch, source.model, text)
                cosinedistance(source.queryvec, v)
            else
                v = _M2V.encode!(scratch, source.model, content(batch[i]))
                cosinedistance(source.queryvec, v)
            end
        end
    end

    scores
end

# Convenience overload for single-threaded callers: uses `source`'s own scratch (safe as long as
# `source` isn't shared across concurrent tasks — see the explicit-scratch method above).
score!(scores, pointers, lengths, source::Embedding, batch::AbstractVector{<:WET}) =
    (handle!(source); score!(scores, pointers, lengths, source, batch, source.scratch))
