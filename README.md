<p align="center">
  <img src="logo.webp" alt="MonsieurPapin logo" width="180">
</p>

# MonsieurPapin

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://D3MZ.github.io/MonsieurPapin.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://D3MZ.github.io/MonsieurPapin.jl/dev/)
[![Build Status](https://github.com/D3MZ/MonsieurPapin.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/D3MZ/MonsieurPapin.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Codecov](https://codecov.io/gh/D3MZ/MonsieurPapin.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/D3MZ/MonsieurPapin.jl)

> A French Huguenot physicist, mathematician and inventor, best known for his pioneering invention of the steam digester, the forerunner of the pressure cooker, the steam engine, the centrifugal pump, and a submersible boat. — [Wikipedia](https://en.wikipedia.org/wiki/Denis_Papin)

This ain't your ordinary digester: Search the entire internet, filter, extract, reduce, and summarize into a "research grade" markdown file on your computer in a day or your money back! :P

> [!IMPORTANT]
> MonsieurPapin is in active pre-release development. See [TODO](TODO.md) before running long crawls.

## Performance Benchmarks

Measured on Apple M1 Max (32 GB) + Julia 1.12, single-threaded, on a 21,465-page WET sample from the February 2026 Common Crawl archive (2.1 billion pages, 5.96 TiB compressed).

| Stage | Rate | Bottleneck bound |
| --- | --- | --- |
| WET record parsing | 27,100 records/s | 21.5 hours for full crawl |
| SimHash deduplication | 3,250 records/s | 7.5 days for full crawl |
| Aho-Corasick keyword scoring | 22,100 records/s | Rust FFI |
| Model2Vec embedding scoring | +400 records/s | CPU-bound, serial per-record; batch scoring amortizes FFI overhead |
| Queue insert (top 1K) | 22,000 records/s | Bounded heap insert |
| Queue best! extraction | 1,100,000 pops/s | Linear scan best-element removal |
| LLM extraction | ~0.6 ms (mock), ~0.1 pages/s (real) | Consumer-bound

As a waterfall, each stage only processes the top candidates from the previous stage — the pipeline doesn't need to run every page through every stage. The practical throughput is bounded by embedding scoring (+34M pages/day) and LLM extraction, with the LLM being the bottleneck for deep extraction work.

See [test/benchmarks.jl](test/benchmarks.jl) for how to reproduce these numbers.

## Quick Start

### Prerequisites

- [Julia 1.12+](https://julialang.org/downloads/)
- Rust toolchain
- A local OpenAI-compatible chat server, such as [LM Studio](https://lmstudio.ai/)
- About 200 MB of disk space for the embedding model, downloaded on first run

Install Rust if needed:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Load a local chat model in your OpenAI-compatible server, for example `qwen/qwen3.6-27b`, and start it on port `1234`.

### Run a Crawl

```bash
git clone https://github.com/D3MZ/MonsieurPapin.jl
cd MonsieurPapin.jl

cargo build --release --manifest-path deps/model2vec_rs_worker/Cargo.toml

julia --project example.jl
```

The pipeline will:

- Bootstrap from seed URLs, asking the LLM for multilingual keywords and a semantic query
- Download the configured Common Crawl WET archive index
- Stream and decompress WET files
- Score pages by weighted keyword match
- Score candidates by embedding similarity
- Send shortlisted pages to the configured LLM
- Append extracted findings to `research.md`

### Configure

Edit `settings.toml` at the package root — all defaults live there including prompts, LLM connection, crawl source, and pipeline parameters.

The LLM integration uses the OpenAI-compatible `/v1/chat/completions` endpoint and supports structured output via JSON schema (`response_format`). It works with LM Studio and any OpenAI-compatible server.

For better local throughput, run Julia with more threads:

```bash
export JULIA_NUM_THREADS=auto
julia --project example.jl
```

## Architecture

MonsieurPapin is a fixed-capacity waterfall. Each stage keeps the best candidates it has seen, and the next stage pulls from that shortlist. Cheap stages reduce the search space before expensive stages run.

```mermaid
flowchart TD
    A["Common Crawl WET archives (2.1B pages)"] --> B["Stage 1: deduplication"]
    B --> C["Stage 2: keyword scoring"]
    C --> D["Stage 3: embedding similarity"]
    D --> E["Stage 4: LLM extraction"]
    E --> F["research.md"]

    G["Bootstrap from seed URLs"] --> C
    G --> D
```

**Key principles**: bounded queues evict lower-ranked candidates when full; expensive stages process the best survivors from the previous stage; near-duplicates compete rather than being hard-dropped.



## Current Implementation

The main runnable entry point is `example.jl`. It demonstrates the broader four-stage shape, including bootstrap and deduplication, with weighted Aho-Corasick terms, embedding scoring, a `WETQueue` shortlist, and LLM extraction.

Important current gaps:

- Keyword harvest is still a streaming threshold filter in the main path, not a fixed-capacity competing queue.
- `semantic()` in `src/core.jl` drains its candidate channel before returning.
- Bootstrap JSON parsing is fragile when the LLM wraps JSON in markdown or extra reasoning text.



## Models

| Model | Type | Loading |
| --- | --- | --- |
| `minishlab/potion-multilingual-128M` | Embedding | Downloaded by the Rust worker on first use |
| Any OpenAI-compatible chat model | Extraction | Served separately at `baseurl` + `path` |

## Project Layout

| Path | Purpose |
| `settings.toml` | All configuration (crawl, LLM, pipeline, prompts) |
| `src/core.jl` | Pipeline orchestration (harvest, semantic, research) |
| `src/llm.jl` | OpenAI-compatible API client (`request`, `keywords`, `summary`) |
| `src/http.jl` | HTML→text extraction, HTTP fetch utilities |
| `src/scoring.jl` | Embedding and distance helpers |
| `src/queue.jl` | Fixed-capacity `WETQueue` priority heap |
| `src/wets.jl` | WET record parsing and streaming |
| `src/wetURIs.jl` | WET path list parsing (local or HTTP) |
| `src/simhash.jl` | SimHash deduplication |
| `src/RustWorker.jl` | Julia→Rust FFI for scoring |
| `deps/model2vec_rs_worker/` | Rust Aho-Corasick + Model2Vec worker |
| `example.jl` | Entry point — waterfall pipeline |
| `test/` | Unit and integration tests |



## Known Issues

1. **Thread count defaults to 1** — Set `JULIA_NUM_THREADS=auto` before running long crawls.
2. **`semantic()` blocks** — Drains its candidate channel before returning; `example.jl` works around this with direct waterfall dispatch.
3. **Coarse keyword pass-through** — Too many keyword-passing pages reach the embedding stage before the bounded queue fills.
4. **Settings mutation** — Pipeline code (e.g. bootstrap keyword generation) mutates the settings dict at runtime.

