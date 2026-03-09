using MonsieurPapin, BenchmarkTools, Test

path_weturis = joinpath(dirname(@__DIR__), "data", "wet.paths.gz")
path_wets = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")

count(iterable) = sum(_ -> 1, iterable)
rate(iterable, seconds) = round(count(iterable) / seconds)

@testset "benchmarks" begin
    @testset "wetURIs" begin
        trial_weturis = @benchmark sum(_ -> 1, wetURIs($path_weturis))
        time_weturis = BenchmarkTools.median(trial_weturis).time / 1e9
        display(trial_weturis)
        @test trial_weturis.allocs <= 901425
        uris_per_second = rate(wetURIs(path_weturis), time_weturis)
        @info "Benchmarking wetURIs (paths)" uris = count(wetURIs(path_weturis)) uris_per_second = uris_per_second
    end

    @testset "wets" begin
        trial_wets = @benchmark sum(_ -> 1, wets($path_wets))
        time_wets = BenchmarkTools.median(trial_wets).time / 1e9
        display(trial_wets)
        @test trial_wets.allocs <= 52745
        records_per_second = rate(wets(path_wets), time_wets)
        @info "Benchmarking wets (records)" records = count(wets(path_wets)) records_per_second = records_per_second
        @test records_per_second >= 25_000
    end
end