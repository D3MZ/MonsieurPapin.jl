using TOML

const _root = dirname(@__DIR__)  # package root

function _prompt(path::AbstractString)
    filepath = isabspath(path) ? path : joinpath(_root, path)
    isfile(filepath) ? read(filepath, String) : ""
end

# Helper: convert immutable struct to NamedTuple for keyword splatting
_kw(s::T) where {T} = NamedTuple{fieldnames(T)}(Tuple(getfield(s, f) for f in fieldnames(T)))

Base.@kwdef struct Crawl
    crawlpath::String = "https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
    crawlroot::String = "https://data.commoncrawl.org/"
    capacity::Int = Threads.nthreads() * 10
    languages::Vector{String} = ["eng", "deu", "rus", "jpn", "zho", "spa", "fra", "por", "ita", "pol"]
    dedupe_capacity::Int = 100_000
end

Base.@kwdef struct Search
    threshold::Float64 = 0.6
    vecpath::String = "minishlab/potion-multilingual-128M"
    query::String = ""
    keywords::Vector{String} = String[]
end

Base.@kwdef struct LLM
    baseurl::String = "http://localhost:1234"
    path::String = "/api/v1/chat"
    model::String = "qwen/qwen3.6-27b"
    password::String = ""
    timeoutseconds::Int = 120
end

Base.@kwdef struct Prompt
    systemprompt::String = _prompt("prompts/system.txt")
    input::String = _prompt("prompts/input.txt")
end

struct Settings
    crawl::Crawl
    search::Search
    llm::LLM
    prompt::Prompt
    outputpath::String
end

# --- Settings constructor ---

function _toml_path()
    path = joinpath(_root, "config.toml")
    isfile(path) ? path : nothing
end

function _settings_from_toml(data::Dict)
    c = get(data, "crawl", Dict{String,Any}())
    crawl = Crawl(;
        crawlpath = get(c, "crawlpath", Crawl().crawlpath),
        crawlroot = get(c, "crawlroot", Crawl().crawlroot),
        capacity = get(c, "capacity", 0) > 0 ? c["capacity"] : Crawl().capacity,
        languages = get(c, "languages", Crawl().languages),
        dedupe_capacity = get(c, "dedupe_capacity", Crawl().dedupe_capacity),
    )

    s = get(data, "search", Dict{String,Any}())
    search = Search(;
        threshold = get(s, "threshold", Search().threshold),
        vecpath = get(s, "vecpath", Search().vecpath),
        query = get(s, "query", Search().query),
        keywords = get(s, "keywords", Search().keywords),
    )

    l = get(data, "llm", Dict{String,Any}())
    llm = LLM(;
        baseurl = get(l, "baseurl", LLM().baseurl),
        path = get(l, "path", LLM().path),
        model = get(l, "model", LLM().model),
        password = get(l, "password", LLM().password),
        timeoutseconds = get(l, "timeoutseconds", LLM().timeoutseconds),
    )

    p = get(data, "prompt", Dict{String,Any}())
    prompt = Prompt(;
        systemprompt = haskey(p, "system_file") ? _prompt(p["system_file"]) :
                       get(p, "systemprompt", Prompt().systemprompt),
        input = haskey(p, "input_file") ? _prompt(p["input_file"]) :
                 get(p, "input", Prompt().input),
    )

    outputpath = get(data, "outputpath", "research.md")

    Settings(crawl, search, llm, prompt, outputpath)
end

function Settings(;
    crawl::Union{Crawl,Nothing} = nothing,
    search::Union{Search,Nothing} = nothing,
    llm::Union{LLM,Nothing} = nothing,
    prompt::Union{Prompt,Nothing} = nothing,
    outputpath::Union{String,Nothing} = nothing,
)
    path = _toml_path()
    base = path !== nothing ? _settings_from_toml(TOML.parsefile(path)) :
           Settings(Crawl(), Search(), LLM(), Prompt(), "research.md")

    Settings(
        something(crawl, base.crawl),
        something(search, base.search),
        something(llm, base.llm),
        something(prompt, base.prompt),
        something(outputpath, base.outputpath),
    )
end

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

function bootstrap(config::Settings, urls::Vector{<:AbstractString}, task::AbstractString)
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

    analysis_config = Settings(;
        crawl = config.crawl,
        search = config.search,
        llm = config.llm,
        prompt = Prompt(; systemprompt = "You are a technical analyst assistant. Output ONLY JSON.", input = config.prompt.input),
        outputpath = config.outputpath,
    )

    response_text = complete(analysis_prompt, analysis_config)

    try
        clean_json = stripjson(response_text)
        data = JSON.parse(clean_json)
        new_search = Search(;
            _kw(config.search)...,
            query = convert(String, data["query"]),
            keywords = convert(Vector{String}, data["keywords"]),
        )
        @info "Bootstrap complete." query = new_search.query keywords_count = length(new_search.keywords)
        return Settings(crawl = config.crawl, search = new_search, llm = config.llm, prompt = config.prompt, outputpath = config.outputpath)
    catch e
        @error "Failed to parse bootstrap analysis: $e"
        @info "Raw response: $response_text"
        return config
    end
