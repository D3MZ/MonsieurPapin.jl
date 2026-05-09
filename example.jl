#!/usr/bin/env julia
# example.jl — Parallel MonsieurPapin pipeline
using MonsieurPapin, ProgressMeter
using HTTP: URI

# ═══════════════════════════════════════════════════════════════════
# QUICK DEMO (offline — 25 WET records shipped in repo)
# ═══════════════════════════════════════════════════════════════════
#
#     config = Configuration(crawlpath="data/warc.wet.gz", capacity=5, query="news")
#     for wet in wets(config)
#         println(uri(wet))
#     end

# ═══════════════════════════════════════════════════════════════════
# PARALLEL THREE-STAGE PIPELINE
# ═══════════════════════════════════════════════════════════════════
#
# Prerequisites:
#   1. Running LLM endpoint (e.g. LM Studio at localhost:1234)
#   2. Internet access — WET files streamed from commoncrawl.org
#
# Stages (pipelined concurrently):
#   1. harvest — N threads download WET files, dedupe, keyword-match
#   2. semantic — embeddings score candidates, maintain top-N queue
#   3. report  — LLM summarises best pages, writes research.md

# --- config ---------------------------------------------------------
config = Configuration(
    crawlpath  = "data/wet.paths.gz",
    capacity   = 2000,
    threshold  = 0.6,
    query      = "trading strategy price action",
    model      = "qwen/qwen3.6-27b",
    outputpath = "research.md",
)

const NTHREADS   = Threads.nthreads()
const TOTAL_URIS = 100_000  # data/wet.paths.gz line count

# --- stage 1: parallel harvest -------------------------------------
wet_type = WET{4096, 12000, 64}
uris     = Channel{String}(NTHREADS * 10) do ch
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

# --- stage 2: semantic scoring -------------------------------------
candidates = harvest(config, raw)
shortlist  = semantic(config, candidates)

# --- stage 3: LLM report -------------------------------------------
@info "Top candidates" count = length(shortlist)
open(config.outputpath, "w") do file
    while !isempty(shortlist)
        wet = best!(shortlist)
        @info "LLM analysing" uri = MonsieurPapin.uri(wet) score = wet.score
        output = complete(MonsieurPapin.prompt(wet, config), config)
        MonsieurPapin.append!(file, output)
        flush(file)
    end
end
println("Done → $(config.outputpath)")
