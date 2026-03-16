Base.@kwdef mutable struct Configuration
    crawlpath = URI("https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz")
    crawlroot::String = "https://data.commoncrawl.org/"
    capacity::Int = Threads.nthreads() * 10
    threshold::Float64 = 0.6
    vecpath::String = "minishlab/potion-multilingual-128M"
    query::String = ""
    keywords::Vector{String} = String[]
    languages::Vector{String} = ["eng", "deu", "rus", "jpn", "zho", "spa", "fra", "por", "ita", "pol"]
    dedupe_capacity::Int = 100_000
    baseurl::String = "http://localhost:1234"
    path::String = "/api/v1/chat"
    model::String = "qwen/qwen3.5-35b-a3b"
    password::String = ""
    systemprompt::String = "If a trading strategy exists then write a small description about it and the trading strategy as pseudo code wrapped in a code fence, otherwise do not output anything."
    input::String = "Evaluate this page excerpt for trading strategy relevance and follow the output rule."
    outputpath::String = "research.md"
    timeoutseconds::Int = 120
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

function bootstrap(config::Configuration, urls::Vector{<:AbstractString}, task::AbstractString)
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
    
    analysis_config = deepcopy(config)
    analysis_config.systemprompt = "You are a technical analyst assistant. Output ONLY JSON."
    
    response_text = complete(analysis_prompt, analysis_config)
    
    try
        clean_json = stripjson(response_text)
        data = JSON.parse(clean_json)
        config.keywords = convert(Vector{String}, data["keywords"])
        config.query = convert(String, data["query"])
        @info "Bootstrap complete." query=config.query keywords_count=length(config.keywords)
    catch e
        @error "Failed to parse bootstrap analysis: $e"
        @info "Raw response: $response_text"
    end
    
    config
end

weturis(config::Configuration) = wetURIs(config.crawlpath; capacity=config.capacity)
wets(config::Configuration) = wets(weturis(config); capacity=config.capacity, wetroot=config.crawlroot, languages=config.languages)

# --- Pipeline Stages ---

"""
    harvest(config, entries) -> Channel{WET}

Stage 1: High-speed deduplication and keyword matching.
Filters the raw stream down to candidates that contain target keywords.
"""
function harvest(config::Configuration, entries::Channel{<:WET})
    out = Channel{eltype(entries)}(config.capacity)
    deduper = Deduper(config.dedupe_capacity)
    ac = isempty(config.keywords) ? nothing : AC(config.keywords)
    
    Threads.@spawn begin
        try
            for wet in entries
                # 1. Dedupe
                isduplicate(deduper, wet) && continue
                
                # 2. Keyword score
                if !isnothing(ac)
                    # We store the match count in the score field for now
                    # A non-zero count is our filter
                    s = RustWorker.score(ac, wet)
                    s > 0 || continue
                    # Update wet with preliminary score
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

"""
    semantic(config, entries) -> WETQueue

Stage 2: Semantic scoring via embeddings.
Consumes from harvest and maintains a prioritized queue of the most relevant items.
"""
function semantic(config::Configuration, entries::Channel{<:WET})
    shortlist = WETQueue(config.capacity, eltype(entries))
    emb = embedding(config.query; vecpath=config.vecpath)
    
    # This stage runs until entries is closed
    for wet in entries
        # Score via embedding model (cosine similarity)
        s = distance(emb, wet)
        if s >= config.threshold
            insert!(shortlist, update(s, wet))
        end
    end
    shortlist
end

# --- Final Orchestration ---

append!(file, output::AbstractString) = isempty(output) ? file : (write(file, output, "\n"); flush(file); file)

prompt(wet::WET, config::Configuration) = string("URI: ", uri(wet), "\nLANGUAGE: ", language(wet), "\nSCORE: ", wet.score, "\n\n", content(wet))

function research(config::Configuration)
    raw_wets = wets(config)
    candidates = harvest(config, raw_wets)
    
    # We use a separate task for extraction so it can run while semantic stage buffers
    Threads.@spawn begin
        open(config.outputpath, "a") do file
            # In this refactored version, we process the stream in semantic stage
            # which returns a prioritized queue once the stream is exhausted.
            # However, for continuous extraction, we might want to pop from queue
            # as soon as it's "good enough".
            
            # For simplicity in this first staged version, we process the full stream:
            shortlist = semantic(config, candidates)
            
            @info "Crawl exhausted. Extracting top results..." count=length(shortlist)
            
            while !isempty(shortlist)
                best_wet = best!(shortlist)
                @info "Analyzing high-relevance page" uri=uri(best_wet) score=best_wet.score
                output = complete(prompt(best_wet, config), config)
                append!(file, output)
            end
        end
        @info "Research complete."
    end
end
