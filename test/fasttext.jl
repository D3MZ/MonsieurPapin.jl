using BenchmarkTools
using Test

@testset "fasttext" begin
    vecpath = joinpath(dirname(@__DIR__), "test", "data", "fasttext.vec")
    model = MonsieurPapin.fasttext(vecpath)
    catdog = MonsieurPapin.embedding("cat dog", model)
    banana = MonsieurPapin.embedding("banana", model)
    catpage = WET("https://example.com", "2026-03-03T00:00:00Z", "en", "7", "kitten dog")
    fruitpage = WET("https://example.com", "2026-03-03T00:00:00Z", "en", "6", "banana")

    @test embedding("cat dog"; vecpath).values ≈ catdog.values
    @test isrelevant("cat dog", "kitten dog"; threshold=0.8, vecpath)
    @test !isrelevant("cat", "banana"; threshold=0.6, vecpath)
    @test isrelevant("CAT, dog!", "kitten dog"; threshold=0.8, vecpath)
    @test !isrelevant("unknown phrase", "banana"; threshold=0.1, vecpath)
    @test isrelevant(catdog, catpage; threshold=0.8)
    @test !isrelevant(catdog, fruitpage; threshold=0.6)
    @test isrelevant(catdog, "kitten dog"; threshold=0.8)
    @test isrelevant(catdog, MonsieurPapin.embedding("kitten dog", model); threshold=0.8)
    @test !isrelevant(catdog, banana; threshold=0.6)
    filtered = collect(relevant!(catdog, Channel{WET}(2) do wets
        put!(wets, catpage)
        put!(wets, fruitpage)
    end; threshold=0.8))
    @test first(filtered).content == "kitten dog"
    @test first(filtered) === catpage
    @test catpage.score < fruitpage.score
    @test catpage.score <= 1.0 - 0.8

    if get(ENV, "MONSIEURPAPIN_BENCHMARK", "false") == "true"
        display(@benchmark isrelevant("cat dog", "kitten dog"; threshold=0.8, vecpath=$vecpath))
    end
end
