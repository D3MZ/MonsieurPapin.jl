# MonsieurPapin

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://D3MZ.github.io/MonsieurPapin.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://D3MZ.github.io/MonsieurPapin.jl/dev/)
[![Build Status](https://github.com/D3MZ/MonsieurPapin.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/D3MZ/MonsieurPapin.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/D3MZ/MonsieurPapin.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/D3MZ/MonsieurPapin.jl)

> A French Huguenot physicist, mathematician and inventor, best known for his pioneering invention of the steam digester, the forerunner of the pressure cooker, the steam engine, the centrifugal pump, and a submersible boat. - [Wikipedia](https://en.wikipedia.org/wiki/Denis_Papin)

Not your ordinary digester: Search the entire internet summarize into a "research grade" markdown file entirely on your computer in a day or your money back!

## TODO
TDD
- [x] wetURIs(::URI | ::AbstractString) -> Channel{URI}(threadcount)
- [x] wets(::URI | ::AbstractString) -> Channel{WET}(threadcount)
- [ ] Reduce allocs: 1,783,247 allocs on 21,321 records. Each record could be read into a large buffer that's reused every time.
- [x] Add isrelevant(string1, string2; threshold=0.6, vecpath="data/wiki-news-300d-1M.vec") function in `src/fasttext.jl`, and test.
  - [ ] do research on quantize, subword, etc.
- [x] turn embedding into a type, and dispatch on isrelevant(embedding, string), add test.
- [x] add embedding(string) constructor.
- [x] gettext(URI)::String. This downloads a webpage and gets the text from it. live test on example.
- [x] replace config.json with a struct in `core.jl`, update and simplify references
- [x] dispatch isrelevant(source::Embedding, wet::WET)
- [x] relevant(source::Embedding, wets::Channel{WET})
- [x] update WET struct to include score::Float, rename relevant to relevant!, have it update score based on distance.
- [x] in `src/queue.jl` binary heap queues that maintain a certain size.
  - [x] drains channel into queue maintaining a certain size (check before insert)
  - [x] drains channel and gets the best element (smallest distance)
  - [x] add tests that prove no allocation and expected performance based on research
- [x] update `src/core.jl` to add another step that async does the: drains channel and gets the best element (smallest distance) function. 
- [x] add `llm.jl` that processes a string and outputs a string for later writing. it should be generic and have core's configuration pass the params. In core the llm will be part of the queue async thread that drains the channel, and then pops the best (smallest distance) to the LLM so it can write it's output to a file. Setup the configurations in the config to ensure that we're filtering for trading strategies and the llm will be writing to a file the strategies it finds. Add testing and benchmark this with the local file.
- [ ] Instead of pass fasttext -> channel; drain channel -> queue -> LLM pops from queue. Do pass fast text -> queue; LLM locks and pops from queue, unlocks and does it's processing in loop.
- [ ] remove query from configuration. add Embedding(URI) constructor that generates an embedding from a webpage.


Scoring fitness can be based on:
1. Relevance
2. similarity to historical 
3. Entropy 
4. Age 
5. Etc. 


## IGNORE BELOW WIP



In core.jl
```julia
function research(exampleuri)
  source = embedding(exampleuri)
  weturis
  wets
  filtered = relevant!(source, wets)
  add to queue
  end 
end
```



Ensure performance maintains +20K pages/sec
- [x] Streaming and decompress
- [x] Muse fast text on pages. Score distance. initial comparison: "trading strategies"
- [x] Insert into Priority Min Max Queue that's no more than 10K elements large.
- [x] Generate an openai-compatible.json config for local endpoint/model/output path with optional password field.
- [x] Have LLM pop from queue and if relevant, append write into a research markdown doc based on prompt: "If a trading strategy exists then write a small description about it and the trading strategy as pseudo code wrapped in a code fence, otherwise do not output anything". 
- [ ] Fix progress bar so it displays correctly. Do benchmarking to determine if throttling the events going to it has any impact on it's performance. Report your results and if there's no performance then remove the update throttling from the code and refactor.
- [ ] Actually use Multi lingual Fasttext properly.
- [ ] move "trading strategy" query to the config.json file, and replace it with the text from this site: https://priceaction.com/blog/articles/simplest-trading-strategy-in-the-world/ 

- [ ] Progress bar
- [ ] stream `CC-MAIN-2026-08` and decompress
- [ ] 
- [ ] Download Stage
  - [ ] Get Common Crawl monthly WET snapshot via `crawlpath` and determine the number of urls.
  - [ ] Put `.warc.wet.gz` file URLs into `weturls::Channel{String}`
  - [ ] Stream-download WET files into `wetstreams::Channel{IO}` sized from `DownloadSettings.ram` at init.
  - [ ] Stream-decompress gzip
  - [ ] Stream WET records efficiently into a Julia `warcs::Channel{WET}` sized to 2x embedding batch.
    - [ ] Use Content-Length from header to efficiently read plaintext content.
    - [ ] Parse WET into `WET` types, have the types go into the `warcs` channel

- [ ] Embedding Stage (CPU) for coarse semantic filtering
  - [ ] Take from the `warcs` channel and filter using GemmaEmbeddings model on CPU
    - [ ] normalize the content 
    - [ ] Tokenize up to `EmbeddingSettings.context` length of tokens
    - [ ] Embed on CPU
    - [ ] If cosine similarity is within `EmbeddingSettings.distance` then put into `filteredwarcs::Channel{WET}` sized to `2 * LLMSettings.batchsize`.

- [ ] LLM Stage (GPU) for summarizing
  - [ ] Take from `filteredwarcs` channel and pack into `llmbatches::Channel{Vector{WET}}` sized from `LLMSettings.gpumemory` at init.
  - [ ] Batch pages for GPU inference up to memory limits using `LLMSettings.batchsize`.
  - [ ] Have LLM append to markdown file.



## Features
- [ ] Query in 1 language, sources and information in all languages.
- [ ] Diverse: Near Duplicate ideas are aggregated

## Theory and Research
A gigabit connection places our lowerbound of reading the internet to about a day. 
24hrs gives a Local LLM has enough time to process ~10K pages. 

This creates a few challenges:
1. How to filter effectively given a generic search phrase?
2. How to find the best 10K pages out of the 2.1 Billion? 
3. How to do it without taking too many resources from the GPU?
4. How to ensure maximum diversity and relevance?

Rough ideas:
1. [Max-min fairness](https://en.wikipedia.org/wiki/Max-min_fairness) is said to be achieved by an allocation if and only if the allocation is feasible and an attempt to increase the allocation of any participant necessarily results in the decrease in the allocation of some other participant with an equal or smaller allocation.
2. [Min-max heap queues](https://en.wikipedia.org/wiki/Priority_queue)


### Streaming Budget @ 68.63 MiB/s Compressed (≈ 203 MB/s Plaintext, ≈ 24,015 pages/s)

_Assumes Apple M1 Max performance core (~3.2 GHz, ~1.2 INT ops/cycle sustained for branchy, memory-bound workloads ⇒ ~3.8×10^9 INT ops/sec/core) for CPU core equivalence estimates._

```
| Step                      | Operation                | Compute / s          | CPU (cores) | Mem BW / s     | Notes               |
|---------------------------|--------------------------|----------------------|-------------|----------------|---------------------|
| Download                  | Network I/O              | —                    | —           | 68.63 MiB/s in | Baseline ingest     |
| Decompress (gzip)         | Inflate plaintext        | ~8.1×10⁸ cycles/s    | ~0.6        | ~203 MB/s out  | 3–5 cycles/byte     |
| WARC Header Parse         | Record framing           | ~5–10×10⁷ cycles/s   | ~0.3–0.6    | negligible     | ~100–200 ns/record  |
| Normalize Text            | Lower / strip punct      | ~9.25×10⁸ int ops/s  | ~0.4        | stream-bound   | ~5 ops/char         |
| Shingle Tokenization (k5) | Rolling hash             | ~9.25×10⁸ int ops/s  | ~0.4        | stream-bound   | ~5 ops/char         |
| SimHash Build (64-bit)    | Accumulator updates      | ~1.18×10¹⁰ int adds  | ~5.5        | ~6 MB/s writes | 64 updates/shingle  |
| Sliding Dedupe (W=512)    | XOR + POPCNT             | ~6.1×10⁷ cycles/s    | ~0.05       | ~197 MB/s read | 12.3 M comps/s      |
| **Pipeline Total**        | —                        | ~1.4×10¹⁰ int ops/s  | **~7–8**    | **400–600 MB/s** | Inline w/ download |
```

### Sliding Window Size vs Headroom

```
| Window (W) | Comparisons / s | CPU (cores) | Mem BW / s |
|------------|------------------|-------------|------------|
| 10^3       | ~24.0 M          | ~0.10       | ~384 MB/s  |
| 10^4       | ~240 M           | ~1.0        | ~3.84 GB/s |
| 10^5       | ~2.4 B           | ~10.0       | ~38.4 GB/s |
| 10^6       | ~24.0 B          | ~100        | ~384 GB/s  |
| 10^7       | ~240 B           | ~1000       | ~3.84 TB/s |
```



- [February 2026 crawl](https://commoncrawl.org/blog/february-2026-crawl-archive-now-available) is 2.1 billion web pages and 5.96 TiB of compressed WET files (~human readable text).
- 6 TB of compressed is 17 TB uncompressed at 2.8249x compression ratio
  - 30 file sample
- 21 hours - 25 hrs to download compressed WET
  - 30s, 1 thread: 68.63 MiB/s
  - 30s, 4 threads: 81.82 MiB/s
- 24,015 pages/s
  - 1 thread download and read
  - 24,015 pages/s * 25 * 3600 s = 2,161,350,000 pages == [2.1B pages February 2026 Crawl post total](https://commoncrawl.org/blog/february-2026-crawl-archive-now-available).
- 7,695.81 chars/page & 3,828.90 tokens/page.
  - 3,000 record sample
- fastText? 
- 13,000 tokens/s 200MB RAM usage through multi-language embedding model
  - EmbeddingGemma, M1 Max GPU, GGUF Q4 quantization
- CHECK: 8,640 pages/day ~ 0.1 pages/s via LLM assuming 4K tokens input and 250 tokens output.
  - 50 Token/s LLM

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
| lmstudio-q4             | metal      |              512 |    16 |  5.675 |  2,905.8 |       31.01 |
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
