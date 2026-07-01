# Keyword matching over WET content, backed by the native-Julia FastAhoCorasick package
# (https://github.com/D3MZ/FastAhoCorasick.jl). This replaces the former Rust `aho-corasick`
# FFI path: it is allocation-free in the match loop and, via single-thread multi-stream ILP,
# several times faster than the Rust crate on this workload (see test/benchmarks.jl).
#
# `AC{UInt32}` counts non-overlapping keyword matches; `AC{Float64}` sums per-keyword weights.
# Semantics match the previous Rust implementation: leftmost non-overlapping matches over raw
# UTF-8 bytes, ASCII case-insensitive.
import FastAhoCorasick
const _FAC = FastAhoCorasick

# Number of interleaved DFA streams for the ILP kernel. WET content is capped at `contentlimit`
# (12 KB), comfortably above the fallback threshold, so 8 streams apply on real records.
const AC_STREAMS = Val(8)

struct AC{T}
    automaton::_FAC.Automaton
end

function AC(keywords::Vector{<:AbstractString})
    AC{UInt32}(_FAC.build(collect(String, keywords)))
end

function AC(weights::AbstractDict{<:AbstractString,<:Real})
    patterns = collect(keys(weights))
    values = Float64[weights[pattern] for pattern in patterns]
    AC{Float64}(_FAC.build(collect(String, patterns); weights=values))
end

# No native resource to release (the automaton is GC-managed); kept for API compatibility
# with call sites that `close(matcher)` in a `finally`.
Base.close(entry::AC) = entry

score(entry::AC{UInt32}, pointer::Ptr{UInt8}, length::Integer) =
    _FAC.count_matches(entry.automaton, pointer, Int(length), AC_STREAMS)

score(entry::AC{Float64}, pointer::Ptr{UInt8}, length::Integer) =
    _FAC.sum_weights(entry.automaton, pointer, Int(length))

function score(entry::AC, text::AbstractString)
    GC.@preserve text score(entry, pointer(text), ncodeunits(text))
end
