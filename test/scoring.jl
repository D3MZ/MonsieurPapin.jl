using BenchmarkTools
using CodecZlib
using Dates
using Model2Vec
using MonsieurPapin
using Test

include(joinpath(dirname(pathof(Model2Vec)), "..", "test", "fixtures.jl"))

boundary(bytes::AbstractVector{UInt8}) = GC.@preserve bytes MonsieurPapin.utf8boundary(pointer(bytes), length(bytes))

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

    @test boundary(UInt8[0x61, 0xE2, 0x82]) == 1
    @test boundary(UInt8[0xE2, 0x82]) == 0
    @test boundary(UInt8[0xC3, 0xA9]) == 2

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
        mktempdir() do dir
            vecpath = buildwordpiecefixture(joinpath(dir, "model"))
            source = embedding("cat dog"; vecpath)
            banana = embedding("banana"; vecpath)
            records = collect(select(source, pages(); capacity=10))
            scores = map(wet -> wet.score, records)

            @test distance(source, "kitten dog") < distance(source, "banana")
            @test distance(source, first(sample)) < distance(source, last(sample))
            @test isrelevant(source, "kitten dog"; threshold=0.0)
            @test !isrelevant(source, banana; threshold=0.9)
            @test length(records) == 2
            @test minimum(scores) < maximum(scores)

            MonsieurPapin.handle!(source)
            bad = WET(
                MonsieurPapin.Snippet("https://example.com", Val(4096)),
                MonsieurPapin.Snippet(UInt8[0x61, 0xC3, 0x61], 1, 3, Val(12000)),
                MonsieurPapin.Snippet("eng", Val(64)),
                DateTime(2026, 1, 1),
                3,
                0.0,
            )
            @test isfinite(distance(source, bad))
            scratch = source.scratch
            scores = Float64[]; pointers = UInt[]; lengths = UInt[]
            MonsieurPapin.score!(scores, pointers, lengths, source, [bad], scratch)
            @test isfinite(first(scores))

            if get(ENV, "MONSIEURPAPIN_BENCHMARK", "false") == "true"
                display(@benchmark isrelevant($source, "kitten dog"; threshold=0.0))
            end
        end
    end
end
