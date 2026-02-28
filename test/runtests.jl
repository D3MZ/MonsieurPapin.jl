using MonsieurPapin
using Test
using HTTP: URI

@testset "MonsieurPapin.jl" begin
    wetpath = joinpath(@__DIR__, "data", "wet.paths.gz")
    uris = wetURIs(wetpath)
    @test @allocations(first(uris)) == 1 # 125.000 ns  Memory estimate: 192 bytes, allocs estimate: 1.

    path = joinpath(@__DIR__, "data", "warc.wet.gz")
    channel = wets(path)
    @test @allocations(first(channel)) == 1 #250.000 ns  Memory estimate: 224 bytes, allocs estimate: 1.
end