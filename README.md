# MonsieurPapin

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://D3MZ.github.io/MonsieurPapin.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://D3MZ.github.io/MonsieurPapin.jl/dev/)
[![Build Status](https://github.com/D3MZ/MonsieurPapin.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/D3MZ/MonsieurPapin.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/D3MZ/MonsieurPapin.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/D3MZ/MonsieurPapin.jl)

You found us! Thank the spellcheck and/or hyperlinking gods.

> A French Huguenot physicist, mathematician and inventor, best known for his pioneering invention of the steam digester, the forerunner of the pressure cooker, the steam engine, the centrifugal pump, and a submersible boat. - [Wikipedia](https://en.wikipedia.org/wiki/Denis_Papin)

This ain't your ordinary digester: Search the entire internet, filter, extract, reduce, and summarize into a "research grade" markdown file on your computer in a matter of weeks... Hopefully! 

## Theory and Research
- [February 2026 crawl](https://commoncrawl.org/blog/february-2026-crawl-archive-now-available) is 2.1 billion web pages and 5.96 TiB of compressed WET files (~human readable text).
- 30 file sample: 6 TB of compressed is 17 TB uncompressed ~= 2.8249x compression ratio
- Gigabit connection 1 thread (30s): 68.63 MiB/s, 25.3 hrs, 193.9 MiB/s uncompressed ; 4 threads (30s): 81.82 MiB/s, 21.2 hours, 231.1 MiB/s uncompressed.
- 1 thread: 24,015 pages/s
  - Consistent with 2.1B page estimate: 24,015 pages/s * 25 * 3600 s = 2,161,350,000 pages
- 3,000 record sample:
  - Avg raw chars/page: 7,695.81
  - Avg normalized chars/page: 7,696.39
  - Avg raw tokens/page: 3,828.90
  - Avg normalized tokens/page: 3,705.14
- Can I use an multi-language embedding model to coarsely filter 24K pages / second?

### EmbeddingGemma Performance Matrix
_Source: `benchmarks/embeddinggemma_matrix_doe.csv`, LM Studio `lms.Client` runs, and REST runs from `scripts/benchmark_lmstudio_rest_python.py` + `scripts/benchmark_lmstudio_rest_julia.jl` on `text-embedding-embeddinggemma-300m-qat` (Q4 GGUF) and `text-embedding-embeddinggemma-300m` (F32 GGUF), duration 20s per batch. REST `Tok/s` uses `Req/s * Seq Len` proxy because API embedding usage tokens are reported as `0`._

| Model Variant           | Device     | Seq Len (tokens) | Batch |  Req/s |    Tok/s | Elapsed (s) |
|:------------------------|:-----------|-----------------:|------:|-------:|---------:|------------:|
| full                    | cpu        |             2048 |     2 |  1.404 |  2,875.2 |       31.34 |
| full                    | cpu        |             2048 |     8 |  1.467 |  3,004.9 |       32.71 |
| full                    | cpu        |             2048 |    16 |  1.498 |  3,067.9 |       32.04 |
| full                    | cpu        |             1024 |     2 |  2.575 |  2,636.6 |       30.29 |
| full                    | cpu        |             1024 |     8 |  2.911 |  2,980.6 |       30.23 |
| full                    | cpu        |             1024 |    16 |  2.981 |  3,053.0 |       32.20 |
| full                    | cpu        |              512 |     2 |  3.898 |  1,995.5 |       30.28 |
| full                    | cpu        |              512 |     8 |  4.413 |  2,259.6 |       30.82 |
| full                    | cpu        |              512 |    16 |  4.633 |  2,371.9 |       31.08 |
| full                    | mps        |             2048 |     2 |  2.589 |  5,303.2 |       30.12 |
| full                    | mps        |             2048 |     8 |  2.298 |  4,706.7 |       31.33 |
| full                    | mps        |             2048 |    16 |  1.540 |  3,154.4 |       31.16 |
| full                    | mps        |             1024 |     2 |  3.916 |  4,010.4 |       30.13 |
| full                    | mps        |             1024 |     8 |  4.290 |  4,392.6 |       31.70 |
| full                    | mps        |             1024 |    16 |  4.204 |  4,304.9 |       30.45 |
| full                    | mps        |              512 |     2 |  5.456 |  2,793.7 |       30.06 |
| full                    | mps        |              512 |     8 |  5.806 |  2,972.5 |       30.32 |
| full                    | mps        |              512 |    16 |  5.675 |  2,905.8 |       31.01 |
| quantized               | cpu        |             2048 |     2 |  0.016 |     33.5 |      122.17 |
| quantized               | cpu        |             2048 |     8 |  0.960 |  1,966.1 |       33.33 |
| quantized               | cpu        |             2048 |    16 |  0.973 |  1,993.3 |       32.88 |
| quantized               | cpu        |             1024 |     2 |  2.155 |  2,206.7 |       30.63 |
| quantized               | cpu        |             1024 |     8 |  2.158 |  2,210.1 |       33.36 |
| quantized               | cpu        |             1024 |    16 |  2.108 |  2,158.8 |       30.36 |
| quantized               | cpu        |              512 |     2 |  3.589 |  1,837.3 |       30.10 |
| quantized               | cpu        |              512 |     8 |  3.770 |  1,930.4 |       31.83 |
| quantized               | cpu        |              512 |    16 |  3.727 |  1,908.3 |       30.05 |
| lmstudio-q4             | metal      |             2048 |     1 |  6.284 | 12,869.8 |       20.05 |
| lmstudio-q4             | metal      |             2048 |     2 |  6.316 | 12,935.7 |       20.27 |
| lmstudio-q4             | metal      |             2048 |     4 |  6.239 | 12,777.9 |       20.52 |
| lmstudio-q4             | metal      |             2048 |     8 |  6.301 | 12,905.3 |       20.31 |
| lmstudio-q4             | metal      |             1024 |     1 | 11.878 | 12,162.6 |       20.04 |
| lmstudio-q4             | metal      |             1024 |     4 | 11.963 | 12,250.3 |       20.06 |
| lmstudio-q4             | metal      |              512 |     1 | 21.870 | 11,197.3 |       20.03 |
| lmstudio-q4             | metal      |              512 |     4 | 21.434 | 10,974.0 |       20.16 |
| lmstudio-f32            | metal      |             2048 |     1 |  6.397 | 13,101.5 |       20.01 |
| lmstudio-f32            | metal      |             2048 |     2 |  6.356 | 13,017.4 |       20.14 |
| lmstudio-f32            | metal      |             2048 |     4 |  6.308 | 12,917.8 |       20.29 |
| lmstudio-f32            | metal      |             2048 |     8 |  6.316 | 12,935.1 |       20.27 |
| lmstudio-f32            | metal      |             1024 |     1 | 11.828 | 12,111.7 |       20.04 |
| lmstudio-f32            | metal      |             1024 |     4 | 11.907 | 12,192.6 |       20.16 |
| lmstudio-f32            | metal      |              512 |     1 | 21.388 | 10,950.9 |       20.01 |
| lmstudio-f32            | metal      |              512 |     4 | 21.315 | 10,913.5 |       20.08 |
| lmstudio-q4-rest-python | metal(api) |             2048 |     2 |  6.678 | 13,677.5 |       20.06 |
| lmstudio-q4-rest-python | metal(api) |             2048 |     4 |  6.497 | 13,306.2 |       20.32 |
| lmstudio-q4-rest-python | metal(api) |             2048 |     8 |  6.373 | 13,052.7 |       20.08 |
| lmstudio-q4-rest-julia  | metal(api) |             2048 |     2 |  6.350 | 13,003.9 |       20.16 |
| lmstudio-q4-rest-julia  | metal(api) |             2048 |     4 |  6.466 | 13,241.4 |       20.42 |
| lmstudio-q4-rest-julia  | metal(api) |             2048 |     8 |  6.518 | 13,349.1 |       20.86 |
| lmstudio-q4-rest-julia  | metal(api) |              512 |     8 | 23.937 | 12,255.8 |       20.05 |

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

- [x] Embedding Stage (CPU) for coarse semantic filtering
  - [x] Take from the `warcs` channel and filter using GemmaEmbeddings model on CPU
    - [x] normalize the content 
    - [x] Tokenize up to `EmbeddingSettings.context` length of tokens
    - [x] Embed on CPU
    - [x] If cosine similarity is within `EmbeddingSettings.distance` then put into `filteredwarcs::Channel{WARC}` sized to `2 * LLMSettings.batchsize`.

- [ ] LLM Stage (GPU) for summarizing
  - [ ] Take from `filteredwarcs` channel and pack into `llmbatches::Channel{Vector{WARC}}` sized from `LLMSettings.gpumemory` at init.
  - [ ] Batch pages for GPU inference up to memory limits using `LLMSettings.batchsize`.
  - [ ] Have LLM append to markdown file.

## Embedding Runtime Setup (uv + PythonCall)

```bash
uv venv .venv
uv pip install sentence-transformers torch
export JULIA_CONDAPKG_BACKEND=Null
export JULIA_PYTHONCALL_EXE=$(pwd)/.venv/bin/python
```

Optional integration test:

```bash
MONSIEURPAPIN_EMBEDDING_INTEGRATION=1 julia --project -e 'using Pkg; Pkg.test()'
```
