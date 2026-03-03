using BenchmarkTools
using Test

@testset "fasttext" begin
    vecpath = joinpath(dirname(@__DIR__), "test", "data", "fasttext.vec")

    @test isrelevant("cat dog", "kitten dog"; threshold=0.8, vecpath)
    @test !isrelevant("cat", "banana"; threshold=0.6, vecpath)
    @test isrelevant("CAT, dog!", "kitten dog"; threshold=0.8, vecpath)
    @test !isrelevant("unknown phrase", "banana"; threshold=0.1, vecpath)

    if get(ENV, "MONSIEURPAPIN_BENCHMARK", "false") == "true"
        display(@benchmark isrelevant("cat dog", "kitten dog"; threshold=0.8, vecpath=$vecpath))
    end
end
