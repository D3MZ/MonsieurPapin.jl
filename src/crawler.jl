using HTTP
using Gumbo
using Cascadia
using Unicode
using WordTokenizers
using DataStructures

struct TokenWeights
    language::Symbol
    weights::Dict{String,Float64}
end

struct CrawlSpec
    url::String
    lang::Symbol
end


"download page"
function crawl(url::String)::Union{Missing,String}
    try
        response = HTTP.get(url)
        response.status == 200 || return missing
        String(response.body)
    catch
        missing
    end
end

"extract visible text from html"
function text(html::String)::String
    parsed = parsehtml(html)

    selector = Selector("body")
    nodes = eachmatch(selector, parsed.root)

    buffer = IOBuffer()

    for node in nodes
        for child in Gumbo.children(node)
            write(buffer, Gumbo.text(child))
            write(buffer, ' ')
        end
    end

    Unicode.normalize(String(take!(buffer)), :NFKC)
end

"latin script tokenizer"
function latinwords(s::String)
    collect(tokenize(s))
end

"fallback CJK segmentation"
function cjkwords(s::String)
    collect(eachmatch(r"[\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]", s)) .|> m -> m.match
end

"script-aware tokenization (language provided)"
function words(s::String, lang::Symbol)::Vector{String}
    s = Unicode.normalize(s, :NFKC)

    if lang in (:zh, :ja, :ko)
        cjkwords(s)
    else
        latinwords(s)
    end
end

"normalize tokens"
function normalize(tokens::Vector{String})
    tokens = lowercase.(tokens)
    filter!(t -> !isempty(t), tokens)
    tokens
end

"inverse normalized frequency weights"
function weights(tokens)::Dict{String,Float64}
    counter = DefaultDict{String,Int}(0)

    for t in tokens
        counter[t] += 1
    end

    scores = Dict{String,Float64}()

    for (word, count) in counter
        scores[word] = 1 / sqrt(count)
    end

    scores
end

function TokenWeights(spec::CrawlSpec)
    html = crawl(spec.url)
    html === missing && return missing

    body = text(html)
    tokens = normalize(words(body, spec.lang))
    w = weights(tokens)
    
    TokenWeights(spec.lang, w)
end