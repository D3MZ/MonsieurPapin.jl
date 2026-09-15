# TODO

The core waterfall, configured backend boundary, and subscription telemetry path are complete. The remaining items are operational or optional extensions.

## Completed

### Architecture

- [x] SimHash-keyed, bounded, score-aware deduplication keeps the higher-scoring duplicate.
- [x] Local HTTP and persistent Pi RPC clients share `LLMBackend`, `request`, `message`, error propagation, and `close` semantics.
- [x] Persistent Pi uses one process per configured `llm.parallel` worker; logical calls are dispatched round-robin.
- [x] All pipeline stages use bounded priority queues and the shared configured concurrency.

### Configuration

- [x] `settings.toml` is parsed once at `example.jl`'s outer boundary.
- [x] Runtime functions receive plain parsed `Dict` sections; no monolithic settings type or internal settings loader.
- [x] Local LLM, Pi, Codex app-server usage, crawl retry, pipeline, and quality settings live in the TOML hierarchy.
- [x] The default final funnel is `openai-codex` with the account-supported `gpt-5.5`; `gpt-5.3-codex-spark` is rejected by this ChatGPT account, so the live run uses `gpt-5.5`.

### Subscription-backed LLM

- [x] Persistent Pi RPC uses the configured provider/model and has one process per worker.
- [x] Codex app-server `account/rateLimits/read` is sampled every five seconds without making an LLM request.
- [x] JSONL usage entries include timestamps, logical calls, provider attempts, response usage, active windows, remaining percentages, and reset times.
- [x] New work stops when an active window rises by 10 percentage points from its run-start baseline; an in-flight call may finish.
- [x] The log records an observed calls-per-percentage-point estimate; it is workload-dependent, not a subscription quota.

### Reliability and quality

- [x] Seed-page and live WET index/archive fetching use HTTP.jl's configured exponential retry layer.
- [x] Missing data propagates naturally; no production `try/catch`, `haskey`, or default-valued `get` access remains.
- [x] Core tests cover persistent Pi RPC, Codex rate-limit RPC, usage sampling, and score-aware deduplication.
- [x] The test suite enforces the configured complexity ceiling and source-level fallback checks.
- [x] Small self-contained WARC fixtures are present for ordinary CI.

## Remaining work

### Operations

- [ ] Add crash checkpoint/resume for multi-day runs, including pipeline and usage-log state.
- [x] Validate the complete subscription run on `z13` against two actual WET archives with the authenticated Codex subscription; the repaired run completed 159-language keyword sweep (2,460 terms), 18 GPT-5.5 extraction calls, one retained finding, and clean teardown. The first retry attempt established that Spark is unsupported for this ChatGPT account.
- [ ] Commit/push only the validated changes to `main` and synchronize the other checkout.

### Opt-in integration testing

- [x] Add an explicitly enabled, authenticated integration test that runs two real WET archives through parsing, filtering, deduplication, embedding, and extraction. Ordinary CI remains subscription-free (`test/codex_integration.jl run`).
- [x] Identify two actual WET archive URLs from `wet.paths.gz` and stream them in the opt-in integration test; the path index itself is not treated as a WET archive.

### Performance experiments

- [ ] Benchmark an optional lease-pool implementation for `wetpaths` URI buffers; keep it only if it preserves ownership semantics and improves the measured workload.
- [ ] Continue Model2Vec/raw-byte optimization only when a benchmark demonstrates a regression or measurable gain.

### Release follow-up

- [ ] Publish generated API/configuration documentation after the next validated `z13` run.
