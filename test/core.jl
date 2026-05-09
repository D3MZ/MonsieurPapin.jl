using CodecZlib
using Test
using HTTP: URI

entryrecord(content; language="eng", uri="https://example.com") =
    "WARC/1.0\r\n" *
    "WARC-Type: conversion\r\n" *
    "WARC-Target-URI: $uri\r\n" *
    "WARC-Date: 2026-03-03T00:00:00Z\r\n" *
    "WARC-Identified-Content-Language: $language\r\n" *
    "Content-Length: $(ncodeunits(content))\r\n\r\n" *
    content

@testset "core" begin
    config = Settings()
    @test config.crawl.crawlpath == "https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
    @test config.search.threshold == 0.6
    @test config.search.vecpath == "minishlab/potion-multilingual-128M"
    @test config.llm.path == "/api/v1/chat"
    @test config.outputpath == "research.md"
    @test config.crawl.languages == ["eng", "deu", "rus", "jpn", "zho", "spa", "fra", "por", "ita", "pol"]

    custom = Settings(; crawl = Crawl(; capacity = 3), outputpath = "notes.md")
    @test custom.crawl.capacity == 3
    @test custom.outputpath == "notes.md"

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
