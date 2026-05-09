using Aqua
using CodeComplexity
using MonsieurPapin
using Test
using HTTP: URI

one(_) = 1

# Zero-allocation assertions run first, before other tests load packages
# (HTTP, JlrsCore, etc.) that add noise to Julia's task allocation tracking.
let path = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
    @testset "zero-alloc" begin
        first(wets(path))
        channel = wets(path)
        @test @allocations(first(channel)) == 0
        first(wets(path; languages=["eng"]))
        filtered = wets(path; languages=["eng"])
        @test @allocations(first(filtered)) == 0
        @test sum(one, wets(path)) == 21_465
        @test sum(one, wets(path)) + sum(one, wets(path)) == 2 * 21_465
    end
end

include("scoring.jl")
include("http.jl")
include("core.jl")
include("queue.jl")
include("llm.jl")

@testset "MonsieurPapin.jl" begin
    wetpath = joinpath(dirname(@__DIR__), "data", "wet.paths.gz")
    uris = wetURIs(wetpath)

    Aqua.test_all(MonsieurPapin; stale_deps=false, deps_compat=false)
    @test isempty(check_complexity(joinpath(dirname(@__DIR__), "src"); max_complexity=13, throw_on_violation=false))

    if get(ENV, "MONSIEURPAPIN_BENCHMARK", "false") == "true"
        using BenchmarkTools
        path = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
        display(@benchmark sum(_ -> 1, wets($path)))
    end
end


# using CodecZlib
# path = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
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
