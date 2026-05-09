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
#     for wet in coarsefilter(config, wets(config))
#         println(uri(wet), "  score: ", round(wet.score; digits=4))
#     end

# ═══════════════════════════════════════════════════════════════════
# FULL PIPELINE
# ═══════════════════════════════════════════════════════════════════
#
# Prerequisites:
#   1. A running OpenAI-compatible LLM endpoint (e.g. LM Studio at localhost:1234)
#   2. Internet access — WET files are streamed from commoncrawl.org
#
# data/wet.paths.gz ships with 100 000 Common Crawl WET paths.
# The pipeline streams each remote WET file, scores every page with
# model2vec embeddings, filters by relevance, and queues the best
# candidates for LLM summarisation.

# --- shared config -------------------------------------------------
config = Configuration(
    crawlpath     = "data/wet.paths.gz",
    crawlroot     = "https://data.commoncrawl.org/",
    capacity      = 20,
    threshold     = 0.6,
    vecpath       = "minishlab/potion-multilingual-128M",
    query         = "trading strategy price action",
    baseurl       = "http://localhost:1234",
    path          = "/api/v1/chat",
    model         = "qwen/qwen3.6-27b",
    password      = "",                              # API key if needed
    systemprompt  = "If a trading strategy exists, describe it + pseudo-code.",
    input         = "Evaluate this page excerpt for trading strategy relevance.",
    outputpath    = "research.md",
    timeoutseconds = 120,
)

# --- pipeline -------------------------------------------------------
uris  = collect(wetURIs(config.crawlpath; capacity=config.capacity))

pages = Channel{MonsieurPapin.WET}(config.capacity) do out
    @showprogress desc="WET URIs: " for path in uris
        for wet in wets(path; capacity=config.capacity, wetroot=config.crawlroot)
            put!(out, wet)
        end
    end
end

emb      = embedding(config.query; vecpath=config.vecpath)
filtered = relevant!(emb, pages; capacity=config.capacity, threshold=config.threshold)

t = queue(config, filtered)
wait(t)
println("Done → $(config.outputpath)")
