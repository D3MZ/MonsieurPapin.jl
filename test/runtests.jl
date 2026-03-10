using Aqua
using CodeComplexity
using MonsieurPapin
using Test
using HTTP: URI

include("fasttext.jl")
include("gettext.jl")
include("core.jl")
include("queue.jl")
include("llm.jl")

one(_) = 1

@testset "MonsieurPapin.jl" begin
    Aqua.test_all(MonsieurPapin; stale_deps=false, deps_compat=false)
    @test isempty(check_complexity(joinpath(dirname(@__DIR__), "src"); max_complexity=5, throw_on_violation=false))

    wetpath = joinpath(dirname(@__DIR__), "data", "wet.paths.gz")
    uris = wetURIs(wetpath)

    path = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
    channel = wets(path)
    @test @allocations(first(channel)) == 0
    @test sum(one, wets(path)) == 21_465
    @test sum(one, wets([path, path])) == 2 * sum(one, wets(path))

    if get(ENV, "MONSIEURPAPIN_BENCHMARK", "false") == "true"
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
