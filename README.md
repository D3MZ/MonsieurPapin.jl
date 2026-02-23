# MonsieurPapin

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://D3MZ.github.io/MonsieurPapin.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://D3MZ.github.io/MonsieurPapin.jl/dev/)
[![Build Status](https://github.com/D3MZ/MonsieurPapin.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/D3MZ/MonsieurPapin.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/D3MZ/MonsieurPapin.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/D3MZ/MonsieurPapin.jl)

You found us! Thank the spellcheck and/or hyperlinking gods.

> A French Huguenot physicist, mathematician and inventor, best known for his pioneering invention of the steam digester, the forerunner of the pressure cooker, the steam engine, the centrifugal pump, and a submersible boat. - [Wikipedia](https://en.wikipedia.org/wiki/Denis_Papin)

This ain't your ordinary digester: Search the entire internet, filter, extract, reduce, and summarize into a "research grade" markdown file on your computer in a matter of weeks... Hopefully! 

## TODO
```julia
@kwdef struct DownloadSettings
    crawlpath::String = "CC-MAIN-2025-01"
    ram::Float32 = 0.8
end

@kwdef struct EmbeddingSettings
    context::Int = 2048
    distance::Float32 = 0.65
    batchsize::Int = 8
end

@kwdef struct LLMSettings
    prompt::String
    gpumemory::Float32 = 0.8
    batchsize::Int = 8
end

@kwdef struct Settings
    query::String
    download::DownloadSettings = DownloadSettings()
    embedding::EmbeddingSettings = EmbeddingSettings()
    llm::LLMSettings
end

struct WARC
    uri::String
    date::DateTime
    language::String
    length::Int
    content::String
end
```
- [x] Progress bar based on urls completed
- [x] Download Stage
  - [x] Get Common Crawl monthly WET snapshot via `crawlpath` and determine the number of urls.
  - [x] Put `.warc.wet.gz` file URLs into `weturls::Channel{String}`
  - [x] Stream-download WET files into `wetstreams::Channel{IO}` sized from `DownloadSettings.ram` at init.
  - [x] Stream-decompress gzip
  - [x] Stream WARC records efficiently into a Julia `warcs::Channel{WARC}` sized to 2x embedding batch.
    - [x] Use Content-Length from header to efficiently read plaintext content.
    - [x] Parse WARC into `WARC` types, have the types go into the `warcs` channel

- [ ] Embedding Stage (CPU) for coarse semantic filtering
  - [ ] Take from the `warcs` channel and filter using GemmaEmbeddings model on CPU
    - [ ] normalize the content 
    - [ ] Tokenize up to `EmbeddingSettings.context` length of tokens
    - [ ] Embed on CPU
    - [ ] If cosine similarity is within `EmbeddingSettings.distance` then put into `filteredwarcs::Channel{WARC}` sized to `2 * LLMSettings.batchsize`.

- [ ] LLM Stage (GPU) for summarizing
  - [ ] Take from `filteredwarcs` channel and pack into `llmbatches::Channel{Vector{WARC}}` sized from `LLMSettings.gpumemory` at init.
  - [ ] Batch pages for GPU inference up to memory limits using `LLMSettings.batchsize`.
  - [ ] Have LLM append to markdown file.
