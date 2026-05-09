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

> **Note:** This is still in active pre-release development. The sections below describe the **target architecture**. See [Roadmap](#roadmap) for the gap between current implementation and vision.

Public Release Milestones
- [ ] 0/8 full searches completed
- [ ] 0/5 machines tested on
- [ ] 0/3 Major OSs (i.e. Latest Windows, MacOS, & Linux)
- [ ] Confirmed that different languages can be used in sources.

## Vision

MonsieurPapin is a **4-stage fixed-capacity waterfall pipeline** that filters the Common Crawl through increasingly expensive scoring stages. Every stage is a competing priority queue — not a streaming channel filter. Pages enter a stage, are scored, and either earn a spot in the queue or are discarded. When the queue is full, the lowest-scoring page is evicted. The next stage always pulls the **best** item from the previous queue.

This means the embedding scorer only ever sees the top-K keyword matches, and the LLM only ever sees the top-K embedding matches. No stage wastes cycles on pages already outranked by better candidates.

```
                       ┌──────────────────────────────────┐
                       │     BOOTSTRAP (one-time)         │
                       │  LLM analyzes example sites      │
                       │  → multilingual keywords + query │
                       └──────────────┬───────────────────┘
                                      │ seeds stages 2 & 3
                                      ▼
Common Crawl WET Archive (6 TiB / 2.1B pages)
              │
    ┌─────────▼──────────┐
    │  STAGE 1            │  Deduplication Queue
    │  SimHash fingerprint│  Near-duplicates get low scores
    │  Fixed-capacity Q   │  Evict worst if full
    │  Rank: uniqueness   │  → best original content survives
    └─────────┬──────────┘
              │ best!() from dedup queue
    ┌─────────▼──────────┐
    │  STAGE 2            │  Multilingual Keyword Queue
    │  Aho-Corasick (Rust)│  Keywords from LLM bootstrap
    │  Fixed-capacity Q   │  Scores page → insert → evict worst
    │  Rank: keyword hits │  → best keyword-matched pages
    └─────────┬──────────┘
              │ best!() from keyword queue
    ┌─────────▼──────────┐
    │  STAGE 3            │  Embedding Similarity Queue
    │  Model2Vec (Rust)   │  Cosine distance to example sites
    │  Fixed-capacity Q   │  Scores page → insert → evict worst
    │  Rank: similarity   │  → best semantically-similar pages
    └─────────┬──────────┘
              │ best!() from embedding queue
    ┌─────────▼──────────┐
    │  STAGE 4            │  AI Research Queue
    │  LLM (OpenAI API)   │  LLM reads page, decides to include
    │  Multiple consumers │  → writes findings to research.md
    │  Rank: AI relevance │
    └─────────┬──────────┘
              │
    ┌─────────▼──────────┐
    │  research.md        │  Appended in real-time
    └────────────────────┘
```

### Key architectural principles

1. **Every stage is a fixed-capacity queue, not a channel.** No stage streams — each maintains a bounded priority queue. If the queue is full, the worst item is evicted.
2. **Each stage pulls `best!()` from the previous queue.** The semantic scorer never sees all keyword-matched pages — only the best ones that survived stage 2's queue.
3. **Deduplication is a soft filter, not a hard drop.** Near-duplicates receive low scores and compete with originals — the best version of near-duplicate content survives.
4. **Keywords are multilingual and LLM-generated.** The bootstrap step sends example site content to the LLM and asks for relevant keywords across languages. This generalizes far better than raw TF-IDF from seed pages.
5. **The LLM can be called thousands of times.** OpenAI-compatible API with `reasoning: off`. Multiple LLM consumers can run in parallel if multiple models/GPUs are available.

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

## How it works (target architecture)

The pipeline has two phases: a one-time **bootstrap** that analyzes example sites, then a continuous **waterfall** of four competing queues.

### Phase 0: Bootstrap

1. User provides a **task** (e.g. "Find trading strategies with clear entry/exit rules"), an **OpenAI-compatible API endpoint**, and **2-4 example URLs** that represent the kind of content to find.
2. The system fetches the example sites, extracts their text, and sends the content + task to the LLM.
3. The LLM returns JSON with two fields:
   - `keywords`: 50 highly specific terms in **multiple languages** (the LLM translates domain terminology based on the configured language list).
   - `query`: a 1-sentence semantic description used as the embedding target.
4. These seed the Aho-Corasick automaton (stage 2) and the Model2Vec query vector (stage 3).

### Phase 1: Waterfall pipeline

**Ingest** — Common Crawl WET archive is streamed over HTTP, decompressed on-the-fly, and parsed into zero-allocation `WET` structs. Language filtering (via `WARC-Identified-Content-Language` header) drops pages in unsupported languages immediately. ~25K pages/s.

**Stage 1 — Deduplication Queue.** Each page is hashed with SimHash (64-bit, 3-gram shingles). Pages with fingerprints close to an existing one get a low score; unique pages get a high score. This is a **fixed-capacity queue**: if the queue is full, the lowest-scoring page is evicted. The next stage pulls `best!()` — the most unique content.

> *Why a queue, not a filter?* A hard dedup filter drops all duplicates, which is correct for exact copies. But near-duplicate content (syndicated articles, slightly edited versions) should *compete* — the best version survives, not the first one seen.

**Stage 2 — Multilingual Keyword Queue.** The Aho-Corasick automaton (built from LLM-generated keywords in Rust) scores each page pulled from the dedup queue. Pages with many keyword hits across languages score high. This is a **fixed-capacity queue**: only the best keyword-matched pages survive. Stage 3 pulls `best!()` — the top keyword candidates.

> *Why multilingual?* Common Crawl spans ~100 languages. A trading strategy in Japanese, Russian, or Portuguese is as valuable as one in English. The LLM generates the keyword list in all configured languages during bootstrap — Japanese pages match against Japanese keywords, Russian pages against Russian keywords, etc.

**Stage 3 — Embedding Similarity Queue.** Model2Vec (`potion-multilingual-128M`, 100+ languages) computes cosine distance between each page (pulled from the keyword queue's best) and the bootstrap query vector. Pages semantically similar to the example sites score high. This is a **fixed-capacity queue**: only the most semantically similar pages survive. Stage 4 pulls `best!()` — the top semantic matches.

> *Why a queue here?* Embedding scoring is ~1000× more expensive than keyword matching. The keyword queue ensures only the top K keyword candidates reach this stage, rather than every page that cleared the keyword threshold.

**Stage 4 — AI Research Queue.** The LLM (OpenAI-compatible chat API, `reasoning: off`) reads each page pulled from the embedding queue's best. It decides whether the content matches the research task and, if so, extracts a structured summary (name, description, source URL, pseudo-code). If the page is irrelevant, the LLM returns `{"skip": true}` and the slot is freed for the next candidate. Results are appended to `research.md` in real-time.

> *Why a queue for the LLM stage?* The LLM is the most expensive stage (~100× slower than embeddings). Multiple LLM consumers can pull from the same queue in parallel if multiple models/GPUs are available. The queue decouples LLM throughput from embedding throughput.

### Throughput profile (target)

| Stage     | Technology                       | Speed            | Queue capacity | Selectivity         |
|-----------|----------------------------------|------------------|----------------|---------------------|
| Ingest    | Julia streaming I/O + gzip       | ~25K pages/s     | —              | 2.1B → 2.1B         |
| Stage 1   | SimHash (64-bit, 3-gram)         | —                | 100K           | 2.1B → ~1B unique   |
| Stage 2   | Rust Aho-Corasick (multilingual) | —                | 100K           | ~1B → 100K          |
| Stage 3   | Rust Model2Vec `scorebatch!`     | ~2.5K pages/s    | 1K             | 100K → 1K           |
| Stage 4   | LLM via HTTP API                 | ~0.1-0.5 pages/s | —              | 1K → ~100 docs      |

> **Critical:** In the current implementation, stage 2 is a streaming threshold filter (not a queue), so stage 3 sees ~100M pages instead of ~100K. Moving to a queued architecture would make the embedding stage **1000× more selective**.

## Current implementation

### What to expect

- The first keyword candidate should appear within ~40 seconds
- The first LLM extraction request follows a few seconds later
- Two progress bars show: `WET files` (100K total) and a page counter
- `research.md` grows in real-time as the LLM finds relevant pages
- A full crawl takes ~4 days at typical home broadband speeds

### Entry points

- **`example.jl`** — Demonstrates a 4-stage pipeline with **deduplication** (SimHash via `Deduper{CircularBuffer}`), `harvest()` keyword channel, `relevant!()` embedding scoring, `WETQueue` shortlist, and concurrent LLM dispatch. Includes `bootstrap()` for LLM-generated keywords and query.
- **`scripts/live_march.jl`** — The primary script. Uses weighted Aho-Corasick from seed page weights (no bootstrap step), omits the dedup stage, and sends results through the same semantic → shortlist → LLM pipeline.

Both pipelines converge on the same core bottleneck: the WETQueue + LLM waterfall at the end.

## Models required

| Model | Type | How it's loaded |
|---|---|---|
| `minishlab/potion-multilingual-128M` | Embedding (Model2Vec) | Auto-downloaded from HuggingFace by the Rust worker on first run |
| Any OpenAI-compatible chat LLM | Chat / extraction | Must be running separately at the configured base URL (default `http://localhost:1234`) |

Configure the LLM endpoint and model name in `src/core.jl` (`baseurl`, `path`, `model`).

## Design decisions

- **Fixed-capacity waterfall queues** — every stage is a competing priority queue, not a channel. No stage sees more pages than its queue capacity; expensive stages only process the best survivors.
- **LLM-driven bootstrap** — keywords and query are generated by the LLM from example sites, in multiple languages. This generalizes far better than raw TF-IDF.
- **Soft deduplication** — near-duplicates compete with originals via SimHash distance scoring. The best version survives, not the first one seen.
- **Staged filtering** — cheap filters (SimHash, Aho-Corasick) eliminate 99.9999% of pages before the LLM sees them.
- **Zero-allocation WET parsing** — WARC records parsed into fixed-size structs with no heap allocations.
- **Rust FFI for hot paths** — Aho-Corasick matching and embedding similarity run in a Rust shared library (`deps/model2vec_rs_worker`).
- **Live output** — `research.md` is appended in real-time; results appear while the crawl runs.
- **Language-aware** — filter by Common Crawl language codes; multilingual embedding model supports 100+ languages natively.

## Known Issues (current implementation)

1. **JULIA_NUM_THREADS defaults to 1** — the pipeline uses `Threads.nthreads()` for parallelism. Set `export JULIA_NUM_THREADS=auto` (or a specific count) before running. On a 24-core machine this means `export JULIA_NUM_THREADS=24`.
2. **Bootstrap JSON parsing fragility** — `bootstrap()` calls the LLM for keywords + query, but the LLM often wraps its output in markdown fences or includes `thinking` blocks. The `stripjson()` fallback is fragile.
3. **`semantic()` in `core.jl` blocks** — the library function `semantic()` drains the entire candidate channel before returning. `example.jl` works around this with the waterfall dispatch pattern, but the library API still blocks.

## Roadmap

### ✅ Completed

- [x] **Zero-allocation WET parsing** — WARC records parsed into fixed-size `WET{U,C,L}` structs with no heap allocations per record.
- [x] **Aho-Corasick via Rust FFI** — `RustWorker.AC` builds an AC automaton from keywords or weighted keywords. `score()` runs byte-level matching on `WET` content directly via pointer + length (no String allocation).
- [x] **SimHash near-duplicate detection** — `simhash()` computes 64-bit fingerprints from 3-gram shingles. `Deduper` wraps a `CircularBuffer` + `Set{UInt64}` sliding window (capacity 100K).
- [x] **Model2Vec embeddings** — `RustWorker.Model` loads `potion-multilingual-128M` from HuggingFace. `scorebatch!()` scores batches of `WET` content pointers in Rust, returning cosine distances. Batch size 64, one task per thread.
- [x] **WETQueue fixed-capacity priority queue** — wraps `DataStructures.BinaryHeap` with `ReverseOrdering(By(score))`. `insert!()` evicts the worst item when over capacity. `best!()` pops the minimum-distance (highest-similarity) item.
- [x] **Language-aware WET filtering** — parses `WARC-Identified-Content-Language` header. `Configuration.languages` defaults to 10 languages; pages are skipped if none match.
- [x] **Multilingual embedding model** — `potion-multilingual-128M` supports 100+ languages natively. Rust worker scores raw bytes without String materialization.
- [x] **Real-time waterfall dispatch** — LLM consumer runs in background task. As semantically-scored items arrive, the best is popped from WETQueue and sent to the LLM while scoring continues concurrently.
- [x] **Bootstrap via LLM** — `bootstrap()` fetches seed URLs, sends their content + task description to the LLM, and parses JSON response for `keywords` (50 terms) and `query` (1-sentence).
- [x] **OpenAI-compatible LLM integration** — `complete()` POSTs `{model, system_prompt, input}` with `reasoning: off`. `extract_content()` deeply walks response JSON to find text in any API format variant.

### 🏗️ Core architecture gaps (current → vision)

- [ ] **Convert stage 2 from streaming filter to competing queue.**
  Harvest is currently a streaming threshold filter: every keyword-matched page above the gate passes through immediately. It must become a fixed-capacity `WETQueue` where pages compete on keyword match score, the worst are evicted, and the semantic stage pulls `best!()` rather than consuming the entire channel.
  - **Impact:** Currently the semantic stage sees everything that passes the keyword gate (~100M pages). With a queue (e.g. capacity 100K), only the best keyword-matched pages reach the far more expensive embedding stage. **~1000× reduction in embedding workload.**
  - **Requires:** Refactor `harvest()` in both `live_march.jl` and `core.jl` to push into a `WETQueue` keyed by keyword score. Wire a pull-based consumer into the semantic stage.
  - **Files:** `src/core.jl` (`harvest()`), `scripts/live_march.jl` (`harvest()`), `example.jl`

- [ ] **Convert deduplication from hard filter to soft queue.**
  `Deduper` currently uses a `CircularBuffer` + `Set` — exact duplicates are dropped, near-duplicates are not detected. It must become a `WETQueue` where SimHash distance scores pages, near-duplicates get low scores, and the best version of near-duplicate content survives via eviction.
  - **Impact:** Currently, the first version of syndicated content wins and all slightly-different copies are dropped. A soft queue lets better versions (fuller text, better formatting) outrank earlier copies.
  - **Requires:** Transform `Deduper` into a `WETQueue`-based stage. Replace the `Set` membership check with Hamming distance scoring on SimHash fingerprints.
  - **Files:** `src/simhash.jl`, `src/core.jl` (`harvest()` dedup path)

- [ ] **Add dedup stage to `live_march.jl`.**
  The primary entry point has no dedup at all. `example.jl` has it (as a hard filter), but `live_march.jl` skips it entirely. Duplicate pages waste keyword scoring, embedding scoring, and LLM capacity.
  - **Files:** `scripts/live_march.jl`

- [ ] **Wire stage 3 to pull from stage 2's queue via `best!()`.**
  Semantic scoring (`relevant!`) currently consumes a `Channel{WET}` containing all keyword-passing pages. Once stage 2 is a queue, semantic must pull from it via `best!()` rather than iterating the channel.
  - **Impact:** The embedding scorer only processes the top-K keyword candidates instead of every keyword match.
  - **Files:** `src/scoring.jl` (`relevant!()`), `src/core.jl` (`semantic()`), `scripts/live_march.jl` (`semantic()`), `example.jl`

- [ ] **Refactor `semantic()` into a streaming primitive.**
  The library function `semantic(config, entries)` drains the entire candidate channel before returning a filled `WETQueue`. The waterfall pattern in `example.jl` and `live_march.jl` works around this by doing LLM dispatch in the main loop alongside `relevant!()`, but the library function itself is not streaming-friendly.
  - **Fix:** Make `semantic()` accept a consumer callback, or return a `Channel` of scored items that yields as soon as items clear the threshold.
  - **Files:** `src/core.jl` (`semantic()`)

- [ ] **Make `best!()` support batch pop.**
  `best!()` calls `pop!()` which scans the internal `valtree` for the best element, deletes it, then calls `heapify!`. This is O(n) for each pop. With batch processing (`bestn!(queue, n)`), the heapify could be deferred until all n items are consumed.
  - **Fix:** Add a `bestn!(queue, n)` that collects the top-n items without re-heapifying between each pop.
  - **Files:** `src/queue.jl`

- [ ] **Add multilingual keyword support to bootstrap.**
  The LLM bootstrap currently generates keywords in whatever language the LLM defaults to. It should explicitly generate keywords in each configured language so that non-English content is matched by native-language keywords.
  - **Requires:** Update the bootstrap prompt to include the configured languages list. Generate per-language keyword sets. Build one AC automaton per language, or tag keywords with language codes and filter at match time.
  - **Files:** `src/core.jl` (`bootstrap()`)

### 🔧 Quality & robustness

- [ ] **Robust bootstrap JSON extraction.**
  `stripjson()` naively grabs text between the first `{` and last `}`. Fails if the LLM outputs markdown code fences or includes nested braces in examples. The fallback query is hardcoded rather than context-aware.
  - **Fix:** Add a regex-based JSON extractor that handles code fences. Add a retry loop with a stricter system prompt when parsing fails.
  - **Files:** `src/llm.jl` (`stripjson()`), `src/core.jl` (`bootstrap()`)

- [ ] **Merge bootstrap keywords with seed-page weights in `live_march.jl`.**
  Unlike `example.jl` which calls `bootstrap()`, `live_march.jl` computes `MonsieurPapin.weights(seedtext)` to build a weighted AC directly from term frequency in seed pages. This skips the LLM's ability to generalize to synonyms, translations, and related terms.
  - **Mitigation:** Run `bootstrap()` in `live_march.jl` and merge LLM keywords with seed-page weights for a hybrid approach.
  - **Files:** `scripts/live_march.jl`

- [ ] **Multiple LLM consumers for stage 4.**
  Both entry points use one `Threads.@spawn` consumer for LLM requests. With a fast LLM (or multiple GPUs), the LLM stage is the bottleneck at ~0.1 pages/s. Multiple consumers (one per GPU or per model shard) would increase throughput linearly.
  - **Fix:** Spawn N consumers, each pulling from the same request channel. Make consumer count configurable.
  - **Files:** `example.jl`, `scripts/live_march.jl`

- [ ] **Retry seed page fetches with exponential backoff.**
  `fetchseed()` has a 30s timeout but no retry. A transient network failure during bootstrap causes the entire pipeline to proceed without keywords or query.
  - **Files:** `src/core.jl` (`fetchseed()`)

### 🧪 Testing & infrastructure

- [ ] **Generate small test fixtures.** Tests currently pass locally but reference Common Crawl data. Need small, self-contained WARC fixtures for CI.
  - **Files:** `test/data/`, `test/runtests.jl`

- [ ] **Docker packaging.** Investigate reproducible builds with Docker, including Rust cross-compilation for the FFI worker.

- [ ] **Model2Vec optimization.** Work on raw bytes without String materialization in the embedding path.
  - **Files:** `deps/model2vec_rs_worker/`
