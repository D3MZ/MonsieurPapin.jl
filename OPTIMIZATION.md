# Performance Optimization Plan

## Current State
- Network: 1.4 kB/s (should be 500+ Mbps)
- CPU: 127% (embedding model active)
- Progress: 0% after 31 min, ETA 52 days (should be <1 day)
- Channel buffer: 1000 (raw) → 20 (harvest) → semantic

## Suspected Issues (ordered by likelihood)

### 1. collect() corrupts StringView URIs
`wetURIs()` returns Channel{StringView} pointing into gzip buffer.
`collect()` on Channel materializes items. If buffer is freed before
all StringViews are consumed, URIs become garbage → wets() gets
garbage paths → HTTP returns 404 or hangs → loop retries/timeout.
FIX: collect into Vector{String} not StringView.

### 2. Single-threaded download bottleneck
Downloads are sequential: one WET file at a time. 100K WET files
at 65MB each on gigabit = ~14 hours of pure download.
FIX: spawn N download threads, each consuming from URI channel.

### 3. Channel backpressure chain
semantic scoring (slow) → harvest output full (cap 20) → harvest blocked →
raw channel full (cap 1000) → download blocked.
FIX: decouple stages with larger buffers; don't block download on scoring.

### 4. BufferedInputStream buffer too small
HTTP.jl default buffer might be too small for efficient gzip streaming.
FIX: increase buffer size or use raw socket.

### 5. GzipDecompressorStream overhead
Decompressing each WET file inline on the download thread.
FIX: decompress on worker threads, not download thread.

### 6. SimHash dedup on every page
harvest() runs simhash on every page. For millions of pages this adds up.
FIX: make dedup optional or batch it.

## Steps
1. Fix StringView → String in collect
2. Add download concurrency
3. Monitor network throughput after each change
4. Check feature branch for missed patterns
