struct FastText
    path::String
    width::Int
    vectors::Dict{String,Union{Nothing,Vector{Float32}}}
end

const fasttexts = Dict{String,FastText}()

tokenize(text::AbstractString) = [String(match.match) for match in eachmatch(r"[[:word:]]+", lowercase(text))]

resolve(path::AbstractString) = isfile(path) ? path : joinpath(dirname(@__DIR__), path)

function fasttext(path::AbstractString)
    get!(fasttexts, resolve(path)) do
        open(resolve(path)) do file
            count, width = split(readline(file))
            FastText(resolve(path), parse(Int, width), Dict{String,Union{Nothing,Vector{Float32}}}())
        end
    end
end

function cache!(model::FastText, tokens)
    pending = Set(token for token in tokens if !haskey(model.vectors, token))
    isempty(pending) && return model

    open(model.path) do file
        readline(file)
        while !eof(file) && !isempty(pending)
            line = readline(file)
            stop = findfirst(' ', line)
            isnothing(stop) && continue
            token = line[firstindex(line):prevind(line, stop)]
            token ∈ pending || continue
            values = split(line[nextind(line, stop):end])
            model.vectors[token] = parse.(Float32, values)
            delete!(pending, token)
        end
    end

    model.vectors[token] = nothing for token in pending
    model
end

function embedding(text::AbstractString, model::FastText)
    tokens = tokenize(text)
    cache!(model, tokens)
    values = Vector{Vector{Float32}}()

    for token in tokens
        entry = model.vectors[token]
        isnothing(entry) || push!(values, entry)
    end

    isempty(values) && return zeros(Float32, model.width)
    sum(values) ./ length(values)
end

similarity(string1::AbstractString, string2::AbstractString, model::FastText) =
    dot(embedding(string1, model), embedding(string2, model)) /
    (norm(embedding(string1, model)) * norm(embedding(string2, model)) + eps())

function isrelevant(string1::AbstractString, string2::AbstractString; threshold=0.6, vecpath="data/wiki-news-300d-1M.vec")
    similarity(string1, string2, fasttext(vecpath)) >= threshold
end
