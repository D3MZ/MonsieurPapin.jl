seed(urls::Vector{<:AbstractString}) = join(filter(page -> !isempty(page), fetchtext.(urls)), "\n\n")
query(page::AbstractString; limit=2_000) = first(page, min(limit, length(page)))
normalize(page::AbstractString) = lowercase(Base.Unicode.normalize(page, :NFKC))
tokens(page::AbstractString) = [entry.match for entry in eachmatch(r"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]|[\p{L}\p{N}]+", normalize(page))]

function counts(page::AbstractString)
    counter = Dict{String,Int}()
    foreach(tokens(page)) do token
        counter[token] = get(counter, token, 0) + 1
    end
    counter
end

function weights(page::AbstractString; capacity=128)
    entries = collect(counts(page))
    k = min(capacity, length(entries))
    ranked = partialsort!(entries, 1:k; by=entry -> (-last(entry), first(entry)))
    Dict(first(entry) => 1 / sqrt(last(entry)) for entry in ranked[1:k])
end
