using Aqua
using CodeComplexity
using MonsieurPapin
using Test
using HTTP: URI
using TOML

one(_) = 1

# Zero-allocation assertions run first, before other tests load packages
# (HTTP and other packages) that add noise to Julia's task allocation tracking.
let path = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
    @testset "zero-alloc" begin
        warmed = wets(path)
        first(warmed)
        foreach(_ -> nothing, warmed)
        channel = wets(path)
        @test @allocations(first(channel)) == 0
        foreach(_ -> nothing, channel)
        warmedfiltered = wets(path; languages=["eng"])
        first(warmedfiltered)
        foreach(_ -> nothing, warmedfiltered)
        filtered = wets(path; languages=["eng"])
        @test @allocations(first(filtered)) == 0
        foreach(_ -> nothing, filtered)
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
    uris = wetpaths(wetpath)

    Aqua.test_all(MonsieurPapin; stale_deps=false, deps_compat=false)
    qualitysettings = TOML.parsefile(joinpath(dirname(@__DIR__), "settings.toml"))
    @test isempty(check_complexity(joinpath(dirname(@__DIR__), "src"); max_complexity=qualitysettings["quality"]["max_complexity"], throw_on_violation=false))

    sourcefiles = filter(path -> endswith(path, ".jl"), readdir(joinpath(dirname(@__DIR__), "src"); join=true))
    source = join(read.(sourcefiles, String), "\n")
    @test !occursin(r"\bcatch\b", source)
    @test !occursin(r"\bhaskey\s*\(", source)
    @test !occursin(r"\bget\s*\([^;,\n]+,[^;,\n]+,", source)
end
