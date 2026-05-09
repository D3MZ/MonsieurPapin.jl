#!/usr/bin/env julia
# example.jl — Waterfall pipeline: each stage streams into the next
using MonsieurPapin, ProgressMeter

settings = loadsettings()
settings["pipeline"]["capacity"] = 2000

# Override crawl path for local testing
settings["crawl"]["path"] = "data/wet.paths.gz"

# Bootstrap: generate keywords and query from seed URLs
seeds_text = join([MonsieurPapin.fetchseed(url) for url in seed_urls], "\n\n")
response = MonsieurPapin.request(;
    model=settings["llm"]["model"],
    systemprompt=settings["prompts"]["bootstrap_system"],
    input="""Task: Find trading strategies that can be expressed as pseudo-code with clear entry/exit rules

Seed Content:
$(first(seeds_text, 2000))""",
    baseurl=settings["llm"]["baseurl"],
    path=settings["llm"]["path"],
    password=settings["llm"]["password"],
    timeout=settings["llm"]["timeout"],
)
data = JSON.parse(MonsieurPapin.get_message(response))
settings["pipeline"]["keywords"] = data["keywords"]
@info "Bootstrap complete." keywords_count=length(settings["pipeline"]["keywords"])

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
            try
                for wet in wets(path; capacity=NTHREADS, wetroot=settings["crawl"]["root"])
                    isduplicate(deduper, wet) && continue
                    put!(out, wet)
                end
            catch e
                @warn "WET download failed" path e
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
candidates = harvest(settings, raw)

# ── stage 3+4: semantic scoring + LLM waterfall ────────────────────
emb       = embedding(join(settings["pipeline"]["keywords"], " "); vecpath=settings["embedding"]["model"])
shortlist = WETQueue(settings["pipeline"]["capacity"], wet_type)

requests  = Channel{Union{Nothing, wet_type}}(NTHREADS)
responses = Channel{NamedTuple{(:wet, :text), Tuple{wet_type, String}}}(NTHREADS)
submitted = Threads.Atomic{Int}(0)
completed = Threads.Atomic{Int}(0)

# LLM consumer runs in background
consumer = Threads.@spawn begin
    for wet in requests
        wet === nothing && break
        try
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
        catch e
            @warn "LLM request failed" uri=MonsieurPapin.uri(wet) e
            put!(responses, (wet=wet, text=""))
        end
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