Base.@kwdef mutable struct Configuration
    crawlpath = URI("https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz")
    crawlroot::String = "https://data.commoncrawl.org/"
    capacity::Int = Threads.nthreads() * 10
    threshold::Float64 = 0.6
    vecpath::String = "minishlab/potion-multilingual-128M"
    query::String = ""
    keywords::Vector{String} = String[]
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
        # Use existing gettext for cleaner extraction
        return gettext(String(response.body))
    catch e
        @warn "Failed to fetch $url: $e"
        return ""
    end
end

function bootstrap(config::Configuration, urls::Vector{<:AbstractString}, task::AbstractString)
    @info "Bootstrapping crawl from seed URLs..." urls
    seeds_text = join([fetchseed(url) for url in urls], "\n\n")
    
    # Analyze task and seeds to get keywords and query
    analysis_prompt = """
    Analyze the following Task and Seed Content.
    Produce a JSON object with two fields:
    1. "keywords": a list of 50 highly specific terms for keyword matching.
    2. "query": a 1-sentence semantic description of the target content.
    
    IMPORTANT: Do not include any thinking process. Do not use markdown. Output ONLY the raw JSON object.
    
    Task: $task
    
    Seed Content:
    $(first(seeds_text, 3000))
    """
    
    # We temporarily update config to call LLM for analysis
    # Use a simpler system prompt for this internal step
    analysis_config = deepcopy(config)
    analysis_config.systemprompt = "You are a technical analyst assistant. Output ONLY JSON."
    
    response_text = complete(analysis_prompt, analysis_config)
    
    try
        # Strip potential thinking or markdown from JSON
        clean_json = stripjson(response_text)
        @debug "Attempting to parse JSON" clean_json
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
wets(config::Configuration) = wets(weturis(config); capacity=config.capacity, wetroot=config.crawlroot)

function coarsefilter(config::Configuration, entries::Channel{<:WET})
    # Initialize Deduper and AC
    deduper = Deduper(config.dedupe_capacity)
    ac = isempty(config.keywords) ? nothing : AC(config.keywords)
    emb = embedding(config.query; vecpath=config.vecpath)
    
    # We wrap the channel to apply filters
    out = Channel{eltype(entries)}(config.capacity)
    
    Threads.@spawn begin
        try
            for wet in entries
                # 1. SimHash Dedupe
                isduplicate(deduper, wet) && continue
                
                # 2. Keyword Filter (AC)
                if !isnothing(ac)
                    ismatch(ac, wet) || continue
                end
                
                # 3. Semantic Filter (Embedding)
                if isrelevant(wet, emb; threshold=config.threshold)
                    put!(out, wet)
                end
            end
        finally
            close(out)
            !isnothing(ac) && close(ac)
        end
    end
    
    out
end

isrelevant(wet::WET, emb::Embedding; threshold=0.6) = distance(emb, wet) >= threshold

append!(file, output::AbstractString) = isempty(output) ? file : (write(file, output, "\n"); flush(file); file)

prompt(wet::WET, config::Configuration) = string("URI: ", uri(wet), "\nSCORE: ", wet.score, "\n\n", content(wet))

active(channel::Channel{<:WET}, shortlist::WETQueue, generation) =
    isopen(channel) || isready(channel) || !isempty(shortlist) || !isnothing(generation)

function ingest!(shortlist::WETQueue, channel::Channel{<:WET})
    while isready(channel)
        insert!(shortlist, take!(channel))
    end
    shortlist
end

summarize(config::Configuration, client, wet::WET) = Threads.@spawn complete(prompt(wet, config), client)

persist(generation::Nothing, file) = nothing
persist(generation::Task, file) = istaskdone(generation) ? (append!(file, fetch(generation)); nothing) : generation

launch(generation::Task, config::Configuration, client, shortlist::WETQueue) = generation
launch(generation::Nothing, config::Configuration, client, shortlist::WETQueue) =
    isempty(shortlist) ? nothing : summarize(config, client, best!(shortlist))

function idle(channel::Channel{<:WET}, shortlist::WETQueue, ::Nothing)
    isempty(shortlist) && isopen(channel) && !isready(channel) && wait(channel)
    yield()
end

function idle(channel::Channel{<:WET}, shortlist::WETQueue, generation::Task)
    isempty(shortlist) && !isopen(channel) && wait(generation)
    yield()
end

function run!(file, entries::Channel{<:WET}, config::Configuration, client, shortlist::WETQueue)
    generation = nothing
    while active(entries, shortlist, generation)
        generation = persist(generation, file)
        ingest!(shortlist, entries)
        generation = launch(generation, config, client, shortlist)
        idle(entries, shortlist, generation)
    end
    file
end

function report(config::Configuration, entries::Channel{<:WET}, client)
    shortlist = WETQueue(config.capacity, eltype(entries))
    open(config.outputpath, "a") do file
        run!(file, entries, config, client, shortlist)
        config.outputpath
    end
end

report(config::Configuration, entries::Channel{<:WET}) = report(config, entries, config)
queue(config::Configuration, entries::Channel{<:WET}) = Threads.@spawn report(config, entries)

function research(config::Configuration)
    entries = wets(config)
    filtered = coarsefilter(config, entries)
    queue(config, filtered)
end
