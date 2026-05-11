# Conventions

## No defensive programming
- No try-catch blocks
- No fallback values or default branches
- No `get(dict, key, default)` — index directly with `dict["key"]`
- No `isnothing` checks — let errors propagate
- No empty string returns — if data is missing, let it error

## Settings
- All configuration lives in `settings.toml` at the project root
- Loaded via `loadsettings()` which returns a plain `Dict`
- Access with `settings["section"]["key"]` — never with fallback defaults

## No helper wrappers for simple API calls
- Use `request()` directly instead of wrapping in convenience functions
- Each caller provides its own prompts inline or from `settings["prompts"]`

## LLM
- `request()` in `src/llm.jl` sends POST to OpenAI-compatible API, returns parsed JSON

## Research folder
- `research/` contains benchmark notes, micro-benchmarks, and performance experiments
- These files are reference material; do not delete them
- They do not need to be kept up to date with the current codebase

### Performance insights from research benchmarks

**Channels** (`julia-channels.jl`)
- Buffered typed channels: ~41 ns put/take, zero allocation, flat across thread count
- Unbuffered Channel(0): ~15-118 μs — rendezvous synchronization is 350-2500x slower
- Always use `Channel{T}(capacity)` for hot paths; never use unbuffered channels in throughput-sensitive code
- Typed channels eliminate boxing allocations even for non-isbits types

**IO and streaming** (`julia-io.jl`, `julia-gunzipstreams.jl`, `julia-bytebuffer-wets.jl`)
- `eachline` costs ~5 allocs per line (raw) / ~6.2 (gzip) — scales linearly, no surprises
- View-based WET parsing from a single decompressed byte buffer: 19 allocs total for 21K records (zero per-record)
- `@view` on span tuples is allocation-free (~15 μs for content, ~30 μs for all fields)
- Tradeoff: parent byte buffer must outlive all records — not suitable for long-lived record retention
- Original naive WET parsing: 756 allocs for 25 records. Span+view approach: 23 allocs (only stream overhead)

**StringView and buffer reuse** (`julia-bytebuffer-stringviews.jl`)
- `StringView` from `readuntil`: 4 allocs per record vs 8 for `String` via `eachline`
- Lease pool (pre-allocated byte buffers recycled via Channel): ~3 MiB total for 100K records
- For paths like `wet.paths.gz` where each line is a URI, `readuntil` + `StringView` halves allocations

**Queue insertion strategy** (`julia-queues.jl`, `julia-queues-benchmark.jl`)
- Precheck (compare before push): 6-8x faster than always-insert-then-pop-worst
- `BinaryMinMaxHeap` stays allocation-free for scalar `Float64` even with lock
- For full `WET` payload: precheck still wins but now allocates (~6K allocs for 10K inserts — struct is non-isbits)
- Lock adds ~2.5x on bare precheck but still well under unconditional cost
- 8-thread contention scales linearly; precheck reduces lock hold time proportionally

**Scoring backends** (`julia-fasttext-vs-model2vec-relevant-benchmark.jl`)
- Three backends benchmarked: Julia fastText, Rust subprocess (stdin/stdout pipe), Rust in-process (ccall shared lib)
- All produce identical scores; in-process ccall won on throughput
- Current backend (`deps/model2vec_rs_worker/`) uses thread-per-core shared library with batched scoring
- Batch scoring amortizes ccall overhead; batch size 64 was used in benchmarks

## Known design decisions (do not recommend changing)
- `queue.jl` `pop!()` is O(n) — linear scan for best element. This is intentional. Extraction is rare (tens to hundreds of calls vs millions of inserts). The insert hot path is zero-allocation O(log n). Two-heap / min-max-heap alternatives were benchmarked and regressed insert throughput 3x while adding allocation overhead. Do not re-recommend.