# TODO

## Completed

- [x] Zero-allocation WET parsing
- [x] Aho-Corasick matching through Rust FFI
- [x] SimHash near-duplicate primitives
- [x] Model2Vec embedding scoring through Rust
- [x] Fixed-capacity bounded priority queue (`BoundedPriorityQueue`)
- [x] Language-aware WET filtering
- [x] Multilingual embedding model support
- [x] Realtime waterfall dispatch in runnable scripts
- [x] LLM bootstrap prototype
- [x] OpenAI-compatible LLM integration
- [x] Unify both `research()` entry points on one set of composable stages (`filter`/`select`).
- [x] Convert keyword harvest from a streaming threshold filter to a bounded priority queue (`BoundedPriorityQueue`).
- [x] Wire embedding scoring to pull from the keyword shortlist (streaming `select`, `take!`).
- [x] Refactor the embedding stage into a single streaming primitive (`select(::Embedding, …)`).
- [x] Generic, thread-safe, iterable `BoundedPriorityQueue{T}` as the single inter-stage primitive.

## Architecture
- [ ] Convert deduplication from a windowed `unique(::SeenSet, …)` into a SimHash-keyed bounded
      priority queue, so the higher-scoring of two near-duplicates is kept rather than dropped.

## Robustness

- [ ] Support multiple LLM consumers.
- [ ] Retry seed page fetches with exponential backoff.
- [ ] Concurrent multi-file download (currently `wets(paths::Channel)` is sequential — the
      dominant wall-clock cost on a full crawl).
- [ ] Checkpoint/resume across crashes for multi-day runs.

## Testing and Packaging

- [ ] Add small self-contained WARC fixtures for CI.
- [ ] Continue optimizing Model2Vec scoring on raw bytes.

## Performance

- [x] Restore allocation-free WET header parsing (`read!` reads into a reused buffer instead of
      allocating a fresh array per line via `readuntil`).
- [ ] Optional `Lease`-pool buffer reuse in `wetpaths` (research shows ~70% fewer allocations).