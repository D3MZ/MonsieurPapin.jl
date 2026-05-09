using CodecZlib
using Test

entryrecord(content; language="eng", uri="https://example.com") =
    "WARC/1.0\r\n" *
    "WARC-Type: conversion\r\n" *
    "WARC-Target-URI: $uri\r\n" *
    "WARC-Date: 2026-03-03T00:00:00Z\r\n" *
    "WARC-Identified-Content-Language: $language\r\n" *
    "Content-Length: $(ncodeunits(content))\r\n\r\n" *
    content

@testset "core" begin
    settings = loadsettings()
    @test settings["crawl"]["path"] == "https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
    @test settings["pipeline"]["threshold"] == 0.6
    @test settings["embedding"]["model"] == "minishlab/potion-multilingual-128M"
    @test settings["llm"]["path"] == "/api/v1/chat"
    @test settings["output"]["path"] == "research.md"
    @test settings["crawl"]["languages"] == ["eng", "deu", "rus", "jpn", "zho", "spa", "fra", "por", "ita", "pol"]

    path = tempname() * ".gz"
    open(path, "w") do file
        stream = GzipCompressorStream(file)
        write(stream, entryrecord(repeat("skip me", 500); language="rus"))
        write(stream, entryrecord("keep me"; language="eng"))
        write(stream, entryrecord("keep me too"; language="zho,eng"))
        close(stream)
    end

    filtered = collect(wets(path; capacity=2, languages=["eng"]))
    @test map(MonsieurPapin.language, filtered) == ["eng", "zho,eng"]
    channel = wets(path; capacity=2, languages=["eng"])
    @test @allocations(first(channel)) == 0
end
