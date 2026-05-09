# TODO

## Completed

- [x] Zero-allocation WET parsing
- [x] Aho-Corasick matching through Rust FFI
- [x] SimHash near-duplicate primitives
- [x] Model2Vec embedding scoring through Rust
- [x] Fixed-capacity `WETQueue`
- [x] Language-aware WET filtering
- [x] Multilingual embedding model support
- [x] Realtime waterfall dispatch in runnable scripts
- [x] LLM bootstrap prototype
- [x] OpenAI-compatible LLM integration

## Architecture
- [ ] Replace Configuration struct with a toml file.
- [ ] Convert keyword harvest from a streaming threshold filter to a competing `WETQueue`.
- [ ] Convert deduplication from a hard filter to a soft SimHash-ranked queue.
- [ ] Add deduplication to `scripts/live_march.jl`.
- [ ] Wire semantic scoring to pull from the keyword queue with `best!()`.
- [ ] Refactor `semantic()` into a streaming primitive.
- [ ] Add batch popping for `WETQueue`, such as `bestn!(queue, n)`.
- [ ] Generate multilingual keyword sets during bootstrap.

## Robustness

- [ ] Make bootstrap JSON extraction resilient to code fences and extra text.
- [ ] Merge bootstrap keywords with seed-page term weights in `scripts/live_march.jl`.
- [ ] Support multiple LLM consumers.
- [ ] Retry seed page fetches with exponential backoff.

## Testing and Packaging

- [ ] Add small self-contained WARC fixtures for CI.
- [ ] Continue optimizing Model2Vec scoring on raw bytes.