<p align="center">
  <img src="logo.webp" alt="MonsieurPapin logo" width="200">
</p>

# MonsieurPapin

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://D3MZ.github.io/MonsieurPapin.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://D3MZ.github.io/MonsieurPapin.jl/dev/)
[![Build Status](https://github.com/D3MZ/MonsieurPapin.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/D3MZ/MonsieurPapin.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/D3MZ/MonsieurPapin.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/D3MZ/MonsieurPapin.jl)

> A French Huguenot physicist, mathematician and inventor, best known for his pioneering invention of the steam digester, the forerunner of the pressure cooker, the steam engine, the centrifugal pump, and a submersible boat. — [Wikipedia](https://en.wikipedia.org/wiki/Denis_Papin)

Not your ordinary digester: search the entire internet and summarize into a research-grade markdown file, entirely on your computer, in a day or your money back. :)

Note: This is still in active pre-release development

Public Release Milestones
- [ ] 0/8 full searches completed
- [ ] 0/5 machines tested on
- [ ] 0/3 Major OSs (i.e. Latest Windows, MacOS, & Linux)
- [ ] Confirmed that different languages can be used in sources.

## Known Issues

1. **semantic() in core.jl blocks** — the library function `semantic()` drains the entire candidate channel before returning. `example.jl` works around this with a waterfall pattern (LLM consumer runs in a background task while scoring continues), but `research()` still blocks. Fix: refactor `semantic()` into a streaming primitive.
2. **Aho-Corasick keyword stage not enabled by default** — `config.keywords` defaults to empty. `example.jl` calls `bootstrap()` with seed URLs but the LLM often returns non-JSON text, causing the fallback query. The AC matcher only activates when keywords are successfully populated. Needs more robust JSON extraction in `bootstrap()`.
3. **JULIA_NUM_THREADS defaults to 1** — the pipeline uses `Threads.nthreads()` for parallelism. Set `export JULIA_NUM_THREADS=auto` (or a specific count) before running. On a 24-core machine this means `export JULIA_NUM_THREADS=24`.

## Quick start

### Prerequisites

1. **Julia 1.12+** — [download](https://julialang.org/downloads/)
2. **Rust toolchain** — `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
3. **An LLM server** running locally with an OpenAI-compatible chat API. [LM Studio](https://lmstudio.ai/) is recommended.
   - Load a model (e.g. `qwen/qwen3.6-27b`)
   - Start the local server on port `1234`
4. **~200 MB free disk** for the embedding model (auto-downloaded on first run)

### Run

```bash
# Clone and enter the repo
git clone https://github.com/D3MZ/MonsieurPapin.jl
cd MonsieurPapin.jl

# Build the Rust worker (one-time)
cargo build --release --manifest-path deps/model2vec_rs_worker/Cargo.toml

# Start the LLM server (e.g. in LM Studio), then:
julia --project scripts/live_march.jl
```

The script will:
- Download the latest [Common Crawl](https://commoncrawl.org/) WET archive index
- Stream and decompress WET files (~25K pages/s)
- Filter pages by keyword match (Aho-Corasick in Rust)
- Score remaining pages by embedding similarity (Model2Vec)
- Send the top candidates to your LLM for extraction
- Write findings to `research.md` in real-time

### Customize

Edit the defaults at the top of `scripts/live_march.jl`:

```julia
seedurls() = ["https://en.wikipedia.org/wiki/Relative_strength_index"]  # seed pages
crawlindex() = URI("https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz")  # crawl to use
outputpath() = "research.md"         # output file
languages() = ["eng"]                # language filter
keywordgate() = 10.0                 # minimum keyword score for harvest stage
distancegate() = 0.45                # maximum embedding distance for semantic stage
```

Or configure the LLM endpoint in `src/core.jl`:
```julia
baseurl::String = "http://localhost:1234"
path::String = "/api/v1/chat"
model::String = "qwen/qwen3.6-27b"
```

### What to expect

- The first AC candidate (keyword match) should appear within ~40 seconds
- The first LLM extraction request follows a few seconds later
- Two progress bars show: `WET files` (100K total) and a page counter
- `research.md` grows in real-time as the LLM finds trading strategies
- A full crawl takes ~4 days at typical home broadband speeds

## How it works

```
Common Crawl WET Archive (6 TiB compressed, 2.1B pages)
              │
    ┌─────────▼──────────┐
    │  1. INGEST         │  HTTP stream + gzip decompress
    │  ~25,000 pages/s   │  Parse WARC records → WET structs
    └─────────┬──────────┘
              │ channel of WET pages
    ┌─────────▼──────────┐
    │  2. HARVEST        │  Dedup + keyword filter (Aho-Corasick in Rust)
    │  rust worker       │  Non-matching pages are dropped
    └─────────┬──────────┘
              │ channel of candidates
    ┌─────────▼──────────┐
    │  3. SEMANTIC       │  Model2Vec embedding similarity
    │  embedding model   │  Cosine distance vs. query vector
    │  potion-128M       │  Only pages above threshold survive
    └─────────┬──────────┘
              │ priority queue (max 10K items)
    ┌─────────▼──────────┐
    │  4. EXTRACT        │  LLM reads each page snippet
    │  LLM (local API)   │  If relevant → description + pseudo Julia code
    └─────────┬──────────┘
              │
    ┌─────────▼──────────┐
    │  research.md        │  Appended in real-time as LLM responds
    └────────────────────┘
```

Each stage is ~10–100× faster than the next, so the expensive LLM only sees the top ~0.001% of pages:

| Stage     | Technology                           | Speed          | Survivors      |
|-----------|--------------------------------------|----------------|----------------|
| Ingest    | Julia streaming I/O                  | ~25K pages/s   | 2.1B → 2.1B    |
| Harvest   | Rust Aho-Corasick                    | —              | 2.1B → ~100M   |
| Semantic  | Model2Vec `potion-multilingual-128M` | ~2.5K pages/s  | ~100M → 10K    |
| Extract   | LLM via HTTP API                     | ~0.1 pages/s   | 10K → ~100 md  |

The frontier is a **min-max heap queue**: new pages displace worse ones when their score is higher, maintaining the 10K best results. The LLM pops from the best end and writes to `research.md` live — results stream in while the crawl is still running.

## Models required

| Model | Type | How it's loaded |
|---|---|---|
| `minishlab/potion-multilingual-128M` | Embedding (Model2Vec) | Auto-downloaded from HuggingFace by the Rust worker on first run |
| Any OpenAI-compatible chat LLM | Chat / extraction | Must be running separately at the configured base URL (default `http://localhost:1234`) |

Configure the LLM endpoint and model name in `src/core.jl` (`baseurl`, `path`, `model`).

## Key design decisions

- **Staged filtering** — cheap filters eliminate 99.9% of pages before the LLM sees them.
- **Zero-allocation WET parsing** — WARC records parsed into fixed-size structs with no heap allocations.
- **Rust FFI for hot paths** — Aho-Corasick matching and embedding similarity run in a Rust shared library (`deps/model2vec_rs_worker`).
- **Live output** — `research.md` is appended in real-time; results appear while the crawl runs.
- **Language-aware** — filter by Common Crawl language codes (`eng`, `deu`, `rus`, `jpn`, `zho`, `spa`, `fra`, `por`, `ita`, `pol` by default).

## TODO
- [x] Multi-language native *(language filtering built into WET parsing + Configuration.languages)*
- [ ] Optimize the multilingual Model2Vec path (work on bytes without string materialization). *(Q: means skip String allocation, pass raw bytes to tokenizer?)*
- [x] Optimize `read!` in `src/wets.jl` to use block-based I/O (`readuntil!`) with pre-allocated buffers.
- [x] `test/benchmarks.jl` measures performance for each stage:
  - [x] wetURIs — URI struct channel throughput.
  - [x] wets — WET struct channel throughput.
  - [x] model2vec — similarity and distance calculation throughput.
  - [x] relevant! — filtering performance and allocation count under load.
  - [x] queue — ingestion and `best!` extraction speed of the frontier.
  - [x] llm — prompt construction overhead and end-to-end processing latency.
- [ ] Ensure tests don't reference large data sets, the data doesn't exist outside of test folder, and scope them small enough that they work with github actions *(tests currently pass locally, need to generate small test fixtures)*
  - [x] Ensure github actions runs the test suite.
- [x] Remove query from configuration. Add `Embedding(URI)` constructor that generates an embedding from a webpage.
- [x] WetURIs is ~200KB — can be downloaded entirely rather than streamed.
- [x] Fix progress bar time estimate (appears to always increase).
- [x] Pass `reasoning: off` in LLM API requests to skip thinking tokens.
- [ ] Investigate wrapping this inside of a docker container for easier install *(Q: priority?)*