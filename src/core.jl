loadsettings(path="settings.toml") = TOML.parsefile(path)

struct TokenWeights
    weights::Dict{String,Float64}
end

function fetchseed(url::AbstractString)
    try
        response = HTTP.get(String(url); timeout=30)
        return gettext(String(response.body))
    catch e
        @warn "Failed to fetch $url: $e"
        return ""
    end
end

seed(urls::Vector{<:AbstractString}) = join(filter(page -> !isempty(page), fetchseed.(urls)), "\n\n")
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
    ranked = sort!(collect(counts(page)); by=entry -> (-last(entry), first(entry)))
    limited = first(ranked, min(capacity, length(ranked)))
    TokenWeights(Dict(first(entry) => 1 / sqrt(last(entry)) for entry in limited))
end

function bootstrap(settings, urls::Vector{<:AbstractString}, task::AbstractString)
    @info "Bootstrapping crawl from seed URLs..." urls
    seeds_text = join([fetchseed(url) for url in urls], "\n\n")
    
    analysis_prompt = """
    Analyze the following Task and Seed Content.
    Produce a JSON object with two fields:
    1. "keywords": a list of 50 highly specific terms for keyword matching.
    2. "query": a 1-sentence semantic description of the target content.
    
    IMPORTANT: Do not include any thinking process. Do not use markdown. Output ONLY the raw JSON object.
    
    Task: $task
    
    Seed Content:
    $(first(seeds_text, 2000))
    """
    
    response = request(;
        model=settings["llm"]["model"],
        systemprompt="You are a technical analyst assistant. Output ONLY JSON.",
        input=analysis_prompt,
        baseurl=settings["llm"]["baseurl"],
        path=settings["llm"]["path"],
        password=settings["llm"]["password"],
        timeout=settings["llm"]["timeout"],
    )
    response_text = get_message(response)
    
    data = JSON.parse(response_text)
    settings["pipeline"]["keywords"] = convert(Vector{String}, data["keywords"])
    settings["pipeline"]["query"] = convert(String, data["query"])
    @info "Bootstrap complete." query=settings["pipeline"]["query"] keywords_count=length(settings["pipeline"]["keywords"])
end

# --- Pipeline Stages ---

"""
    harvest(settings, entries) -> Channel{WET}

Stage 1: High-speed deduplication and keyword matching.
Filters the raw stream down to candidates that contain target keywords.
"""
function harvest(settings, entries::Channel{<:WET})
    out = Channel{eltype(entries)}(settings["pipeline"]["capacity"])
    deduper = Deduper(settings["pipeline"]["dedupe_capacity"])
    keywords = settings["pipeline"]["keywords"]
    ac = isempty(keywords) ? nothing : AC(keywords)
    
    Threads.@spawn begin
        try
            for wet in entries
                isduplicate(deduper, wet) && continue
                
                if !isnothing(ac)
                    s = RustWorker.score(ac, wet)
                    s > 0 || continue
                    wet = update(Float64(s), wet)
                end
                
                put!(out, wet)
            end
        finally
            close(out)
            !isnothing(ac) && close(ac)
        end
    end
    out
end

function harvest(settings, entries::Channel{<:WET}, source::TokenWeights; capacity=10)
    shortlist = WETQueue(capacity, eltype(entries), ReverseOrdering(By(score)))
    isempty(source.weights) && return shortlist
    deduper = Deduper(settings["pipeline"]["dedupe_capacity"])
    ac = AC(source.weights)

    try
        for wet in entries
            isduplicate(deduper, wet) && continue
            value = RustWorker.score(ac, wet)
            value > 0 || continue
            insert!(shortlist, update(value, wet))
        end
    finally
        close(ac)
    end

    shortlist
end

"""
    semantic(settings, entries) -> WETQueue

Stage 2: Semantic scoring via embeddings.
Consumes from harvest and maintains a prioritized queue of the most relevant items.
"""
function semantic(settings, entries::Channel{<:WET})
    shortlist = WETQueue(settings["pipeline"]["capacity"], eltype(entries))
    emb = embedding(settings["pipeline"]["query"]; vecpath=settings["embedding"]["model"])
    
    filtered = relevant!(emb, entries; capacity=Threads.nthreads()*10, threshold=1.0-settings["pipeline"]["threshold"])
    for wet in filtered
        insert!(shortlist, wet)
    end
    shortlist
end

function semantic(settings, entries::WETQueue, text::AbstractString; capacity=10)
    shortlist = WETQueue(capacity, eltype(entries))
    isempty(entries) && return shortlist
    source = embedding(query(text); vecpath=settings["embedding"]["model"])

    while !isempty(entries)
        insert!(shortlist, score(source, best!(entries)))
    end

    shortlist
end

# --- Final Orchestration ---

append!(file, output::AbstractString) = isempty(output) ? file : (write(file, strip(output), "\n"); flush(file); file)

prompt(wet::WET) = string("URI: ", uri(wet), "\nLANGUAGE: ", language(wet), "\nSCORE: ", wet.score, "\n\n", content(wet))
prompt(wet::WET, ::Val{:local}) = string("SOURCE URL: ", uri(wet), "\nLANGUAGE: ", language(wet), "\nDISTANCE: ", wet.score, "\n\nPAGE EXCERPT:\n", content(wet))

wetstream(settings) = wets(settings["crawl"]["path"]; capacity=settings["pipeline"]["capacity"], wetroot=settings["crawl"]["root"], languages=settings["crawl"]["languages"])

function research(settings)
    raw_wets = wetstream(settings)
    candidates = harvest(settings, raw_wets)
    
    Threads.@spawn begin
        open(settings["output"]["path"], "a") do file
            shortlist = semantic(settings, candidates)
            
            @info "Crawl exhausted. Extracting top results..." count=length(shortlist)
            
            while !isempty(shortlist)
                best_wet = best!(shortlist)
                @info "Analyzing high-relevance page" uri=uri(best_wet) score=best_wet.score
                response = request(;
                    model=settings["llm"]["model"],
                    systemprompt=settings["prompts"]["system"],
                    input=string(settings["prompts"]["input"], "\n\n", prompt(best_wet)),
                    baseurl=settings["llm"]["baseurl"],
                    path=settings["llm"]["path"],
                    password=settings["llm"]["password"],
                    timeout=settings["llm"]["timeout"],
                )
                append!(file, get_message(response))
            end
        end
        @info "Research complete."
    end
end

function research(settings, urls::Vector{<:AbstractString}, wetpath::AbstractString)
    Threads.@spawn begin
        source = seed(urls)
        candidates = harvest(settings, wets(wetpath; capacity=settings["pipeline"]["capacity"], languages=settings["crawl"]["languages"]), weights(source))
        retained = length(candidates)
        shortlist = semantic(settings, candidates, source)
        entries = length(shortlist)

        open(settings["output"]["path"], "w") do file
            @info "Local research shortlist ready." candidates=retained entries=entries outputpath=settings["output"]["path"]
            while !isempty(shortlist)
                wet = best!(shortlist)
                @info "Analyzing local page" uri=uri(wet) score=wet.score
                response = request(;
                    model=settings["llm"]["model"],
                    systemprompt=settings["prompts"]["local_system"],
                    input=string(settings["prompts"]["local_input"], "\n\n", prompt(wet, Val(:local))),
                    baseurl=settings["llm"]["baseurl"],
                    path=settings["llm"]["path"],
                    password=settings["llm"]["password"],
                    timeout=settings["llm"]["timeout"],
                )
                append!(file, get_message(response))
            end
        end

        @info "Local research complete." outputpath=settings["output"]["path"] entries=entries
    end
end