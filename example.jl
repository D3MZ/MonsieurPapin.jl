#!/usr/bin/env julia
# example.jl — Waterfall pipeline: each stage streams into the next
using MonsieurPapin, ProgressMeter

settings = loadsettings()
settings["pipeline"]["capacity"] = 2000

# Override crawl path for local testing
settings["crawl"]["path"] = "data/wet.paths.gz"

# Bootstrap from seed URLs — customize these for your domain
const seed_urls = [
    "https://www.investopedia.com/articles/active-trading/",
    "https://en.wikipedia.org/wiki/Technical_analysis",
]
seedpages = [MonsieurPapin.fetchtext(url) for url in seed_urls]
keywords = unique(reduce(vcat, [MonsieurPapin.keywords(settings, page) for page in seedpages]))
summaries = [MonsieurPapin.summary(settings, page) for page in seedpages]
@info "Seed processing complete." keywords_count=length(keywords) summaries_count=length(summaries)

const NTHREADS   = Threads.nthreads()
const TOTAL_URIS = 100_000

wet_type = WET{4096, 12000, 64}

# ── stage 1: parallel WET download → raw channel ───────────────────
uris = Channel{String}(NTHREADS * 10) do ch
    for uri in wetURIs(settings["crawl"]["path"]; capacity=NTHREADS)
        put!(ch, String(uri))
    end
end

p       = Progress(TOTAL_URIS; desc="WET URIs: ", output=stderr)
lk      = ReentrantLock()
counter = Threads.Atomic{Int}(0)
deduper = Deduper(settings["pipeline"]["dedupe_capacity"])

raw = Channel{wet_type}(NTHREADS * 100) do out
    tasks = [Threads.@spawn begin
        for path in uris
            for wet in wets(path; capacity=NTHREADS, wetroot=settings["crawl"]["root"])
                isduplicate(deduper, wet) && continue
                put!(out, wet)
            end
            lock(lk) do; next!(p); end
            n = Threads.atomic_add!(counter, 1)
            n % 1000 == 0 && @info "WET URIs processed" n
        end
    end for _ in 1:NTHREADS]
    foreach(wait, tasks)
    finish!(p)
end

# ── stage 2: harvest (dedup + keyword) ─────────────────────────────
candidates = harvest(keywords, settings, raw)

# ── stage 3+4: semantic scoring + LLM waterfall ────────────────────
emb       = embedding(join(keywords, " "); vecpath=settings["embedding"]["model"])
shortlist = WETQueue(settings["pipeline"]["capacity"], wet_type)

requests  = Channel{Union{Nothing, wet_type}}(NTHREADS)
responses = Channel{NamedTuple{(:wet, :text), Tuple{wet_type, String}}}(NTHREADS)
submitted = Threads.Atomic{Int}(0)
completed = Threads.Atomic{Int}(0)

# LLM consumer runs in background
consumer = Threads.@spawn begin
    for wet in requests
        wet === nothing && break
        response = MonsieurPapin.request(;
            model=settings["llm"]["model"],
            systemprompt=settings["prompts"]["system"],
            input=string(settings["prompts"]["input"], "\n\n", MonsieurPapin.prompt(wet)),
            baseurl=settings["llm"]["baseurl"],
            path=settings["llm"]["path"],
            password=settings["llm"]["password"],
            timeout=settings["llm"]["timeout"],
        )
        output = MonsieurPapin.get_message(response)
        put!(responses, (wet=wet, text=output))
    end
end

open(settings["output"]["path"], "w") do file
    scored = relevant!(emb, candidates; capacity=NTHREADS*10, threshold=1.0-settings["pipeline"]["threshold"])
    first_result = Ref(true)

    for wet in scored
        first_result[] && (@info "First result" uri=MonsieurPapin.uri(wet) score=wet.score; first_result[] = false)
        MonsieurPapin.insert!(shortlist, wet)

        # Dispatch best to LLM as queue fills (no dispatch limit)
        while !MonsieurPapin.isempty(shortlist) && !isfull(requests)
            put!(requests, MonsieurPapin.best!(shortlist))
            submitted[] += 1
        end

        # Collect any completed LLM responses
        while isready(responses)
            result = take!(responses)
            completed[] += 1
            MonsieurPapin.append!(file, result.text)
        end
    end

    # Drain remaining queue
    while !MonsieurPapin.isempty(shortlist) && !isfull(requests)
        put!(requests, MonsieurPapin.best!(shortlist))
        submitted[] += 1
    end

    # Wait for all LLM responses
    while completed[] < submitted[]
        result = take!(responses)
        completed[] += 1
        MonsieurPapin.append!(file, result.text)
    end
end

put!(requests, nothing)  # signal consumer to stop
wait(consumer)
@info "Done" submitted=submitted[] completed=completed[] output=settings["output"]["path"]