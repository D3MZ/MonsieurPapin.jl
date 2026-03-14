struct Embedding
    model::String
    text::String
    handle::RustWorker.Model
end

contentoffset(::Type{T}) where {T<:WET} = fieldoffset(T, 2) + fieldoffset(fieldtype(T, 2), 1)

function embedding(text::AbstractString, model::AbstractString)
    value = String(text)
    source = String(model)
    Embedding(source, value, RustWorker.open(source, value))
end

embedding(text::AbstractString; vecpath="minishlab/potion-multilingual-128M") = embedding(text, vecpath)

distance(first::Embedding, second::AbstractString) = RustWorker.score(second, first.handle)
distance(first::Embedding, second::Embedding) = distance(first, second.text)

function distance(source::Embedding, wet::WET)
    scores = Float64[0.0]
    pointers = UInt[0]
    lengths = UInt[0]
    reference = Ref(wet)

    GC.@preserve reference pointers lengths scores begin
        pointers[firstindex(pointers)] = UInt(Base.unsafe_convert(Ptr{typeof(wet)}, reference)) + contentoffset(typeof(wet))
        lengths[firstindex(lengths)] = wet.content.length
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

function RustWorker.ismatch(entry::Union{RustWorker.AC, RustWorker.DAAC}, wet::WET)
    reference = Ref(wet)
    GC.@preserve reference begin
        ptr = Base.unsafe_convert(Ptr{UInt8}, reference) + contentoffset(typeof(wet))
        RustWorker.ismatch(entry, ptr, wet.content.length)
    end
end

score(source::Embedding, wet::WET) = update(distance(source, wet), wet)

function score!(scores, pointers, lengths, source::Embedding, batch)
    resize!(scores, length(batch))
    resize!(pointers, length(batch))
    resize!(lengths, length(batch))
    references = Ref.(batch)

    GC.@preserve references pointers lengths scores begin
        foreach(eachindex(batch)) do i
            pointers[i] = UInt(Base.unsafe_convert(Ptr{typeof(batch[i])}, references[i])) + contentoffset(typeof(batch[i]))
            lengths[i] = batch[i].content.length
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
