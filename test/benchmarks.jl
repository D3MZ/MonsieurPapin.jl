# DO ADD OR REMOVE COMMENTS FROM THIS FILE
using MonsieurPapin, BenchmarkTools, Statistics, Test
import MonsieurPapin: insert!, score

# USE REAL DATASETS, NOT SIMULATED FOR BENCHMARKING.
urispath = joinpath(dirname(@__DIR__), "data", "wet.paths.gz")
wetspath = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
model_source = "minishlab/potion-multilingual-128M"

count(iterable) = sum(_ -> 1, iterable)
rate(iterable, seconds) = round(count(iterable) / seconds)

@testset "benchmarks" begin
    @testset "wetURIs" begin
        benchmark = @benchmark sum(_ -> 1, wetURIs($urispath))
        time = median(benchmark).time / 1e9
        display(benchmark)
        @test benchmark.allocs <= 5 * 100_000 # less than 5 allocations per record (at 100K records)
        uris_per_second = rate(wetURIs(urispath), time)
        @info "Benchmarking wetURIs (paths)" uris = count(wetURIs(urispath)) uris_per_second = uris_per_second
    end

    @testset "wets" begin
        benchmark = @benchmark sum(_ -> 1, wets($wetspath))
        time = median(benchmark).time / 1e9
        display(benchmark)
        @test benchmark.allocs <= 75_000 # less than 3 allocations per record (~24K pages)
        records_per_second = rate(wets(wetspath), time)
        @info "Benchmarking wets (records)" records = count(wets(wetspath)) records_per_second = records_per_second
        @test records_per_second >= 25_000
    end

    @testset "Multilingual Distance between Query and WET" begin
        benchmark = @benchmark score(source, take!(channel)) setup=(
            source = embedding("cat dog"; vecpath=model_source);
            channel = wets(wetspath)
        ) samples=1 evals=count(wets(wetspath))
        time = median(benchmark).time / 1e9
        display(benchmark)
        @info "Benchmarking relevant! (records)" records_per_second = round(1 / time)
        @test records_per_second >= 400
    end

    @testset "Queuing the top 1K" begin
        benchmark = @benchmark insert!(queue, wets($wetspath)) setup=(queue = WETQueue(1_000, typeof(first(wets($wetspath))))) evals=1
        time = median(benchmark).time / 1e9
        display(benchmark)
        queue = WETQueue(1_000, typeof(first(wets(wetspath))))
        insert!(queue, wets(wetspath))
        records_per_second = rate(wets(wetspath), time)
        @info "Benchmarking queue (records)" records = count(wets(wetspath)) capacity = 1_000 retained = length(queue) records_per_second = records_per_second payload_mib = round(Base.summarysize(queue.heap) / 2.0^20; digits=4)
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
