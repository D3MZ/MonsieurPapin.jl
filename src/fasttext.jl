struct FastText
    path::String
    width::Int
    vectors::Dict{String,Vector{Float32}}
end

const fasttexts = Dict{String,FastText}()

tokenize(text::AbstractString) = [String(match.match) for match in eachmatch(r"[[:word:]]+", lowercase(text))]

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

        FastText(String(path), width, vectors)
    end
end

function embedding(text::AbstractString, model::FastText)
    vectors = Vector{Vector{Float32}}()

    for token in tokenize(text)
        haskey(model.vectors, token) && push!(vectors, model.vectors[token])
    end

    isempty(vectors) && return zeros(Float32, model.width)
    sum(vectors) ./ length(vectors)
end

function similarity(string1::AbstractString, string2::AbstractString, model::FastText)
    firstembedding = embedding(string1, model)
    secondembedding = embedding(string2, model)
    dot(firstembedding, secondembedding) / (norm(firstembedding) * norm(secondembedding) + eps())
end

function isrelevant(string1::AbstractString, string2::AbstractString; threshold=0.6, vecpath="data/wiki-news-300d-1M.vec")
    similarity(string1, string2, fasttext(vecpath)) >= threshold
end
