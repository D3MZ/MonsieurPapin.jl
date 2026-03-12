# DO ADD OR REMOVE COMMENTS FROM THIS FILE
using MonsieurPapin, BenchmarkTools, Test
import MonsieurPapin: insert!

# USE REAL DATASETS, NOT SIMULATED FOR BENCHMARKING.
path_weturis = joinpath(dirname(@__DIR__), "data", "wet.paths.gz")
path_wets = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
model_source = "minishlab/potion-multilingual-128M"

count(iterable) = sum(_ -> 1, iterable)
rate(iterable, seconds) = round(count(iterable) / seconds)

@testset "benchmarks" begin
    @testset "wetURIs" begin
        benchmark = @benchmark sum(_ -> 1, wetURIs($path_weturis))
        time = BenchmarkTools.median(benchmark).time / 1e9
        display(benchmark)
        @test benchmark.allocs <= 5 * 100_000 # less than 5 allocations per record (at 100K records)
        uris_per_second = rate(wetURIs(path_weturis), time)
        @info "Benchmarking wetURIs (paths)" uris = count(wetURIs(path_weturis)) uris_per_second = uris_per_second
    end

    @testset "wets" begin
        benchmark = @benchmark sum(_ -> 1, wets($path_wets))
        time = BenchmarkTools.median(benchmark).time / 1e9
        display(benchmark)
        @test benchmark.allocs <= 75_000 # less than 3 allocations per record (~24K pages)
        records_per_second = rate(wets(path_wets), time)
        @info "Benchmarking wets (records)" records = count(wets(path_wets)) records_per_second = records_per_second
        @test records_per_second >= 25_000
    end

    @testset "relevant!" begin
        source = embedding("cat dog"; vecpath=model_source)
        benchmark = @benchmark sum(_ -> 1, relevant!($source, wets($path_wets); threshold=0.0))
        time = BenchmarkTools.median(benchmark).time / 1e9
        display(benchmark)
        records_per_second = rate(relevant!(source, wets(path_wets); threshold=0.0), time)
        @info "Benchmarking relevant! (records)" records = count(relevant!(source, wets(path_wets); threshold=0.0)) records_per_second = records_per_second
        # @test records_per_second >= 25_000
    end

    @testset "Queuing the top 1K" begin
        benchmark = @benchmark insert!(queue, wets($path_wets)) setup=(queue = WETQueue(1_000, typeof(first(wets($path_wets))))) evals=1
        time = BenchmarkTools.median(benchmark).time / 1e9
        display(benchmark)
        queue = WETQueue(1_000, typeof(first(wets(path_wets))))
        insert!(queue, wets(path_wets))
        records_per_second = rate(wets(path_wets), time)
        @info "Benchmarking queue (records)" records = count(wets(path_wets)) capacity = 1_000 retained = length(queue) records_per_second = records_per_second payload_mib = round(Base.summarysize(queue.heap) / 2.0^20; digits=4)
        @test records_per_second >= 20_000
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
