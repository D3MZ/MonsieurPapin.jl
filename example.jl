#!/usr/bin/env julia
# example.jl — Entry point for the modular MonsieurPapin pipeline
using MonsieurPapin, ProgressMeter
using HTTP: URI

# ═══════════════════════════════════════════════════════════════════
# QUICK DEMO (offline — 25 WET records shipped in repo)
# ═══════════════════════════════════════════════════════════════════
#
#     config = Configuration(
#         crawlpath = "data/warc.wet.gz",
#         capacity  = 5,
#         threshold = 0.4,
#         query     = "technology news",
#     )
#     for wet in wets(config)
#         println(uri(wet))
#     end

# ═══════════════════════════════════════════════════════════════════
# THREE-STAGE PIPELINE (with progress bar)
# ═══════════════════════════════════════════════════════════════════
#
# Prerequisites:
#   1. Running LLM endpoint (e.g. LM Studio at localhost:1234)
#   2. Internet access — WET files streamed from commoncrawl.org
#
# Stages:
#   1. harvest — deduplicate + keyword-match raw WET stream
#   2. semantic — score candidates with model2vec embeddings
#   3. report  — LLM summarises top-N pages, writes research.md

# --- shared config -------------------------------------------------
config = Configuration(
    crawlpath      = "data/wet.paths.gz",
    capacity       = 20,
    threshold      = 0.6,
    query          = "trading strategy price action",
    model          = "qwen/qwen3.6-27b",
    outputpath     = "research.md",
)

const TOTAL_URIS = 100_000  # data/wet.paths.gz line count

# --- pipeline -------------------------------------------------------
uris  = collect(wetURIs(config.crawlpath; capacity=config.capacity))
p     = Progress(length(uris); desc="WET URIs: ")

wet_type = WET{4096, 12000, 64}
raw = Channel{wet_type}(1000) do out
    for path in uris
        for wet in wets(path; capacity=config.capacity, wetroot=config.crawlroot)
            put!(out, wet)
        end
        next!(p)
    end
    finish!(p)
end

candidates = harvest(config, raw)
shortlist  = semantic(config, candidates)

@info "Top candidates" count = length(shortlist)
open(config.outputpath, "w") do file
    while !isempty(shortlist)
        wet = best!(shortlist)
        @info "LLM analysing" uri = uri(wet) score = wet.score
        output = complete(prompt(wet, config), config)
        append!(file, output)
    end
end
println("Done → $(config.outputpath)")
