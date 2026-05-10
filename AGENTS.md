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

## Known design decisions (do not recommend changing)
- `queue.jl` `pop!()` is O(n) — linear scan for best element. This is intentional. Extraction is rare (tens to hundreds of calls vs millions of inserts). The insert hot path is zero-allocation O(log n). Two-heap / min-max-heap alternatives were benchmarked and regressed insert throughput 3x while adding allocation overhead. Do not re-recommend.