end

weturis(config::Settings) = wetURIs(URI(config.crawl.crawlpath); capacity=config.crawl.capacity)
wets(config::Settings) = wets(weturis(config); capacity=config.crawl.capacity, wetroot=config.crawl.crawlroot, languages=config.crawl.languages)

# --- Pipeline Stages ---

"""
    harvest(config, entries) -> Channel{WET}

Stage 1: High-speed deduplication and keyword matching.
Filters the raw stream down to candidates that contain target keywords.
"""
function harvest(config::Settings, entries::Channel{<:WET})
    out = Channel{eltype(entries)}(config.crawl.capacity)
    deduper = Deduper(config.crawl.dedupe_capacity)
    ac = isempty(config.search.keywords) ? nothing : AC(config.search.keywords)

    Threads.@spawn begin
        try
            for wet in entries
                # 1. Dedupe
                isduplicate(deduper, wet) && continue

                # 2. Keyword score
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

function harvest(config::Settings, entries::Channel{<:WET}, source::TokenWeights; capacity=10)
    shortlist = WETQueue(capacity, eltype(entries), ReverseOrdering(By(score)))
    isempty(source.weights) && return shortlist
    deduper = Deduper(config.crawl.dedupe_capacity)
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
    semantic(config, entries) -> WETQueue

Stage 2: Semantic scoring via embeddings.
Consumes from harvest and maintains a prioritized queue of the most relevant items.
"""
function semantic(config::Settings, entries::Channel{<:WET})
    shortlist = WETQueue(config.crawl.capacity, eltype(entries))
    emb = embedding(config.search.query; vecpath=config.search.vecpath)

    # Parallel scoring via relevant!
    filtered = relevant!(emb, entries; capacity=Threads.nthreads()*10, threshold=1.0-config.search.threshold)
    for wet in filtered
        insert!(shortlist, wet)
    end
    shortlist
end

function semantic(config::Settings, entries::WETQueue, text::AbstractString; capacity=10)
    shortlist = WETQueue(capacity, eltype(entries))
    isempty(entries) && return shortlist
    source = embedding(query(text); vecpath=config.search.vecpath)

    while !isempty(entries)
        insert!(shortlist, score(source, best!(entries)))
    end

    shortlist
end

# --- Final Orchestration ---

append!(file, output::AbstractString) = isempty(output) ? file : (write(file, strip(output), "\n"); flush(file); file)

prompt(wet::WET, config::Settings) = string("URI: ", uri(wet), "\nLANGUAGE: ", language(wet), "\nSCORE: ", wet.score, "\n\n", content(wet))
prompt(wet::WET, ::Val{:local}) = string("SOURCE URL: ", uri(wet), "\nLANGUAGE: ", language(wet), "\nDISTANCE: ", wet.score, "\n\nPAGE EXCERPT:\n", content(wet))

function research(config::Settings)
    raw_wets = wets(config)
    candidates = harvest(config, raw_wets)

    Threads.@spawn begin
        open(config.outputpath, "a") do file
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

function research(config::Settings, urls::Vector{<:AbstractString}, wetpath::AbstractString)
    Threads.@spawn begin
        source = seed(urls)
        candidates = harvest(config, wets(wetpath; capacity=config.crawl.capacity, languages=config.crawl.languages), weights(source))
        retained = length(candidates)
        shortlist = semantic(config, candidates, source)

        report = Settings(
            crawl = config.crawl,
            search = config.search,
            llm = config.llm,
            prompt = Prompt(;
                systemprompt = "You extract only trading strategies and financial or technical indicators. If the page does not contain a trading strategy or financial or technical indicator, return an empty string and no explanation. If it does, write 1-2 sentences with the source URL and a small pseudo Julia code block.",
                input = "Review this page excerpt and follow the output rule.",
            ),
            outputpath = config.outputpath,
        )
        entries = length(shortlist)

        open(config.outputpath, "w") do file
            @info "Local research shortlist ready." candidates=retained entries=entries outputpath=config.outputpath
            while !isempty(shortlist)
                wet = best!(shortlist)
                @info "Analyzing local page" uri=uri(wet) score=wet.score
                append!(file, complete(prompt(wet, Val(:local)), report))
            end
        end

        @info "Local research complete." outputpath=config.outputpath entries=entries
    end
end
