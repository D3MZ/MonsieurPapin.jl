using BenchmarkTools
using Test

record(content; language="en", uri="https://example.com") =
    "WARC/1.0\r\n" *
    "WARC-Type: conversion\r\n" *
    "WARC-Target-URI: $uri\r\n" *
    "WARC-Date: 2026-03-03T00:00:00Z\r\n" *
    "WARC-Identified-Content-Language: $language\r\n" *
    "Content-Length: $(ncodeunits(content))\r\n\r\n" *
    content

pages() = MonsieurPapin.wets(Vector{UInt8}(codeunits(record("kitten dog") * record("banana"))); capacity=2)

@testset "fasttext" begin
    vecpath = joinpath(dirname(@__DIR__), "test", "data", "fasttext.vec")
    model = MonsieurPapin.fasttext(vecpath)
    catdog = MonsieurPapin.embedding("cat dog", model)
    banana = MonsieurPapin.embedding("banana", model)
    sample = pages()
    records = collect(sample)
    catpage = first(records)
    fruitpage = last(records)

    @test embedding("cat dog"; vecpath).values ≈ catdog.values
    @test isrelevant("cat dog", "kitten dog"; threshold=0.8, vecpath)
    @test !isrelevant("cat", "banana"; threshold=0.6, vecpath)
    @test isrelevant("CAT, dog!", "kitten dog"; threshold=0.8, vecpath)
    @test !isrelevant("unknown phrase", "banana"; threshold=0.1, vecpath)
    @test isrelevant(catdog, sample, catpage; threshold=0.8)
    @test !isrelevant(catdog, sample, fruitpage; threshold=0.6)
    @test isrelevant(catdog, "kitten dog"; threshold=0.8)
    @test isrelevant(catdog, MonsieurPapin.embedding("kitten dog", model); threshold=0.8)
    @test !isrelevant(catdog, banana; threshold=0.6)
    filtered = relevant!(catdog, pages(); threshold=0.8)
    results = collect(filtered)
    @test String(MonsieurPapin.content(filtered, first(results))) == "kitten dog"
    scored = collect(relevant!(catdog, pages(); threshold=0.0))
    @test minimum(wet -> wet.score, scored) < maximum(wet -> wet.score, scored)

    if get(ENV, "MONSIEURPAPIN_BENCHMARK", "false") == "true"
        display(@benchmark isrelevant("cat dog", "kitten dog"; threshold=0.8, vecpath=$vecpath))
    end
end
