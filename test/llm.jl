using BenchmarkTools
using Test

struct StubLLM
    output::String
end

MonsieurPapin.complete(::AbstractString, llm::StubLLM) = llm.output

warcrecord(content; language="en", uri="https://example.com") =
    "WARC/1.0\r\n" *
    "WARC-Type: conversion\r\n" *
    "WARC-Target-URI: $uri\r\n" *
    "WARC-Date: 2026-03-03T00:00:00Z\r\n" *
    "WARC-Identified-Content-Language: $language\r\n" *
    "Content-Length: $(ncodeunits(content))\r\n\r\n" *
    content

sample() = MonsieurPapin.wets(Vector{UInt8}(codeunits(warcrecord("kitten dog") * warcrecord("banana"))); capacity=2)

@testset "llm" begin
    stub = StubLLM("```text\nstrategy\n```\n")
    @test complete("anything", stub) == stub.output

    outputpath = tempname()
    config = Configuration(; outputpath, capacity=2)
    filtered = relevant!(embedding("cat dog"; vecpath="test/data/fasttext.vec"), sample(); threshold=0.0)
    @test MonsieurPapin.report(config, filtered, stub) == outputpath
    @test occursin("strategy", read(outputpath, String))

    if get(ENV, "MONSIEURPAPIN_BENCHMARK", "false") == "true"
        path = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
        documents = wets(path)
        source = embedding("trading strategy"; vecpath="test/data/fasttext.vec")
        filtered = relevant!(source, documents; threshold=0.0)
        config = Configuration(; outputpath=tempname(), capacity=10)
        display(@benchmark MonsieurPapin.report($config, $filtered, $stub) samples=1 evals=1 seconds=60)
    end
end
