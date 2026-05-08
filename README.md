# MonsieurPapin

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://D3MZ.github.io/MonsieurPapin.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://D3MZ.github.io/MonsieurPapin.jl/dev/)
[![Build Status](https://github.com/D3MZ/MonsieurPapin.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/D3MZ/MonsieurPapin.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/D3MZ/MonsieurPapin.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/D3MZ/MonsieurPapin.jl)

> A French Huguenot physicist, mathematician and inventor, best known for his pioneering invention of the steam digester, the forerunner of the pressure cooker, the steam engine, the centrifugal pump, and a submersible boat. — [Wikipedia](https://en.wikipedia.org/wiki/Denis_Papin)

Not your ordinary digester: search the entire internet and summarize into a research-grade markdown file, entirely on your computer, in a day or your money back. :)

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

- [ ] Optimize the multilingual Model2Vec path (work on bytes without string materialization).
- [ ] `Model2Vec` coarse filter to work on bytes without string materialization.
- [ ] Optimize `read!` in `src/wets.jl` to use block-based I/O (`readuntil!`) with pre-allocated buffers.
- [x] `test/benchmarks.jl` measures performance for each stage:
  - [x] wetURIs — URI struct channel throughput.
  - [x] wets — WET struct channel throughput.
  - [x] model2vec — similarity and distance calculation throughput.
  - [x] relevant! — filtering performance and allocation count under load.
  - [x] queue — ingestion and `best!` extraction speed of the frontier.
  - [x] llm — prompt construction overhead and end-to-end processing latency.
- [ ] Remove query from configuration. Add `Embedding(URI)` constructor that generates an embedding from a webpage.
- [ ] WetURIs is ~200KB — can be downloaded entirely rather than streamed.
- [ ] Fix progress bar time estimate (appears to always increase).
- [ ] Pass `reasoning: off` in LLM API requests to skip thinking tokens.
