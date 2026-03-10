# DO ADD OR REMOVE COMMENTS FROM THIS FILE
using MonsieurPapin, BenchmarkTools, Test

# USE REAL DATASETS, NOT SIMULATED FOR BENCHMARKING.
path_weturis = joinpath(dirname(@__DIR__), "data", "wet.paths.gz")
path_wets = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
path_vectors = joinpath(dirname(@__DIR__), "data", "wiki-news-300d-1M.vec")

count(iterable) = sum(_ -> 1, iterable)
rate(iterable, seconds) = round(count(iterable) / seconds)

@testset "benchmarks" begin
    @testset "wetURIs" begin
        trial_weturis = @benchmark sum(_ -> 1, wetURIs($path_weturis))
        time_weturis = BenchmarkTools.median(trial_weturis).time / 1e9
        display(trial_weturis)
        @test trial_weturis.allocs <= 5 * 100_000 # less than 5 allocations per record (at 100K records)
        uris_per_second = rate(wetURIs(path_weturis), time_weturis)
        @info "Benchmarking wetURIs (paths)" uris = count(wetURIs(path_weturis)) uris_per_second = uris_per_second
    end

    @testset "wets" begin
        trial_wets = @benchmark sum(_ -> 1, wets($path_wets))
        time_wets = BenchmarkTools.median(trial_wets).time / 1e9
        display(trial_wets)
        @test trial_wets.allocs <= 600_000 # less than 6 allocations per record
        records_per_second = rate(wets(path_wets), time_wets)
        @info "Benchmarking wets (records)" records = count(wets(path_wets)) records_per_second = records_per_second
        @test records_per_second >= 25_000
    end

    @testset "relevant!" begin
        source = embedding("cat dog"; vecpath=path_vectors)
        trial_relevant = @benchmark sum(_ -> 1, relevant!($source, wets($path_wets); threshold=0.0))
        time_relevant = BenchmarkTools.median(trial_relevant).time / 1e9
        display(trial_relevant)
        records_per_second = rate(relevant!(source, wets(path_wets); threshold=0.0), time_relevant)
        @info "Benchmarking relevant! (records)" records = count(relevant!(source, wets(path_wets); threshold=0.0)) records_per_second = records_per_second
        # @test records_per_second >= 25_000
    end
end

# wet is 2x faster than wet2 below. wet2 just read lines and does nothing, but wet is still much faster despite doing more
# function wet2(path="data/warc.wet.gz")
#     stream = GzipDecompressorStream(open(path))
#     for line in eachline(stream)
#         # do something...
#     end
#     close(stream)
# end

# @benchmark wet2()

# BenchmarkTools.Trial: 3 samples with 1 evaluation per sample.
#  Range (min … max):  1.708 s …   1.737 s  ┊ GC (min … max): 3.66% … 5.11%
#  Time  (median):     1.736 s              ┊ GC (median):    5.09%
#  Time  (mean ± σ):   1.727 s ± 16.457 ms  ┊ GC (mean ± σ):  4.63% ± 0.83%

#   ▁                                                       █  
#   █▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁█ ▁
#   1.71 s         Histogram: frequency by time        1.74 s <

#  Memory estimate: 1.08 GiB, allocs estimate: 17426086.
