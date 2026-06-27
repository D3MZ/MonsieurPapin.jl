using BenchmarkTools
using CodecZlib
using Dates
using MonsieurPapin
using Test

record(content; language="eng", uri="https://example.com") =
    "WARC/1.0\r\n" *
    "WARC-Type: conversion\r\n" *
    "WARC-Target-URI: $(uri)\r\n" *
    "WARC-Date: 2026-03-03T00:00:00Z\r\n" *
    "WARC-Identified-Content-Language: $(language)\r\n" *
    "Content-Length: $(ncodeunits(content))\r\n\r\n" *
    content

function pages()
    path = tempname() * ".gz"
    open(path, "w") do file
        stream = GzipCompressorStream(file)
        write(stream, record("kitten dog"; language="eng") * record("banana"; language="zho,eng"))
        close(stream)
    end
    MonsieurPapin.wets(path; capacity=2)
end

@testset "scoring" begin
    @test :values ∉ fieldnames(MonsieurPapin.Embedding)
    @test !isdefined(MonsieurPapin, :fasttext)
    @test !isdefined(MonsieurPapin, :tokenize)
    sample = collect(pages())
    matcher = AC(Dict("kitten" => 1.0, "dog" => 2.0, "banana" => 4.0))
    @test MonsieurPapin.language(first(sample)) == "eng"
    @test MonsieurPapin.language(last(sample)) == "zho,eng"
    @test MonsieurPapin.languages(last(sample)) == ["zho", "eng"]
    @test MonsieurPapin.score(matcher, "kitten dog dog") == 5.0
    @test MonsieurPapin.score(matcher, first(sample)) == 3.0
    @test MonsieurPapin.score(matcher, last(sample)) == 4.0

    # The content pointer Rust slices must land on the real content bytes (struct-layout guard).
    text = "héllo wörld"
    page = WET(MonsieurPapin.Snippet("u", Val(8)), MonsieurPapin.Snippet(text, Val(64)),
        MonsieurPapin.Snippet("eng", Val(8)), DateTime(2026, 1, 1), ncodeunits(text), 0.0)
    reference = Ref(page)
    GC.@preserve reference begin
        pointer = Ptr{UInt8}(Base.unsafe_convert(Ptr{typeof(page)}, reference) + MonsieurPapin.contentoffset(typeof(page)))
        @test unsafe_string(pointer, MonsieurPapin.utf8boundary(pointer, page.content.length)) == MonsieurPapin.content(page)
    end

    if get(ENV, "MONSIEURPAPIN_MODEL2VEC", "false") == "true"
        source = embedding("cat dog")
        banana = embedding("banana")
        records = collect(select(source, pages(); capacity=10))
        scores = map(wet -> wet.score, records)

        @test distance(source, "kitten dog") < distance(source, "banana")
        @test distance(source, first(sample)) < distance(source, last(sample))
        @test isrelevant(source, "kitten dog"; threshold=0.0)
        @test !isrelevant(source, banana; threshold=0.9)
        @test length(records) == 2
        @test minimum(scores) < maximum(scores)

        if get(ENV, "MONSIEURPAPIN_BENCHMARK", "false") == "true"
            display(@benchmark isrelevant($source, "kitten dog"; threshold=0.0))
        end
    end
end
