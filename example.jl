#!/usr/bin/env julia
# example.jl — Entry point for the modular MonsieurPapin pipeline
using MonsieurPapin, ProgressMeter
using HTTP: URI

# ═══════════════════════════════════════════════════════════════════
# QUICK TEST (offline — 25 WET records shipped in repo)
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
# THREE-STAGE PIPELINE
# ═══════════════════════════════════════════════════════════════════
#
# Prerequisites:
#   1. A running OpenAI-compatible LLM endpoint (e.g. LM Studio at localhost:1234)
#   2. Internet access — WET files are streamed from commoncrawl.org
#
# data/wet.paths.gz ships with 100 000 Common Crawl WET paths.
# Stage 1 (harvest): deduplicate + keyword-match raw WET stream
# Stage 2 (semantic): score candidates with model2vec embeddings
# Stage 3 (report):  LLM summarises top-N pages, writes research.md

# --- shared config -------------------------------------------------
config = Configuration(
    crawlpath      = "data/wet.paths.gz",
    crawlroot      = "https://data.commoncrawl.org/",
    capacity       = 20,
    threshold      = 0.6,
    vecpath        = "minishlab/potion-multilingual-128M",
    query          = "trading strategy price action",
    baseurl        = "http://localhost:1234",
    path           = "/api/v1/chat",
    model          = "qwen/qwen3.6-27b",
    password       = "",                             # API key if needed
    systemprompt   = "If a trading strategy exists, describe it + pseudo-code.",
    input          = "Evaluate this page excerpt for trading strategy relevance.",
    outputpath     = "research.md",
    timeoutseconds = 120,
)

const TOTAL_URIS = 100_000  # data/wet.paths.gz line count

# --- one-shot ------------------------------------------------------
t = research(config)
wait(t)
println("Done → $(config.outputpath)")

# --- or manual pipeline with progress bar --------------------------
#
# uris  = collect(wetURIs(config.crawlpath; capacity=config.capacity))
#
# wet_type = WET{4096, 12000, 64}
# raw = Channel{wet_type}(config.capacity) do out
#     @showprogress desc="WET URIs: " for path in uris
#         for wet in wets(path; capacity=config.capacity, wetroot=config.crawlroot)
#             put!(out, wet)
#         end
#     end
# end
#
# candidates = harvest(config, raw)
# shortlist  = semantic(config, candidates)
#
# @info "Top candidates" count = length(shortlist)
# while !isempty(shortlist)
#     wet = best!(shortlist)
#     @info "LLM analysing" uri = uri(wet) score = wet.score
#     output = complete(prompt(wet, config), config)
#     append!(outputpath, output)
# end
