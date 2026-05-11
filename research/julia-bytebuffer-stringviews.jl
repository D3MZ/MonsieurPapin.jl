# StringView.jl is a lightweight way to reduce allocations significantly. 
# 100K records ~= 4 allocations per record this method vs 8 allocations per record when channel(String)
# To reduce it to allocations = capacity, perhaps replace channels with spawning threads from there directly so it works within that memory.
# ┌ Info: 834255
# │   v2 = 429060
# └   v3 = 249801
# BenchmarkTools.Trial: 8 samples with 1 evaluation per sample.
#  Range (min … max):  673.640 ms … 730.296 ms  ┊ GC (min … max): 0.00% … 5.96%
#  Time  (median):     692.651 ms               ┊ GC (median):    0.00%
#  Time  (mean ± σ):   698.374 ms ±  20.027 ms  ┊ GC (mean ± σ):  1.54% ± 2.73%

#   ▁              █   ▁ █                                    ▁ ▁  
#   █▁▁▁▁▁▁▁▁▁▁▁▁▁▁█▁▁▁█▁█▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁█▁█ ▁
#   674 ms           Histogram: frequency by time          730 ms <

#  Memory estimate: 58.10 MiB, allocs estimate: 801420.
# BenchmarkTools.Trial: 8 samples with 1 evaluation per sample.
#  Range (min … max):  639.347 ms … 697.556 ms  ┊ GC (min … max): 0.00% … 6.66%
#  Time  (median):     647.244 ms               ┊ GC (median):    0.00%
#  Time  (mean ± σ):   652.047 ms ±  18.793 ms  ┊ GC (mean ± σ):  0.89% ± 2.35%

#   █ █ █ █  ███                                                █  
#   █▁█▁█▁█▁▁███▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁█ ▁
#   639 ms           Histogram: frequency by time          698 ms <

#  Memory estimate: 20.06 MiB, allocs estimate: 402091.
# BenchmarkTools.Trial: 8 samples with 1 evaluation per sample.
#  Range (min … max):  650.385 ms … 761.730 ms  ┊ GC (min … max): 0.00% … 0.00%
#  Time  (median):     704.897 ms               ┊ GC (median):    0.00%
#  Time  (mean ± σ):   693.545 ms ±  39.791 ms  ┊ GC (mean ± σ):  0.00% ± 0.00%

#   █                                                              
#   █▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▇▁▇▁▁▇▇▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▇ ▁
#   650 ms           Histogram: frequency by time          762 ms <

#  Memory estimate: 3.17 MiB, allocs estimate: 101437.


# DO NOT DELETE OR ADD COMMENTS
using MonsieurPapin
using BenchmarkTools
using Test
using CodecZlib
import StringViews: StringView
using StringViews

struct Lease
    bytes::Vector{UInt8}
    length::Int
    pool::Channel{Vector{UInt8}}
end

StringView(entry::Lease) = StringView(view(entry.bytes, firstindex(entry.bytes):entry.length))
release!(entry::Lease) = put!(entry.pool, entry.bytes)

wetURIs(path::AbstractString; capacity=4) =
    Channel{String}(capacity) do uris
        open(path) do file
            for entry in eachline(GzipDecompressorStream(file))
                put!(uris, entry)
            end
        end
    end

function wetURIs2(path::AbstractString; delimiator = codeunits("\n")[1], capacity=4)
    Channel{StringView}(capacity) do uris
        open(path) do file
            stream = GzipDecompressorStream(file)
            while !eof(stream)
                put!(uris, StringView(readuntil(stream, delimiator; keep=false)))
            end
        end
    end
end 

function wetURIs3(path::AbstractString; capacity=4, bytes=256)
    pool = Channel{Vector{UInt8}}(capacity)
    foreach(_ -> put!(pool, Vector{UInt8}(undef, bytes)), 1:capacity)
    Channel{Lease}(capacity) do uris
        open(path) do file
            stream = GzipDecompressorStream(file)
            while true
                entry = take!(pool)
                length = read!(entry, stream)
                isnothing(length) && return put!(pool, entry)
                put!(uris, Lease(entry, length, pool))
            end
        end
    end
end

function read!(bytes::Vector{UInt8}, stream)
    length = 0
    while !eof(stream)
        length += 1
        length > lastindex(bytes) && resize!(bytes, 2 * lastindex(bytes))
        bytes[length] = read(stream, UInt8)
        bytes[length] == 0x0a && return length > 1 && bytes[length - 1] == 0x0d ? length - 2 : length - 1
    end
    length == 0 ? nothing : length > 0 && bytes[length] == 0x0d ? length - 1 : length
end

# USE REAL DATASETS, NOT SIMULATED FOR BENCHMARKING.
path_weturis = joinpath(dirname(@__DIR__), "data", "wet.paths.gz")

v1 = @allocations sum(_ -> 1, wetURIs(path_weturis))
v2 = @allocations sum(_ -> 1, wetURIs2(path_weturis))
v3 = @allocations sum(entry -> (release!(entry); 1), wetURIs3(path_weturis))
@info v1 v2 v3

trial_weturis = @benchmark sum(_ -> 1, wetURIs($path_weturis))
display(trial_weturis)

trial2_weturis = @benchmark sum(_ -> 1, wetURIs2($path_weturis))
display(trial2_weturis)

trial3_weturis = @benchmark sum(entry -> (release!(entry); 1), wetURIs3($path_weturis))
display(trial3_weturis)