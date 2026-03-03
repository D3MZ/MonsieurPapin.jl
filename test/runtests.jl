using Aqua
using CodeComplexity
using MonsieurPapin
using Test
using HTTP: URI

@testset "MonsieurPapin.jl" begin
    Aqua.test_all(MonsieurPapin; stale_deps=false, deps_compat=false)
    @test isempty(check_complexity(joinpath(dirname(@__DIR__), "src"); max_complexity=5, throw_on_violation=false))

    wetpath = joinpath(@__DIR__, "data", "wet.paths.gz")
    uris = wetURIs(wetpath)
    @test @allocations(first(uris)) == 1 # 125.000 ns  Memory estimate: 192 bytes, allocs estimate: 1.

    path = joinpath(@__DIR__, "data", "warc.wet.gz")
    channel = wets(path)
    @test @allocations(first(channel)) == 1 #250.000 ns  Memory estimate: 224 bytes, allocs estimate: 1.
end


# using CodecZlib
# path = joinpath(@__DIR__, "test/data", "warc.wet.gz")
# open(path) do file
#     stream = GzipDecompressorStream(file)
#     @allocations readline(stream)
# end

# using CodecZlib

# open(path) do file
#     stream = GzipDecompressorStream(file)
#     total = 0
#     while !eof(stream)
#         total += @allocations readline(stream)
#     end
#     total
# end

# @allocations begin
#     for _ in wets(path)
#     end
# end

using BenchmarkTools

display(@benchmark sum(_ -> 1, channel) setup = (path = joinpath(@__DIR__, "data", "warc.wet.gz"); channel = wets(path)) evals = 1)
