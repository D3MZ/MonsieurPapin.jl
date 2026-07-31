using CodecZlib
using HTTP
using HTTP: URI
using MonsieurPapin
using Sockets
using Test

function compressed(text::AbstractString)
    transcode(GzipCompressor, codeunits(text))
end

corerecord(content; language="eng", uri="https://example.com") =
    "WARC/1.0\r\n" *
    "WARC-Type: conversion\r\n" *
    "WARC-Target-URI: $(uri)\r\n" *
    "WARC-Date: 2026-03-03T00:00:00Z\r\n" *
    "WARC-Identified-Content-Language: $(language)\r\n" *
    "Content-Length: $(ncodeunits(content))\r\n\r\n" *
    content

@testset "core" begin
    settings = loadsettings(joinpath(dirname(@__DIR__), "settings.toml"))
    @test settings["crawl"]["path"] == "https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
    @test settings["pipeline"]["threshold"] == 0.6
    @test settings["embedding"]["model"] == "minishlab/potion-multilingual-128M"
    @test settings["llm"]["path"] == "/v1/chat/completions"
    @test settings["output"]["path"] == "research.md"
    langs = settings["crawl"]["languages"]
    @test langs isa AbstractVector && length(langs) == length(unique(langs)) && length(langs) > 100
    @test issubset(["eng", "deu", "rus", "jpn", "zho", "spa", "fra", "por", "ita", "pol"], langs)

    path = tempname() * ".gz"
    open(path, "w") do file
        stream = GzipCompressorStream(file)
        write(stream, corerecord(repeat("skip me", 500); language="rus"))
        write(stream, corerecord("keep me"; language="eng"))
        write(stream, corerecord("keep me too"; language="zho,eng"))
        close(stream)
    end

    filtered = collect(wets(path; capacity=2, languages=["eng"]))
    @test map(MonsieurPapin.language, filtered) == ["eng", "zho,eng"]
    channel = wets(path; capacity=2, languages=["eng"])
    @test @allocations(first(channel)) == 0
    foreach(_ -> nothing, channel)

    cleaned = MonsieurPapin.cleankeywords([" trend / breakout ", "趋势，突破", "x", repeat("a", 61), "trend"])
    @test cleaned == ["trend", "breakout", "趋势", "突破"]

    firsthash = simhash("A momentum trading strategy")
    @test firsthash == simhash("A momentum trading strategy")
    seen = SeenSet(2)
    @test !MonsieurPapin.seen!(seen, firsthash)
    @test MonsieurPapin.seen!(seen, firsthash)
    @test !MonsieurPapin.seen!(seen, simhash("gardening"))
    @test !MonsieurPapin.seen!(seen, simhash("astronomy"))
    @test !MonsieurPapin.seen!(seen, firsthash)

    records = collect(wets(path; capacity=2, languages=["eng"]))
    recordsource = Channel{eltype(records)}(length(records)) do source
        foreach(record -> put!(source, record), records)
    end
    selected = collect(select(AC(["keep"]), recordsource; capacity=2))
    @test length(selected) == 2
    @test all(record -> MonsieurPapin.score(record) == 1, selected)

    duplicates = Channel{eltype(records)}(2) do source
        put!(source, records[1])
        put!(source, records[1])
    end
    @test length(collect(unique(SeenSet(10), duplicates))) == 1

    server = HTTP.serve!("127.0.0.1", 0; verbose=false) do req
        if req.target == "/paths"
            HTTP.Response(200, compressed("https://example.com/stream\n"))
        elseif req.target == "/wet"
            HTTP.Response(200, compressed(corerecord("hello")))
        else
            HTTP.Response(404)
        end
    end

    try
        host, port = getsockname(server.listener.server)
        base = "http://$(host):$(Int(port))"
        @test collect(wetpaths("$base/paths")) == ["https://example.com/stream"]

        remote = collect(wets(URI("$base/wet"); languages=["eng"]))
        @test length(remote) == 1
        @test MonsieurPapin.uri(first(remote)) == "https://example.com"
        @test MonsieurPapin.language(first(remote)) == "eng"

        remote = collect(wets("$base/wet"; languages=["eng"]))
        @test length(remote) == 1
        @test MonsieurPapin.uri(first(remote)) == "https://example.com"
        @test MonsieurPapin.language(first(remote)) == "eng"
    finally
        close(server)
    end
end
