struct FastText
    width::Int
    vectors::Dict{String,Vector{Float32}}
end

struct Embedding
    source::FastText
    values::Vector{Float32}
end

const fasttexts = Dict{String,FastText}()

tokenize(text::AbstractString) = split(text)

resolve(path::AbstractString) = isfile(path) ? path : joinpath(dirname(@__DIR__), path)

function fasttext(path::AbstractString)
    get!(fasttexts, resolve(path)) do
        load(resolve(path))
    end
end

function load(path::AbstractString)
    open(path) do file
        header = split(readline(file))
        width = parse(Int, last(header))
        vectors = Dict{String,Vector{Float32}}()

        while !eof(file)
            row = split(readline(file))
            token = first(row)
            vectors[token] = parse.(Float32, row[2:end])
        end

        FastText(width, vectors)
    end
end

function embedding(text::AbstractString, model::FastText)
    vectors = Vector{Vector{Float32}}()

    for token in tokenize(text)
        haskey(model.vectors, token) && push!(vectors, model.vectors[token])
    end

    values = isempty(vectors) ? zeros(Float32, model.width) : sum(vectors) ./ length(vectors)
    Embedding(model, values)
end

embedding(text::AbstractString; vecpath="data/wiki-news-300d-1M.vec") = embedding(text, fasttext(vecpath))

function similarity(firstembedding::Embedding, secondembedding::Embedding)
    dot(firstembedding.values, secondembedding.values) /
    (norm(firstembedding.values) * norm(secondembedding.values) + eps())
end

function similarity(string1::AbstractString, string2::AbstractString, model::FastText)
    similarity(embedding(string1, model), embedding(string2, model))
end

distance(firstembedding::Embedding, secondembedding::Embedding) = 1.0 - similarity(firstembedding, secondembedding)
distance(source::Embedding, wet::WET) = distance(source, embedding(content(wet), source.source))

function isrelevant(firstembedding::Embedding, secondembedding::Embedding; threshold=0.6)
    similarity(firstembedding, secondembedding) >= threshold
end

function isrelevant(firstembedding::Embedding, text::AbstractString; threshold=0.6)
    isrelevant(firstembedding, embedding(text, firstembedding.source); threshold)
end

function isrelevant(text::AbstractString, secondembedding::Embedding; threshold=0.6)
    isrelevant(secondembedding, text; threshold)
end

isrelevant(source::Embedding, wet::WET; threshold=0.6) = isrelevant(source, content(wet); threshold)

score(source::Embedding, wet::WET) = scored(wet, distance(source, wet))

function relevant!(source::Embedding, pages::Channel{T}; capacity=Threads.nthreads() * 10, threshold=0.6) where {T<:WET}
    Channel{T}(capacity) do filtered
        Threads.foreach(pages) do wet
            candidate = score(source, wet)
            candidate.score <= 1.0 - threshold && put!(filtered, candidate)
        end
    end
end

function isrelevant(string1::AbstractString, string2::AbstractString; threshold=0.6, vecpath="data/wiki-news-300d-1M.vec")
    similarity(string1, string2, fasttext(vecpath)) >= threshold
end
