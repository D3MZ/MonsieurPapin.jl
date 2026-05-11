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
- [ ] Convert keyword harvest from a streaming threshold filter to a competing `WETQueue`.
- [ ] Convert deduplication from a hard filter to a soft SimHash-ranked queue.
- [ ] Wire semantic scoring to pull from the keyword queue with `best!()`.
- [ ] Refactor `semantic()` into a streaming primitive.
- [ ] Add batch popping for `WETQueue`, such as `bestn!(queue, n)`.

## Robustness

- [ ] Support multiple LLM consumers.
- [ ] Retry seed page fetches with exponential backoff.

## Testing and Packaging

- [ ] Add small self-contained WARC fixtures for CI.
- [ ] Continue optimizing Model2Vec scoring on raw bytes.

## Performance

- [ ] Reduce wets parsing from ~26 to ~8 allocs/record. Commit `89521f6` replaced byte-by-byte `read!` with `readuntil`, adding ~2-3 allocs per header line (18 extra allocs/record). The old zero-alloc `read!` lives on `feature/multi-stage-pipeline`. Reverting would trim allocations without code duplication — tradeoff is per-character read overhead vs block reads.