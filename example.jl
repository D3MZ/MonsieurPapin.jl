#!/usr/bin/env julia
# example.jl — Waterfall pipeline: each stage streams into the next
using MonsieurPapin, ProgressMeter
using HTTP: URI

config = Configuration(
    crawlpath  = "data/wet.paths.gz",
    capacity   = 2000,
    threshold  = 0.6,
    model      = "qwen/qwen3.6-27b",
    outputpath = "research.md",
)

# Boostrap: fetch seed URLs, let LLM generate keywords + semantic query
seed_urls = [
    "https://en.wikipedia.org/wiki/Technical_analysis",
    "https://en.wikipedia.org/wiki/Algorithmic_trading",
]
bootstrap(config, seed_urls, "Find trading strategies that can be expressed as pseudo-code with clear entry/exit rules")

# Fallback if bootstrap fails
if isempty(config.query)
    config.query = "trading strategy entry exit rules indicators pseudo-code"
    @warn "Bootstrap failed, using fallback query" config.query
end

const NTHREADS   = Threads.nthreads()
const TOTAL_URIS = 100_000

wet_type = WET{4096, 12000, 64}

# ── stage 1: parallel WET download → raw channel ───────────────────
uris = Channel{String}(NTHREADS * 10) do ch
    for uri in wetURIs(config.crawlpath; capacity=NTHREADS)
        put!(ch, String(uri))
    end
end

p       = Progress(TOTAL_URIS; desc="WET URIs: ", output=stderr)
lk      = ReentrantLock()
counter = Threads.Atomic{Int}(0)
deduper = Deduper(config.dedupe_capacity)

raw = Channel{wet_type}(NTHREADS * 100) do out
    tasks = [Threads.@spawn begin
        for path in uris
            try
                for wet in wets(path; capacity=NTHREADS, wetroot=config.crawlroot)
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
candidates = harvest(config, raw)

# ── stage 3+4: semantic scoring + LLM waterfall ────────────────────
emb       = embedding(config.query; vecpath=config.vecpath)
shortlist = WETQueue(config.capacity, wet_type)

requests  = Channel{Union{Nothing, wet_type}}(NTHREADS)
responses = Channel{NamedTuple{(:wet, :text), Tuple{wet_type, String}}}(NTHREADS)
submitted = Threads.Atomic{Int}(0)
completed = Threads.Atomic{Int}(0)

# LLM consumer runs in background
consumer = Threads.@spawn begin
    for wet in requests
        wet === nothing && break
        try
            output = complete(MonsieurPapin.prompt(wet, config), config)
            put!(responses, (wet=wet, text=output))
        catch e
            @warn "LLM request failed" uri=MonsieurPapin.uri(wet) e
            put!(responses, (wet=wet, text=""))
        end
    end
end

open(config.outputpath, "w") do file
    scored = relevant!(emb, candidates; capacity=NTHREADS*10, threshold=1.0-config.threshold)
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
@info "Done" submitted=submitted[] completed=completed[] output=config.outputpath
