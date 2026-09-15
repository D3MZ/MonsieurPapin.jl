using CodecZlib
using HTTP
using HTTP: URI
using MonsieurPapin
using Sockets
using Test
using TOML

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
    settings = TOML.parsefile(joinpath(dirname(@__DIR__), "settings.toml"))
    @test settings["crawl"]["path"] == "https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
    @test settings["pipeline"]["threshold"] == 0.6
    @test settings["embedding"]["model"] == "minishlab/potion-multilingual-128M"
    @test settings["llm"]["path"] == "/v1/chat/completions"
    @test settings["llm"]["provider"] == "openai-codex"
    @test settings["llm"]["model"] == "gpt-5.5"
    @test settings["llm"]["command"] == ["pi", "--mode", "rpc", "--no-session", "--no-tools", "--thinking", "off"]
    @test settings["llm"]["usage"]["method"] == "account/rateLimits/read"
    @test settings["llm"]["usage"]["command"] == ["codex", "app-server", "--stdio"]
    @test settings["llm"]["usage"]["limit_name"] == "GPT-5.3-Codex-Spark"
    # Embedding scores are cosine distances; similarity is 1 - distance.
    @test MonsieurPapin.isrelevant(0.39; threshold=settings["pipeline"]["threshold"])
    @test !MonsieurPapin.isrelevant(0.41; threshold=settings["pipeline"]["threshold"])
    @test settings["output"]["path"] == "research.md"
    langs = settings["crawl"]["languages"]
    @test langs isa AbstractVector && length(langs) == length(unique(langs)) && length(langs) > 100
    @test length(langs) >= 25
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

    lower = MonsieurPapin.rescore(records[1], 0.1)
    higher = MonsieurPapin.rescore(records[1], 0.9)
    scoredduplicates = Channel{eltype(records)}(2) do source
        put!(source, lower)
        put!(source, higher)
    end
    survivors = collect(unique(SeenSet(10), scoredduplicates))
    @test length(survivors) == 1
    @test MonsieurPapin.score(first(survivors)) == 0.9

    release = Channel{Nothing}(1)
    delayed = Channel{eltype(records)}(1; spawn=true) do source
        put!(source, records[1])
        take!(release)
        put!(source, records[2])
    end
    streamed = unique(SeenSet(10), delayed; batchsize=1)
    ready = Base.timedwait(() -> isready(streamed), 1)
    put!(release, nothing)
    @test ready == :ok
    @test take!(streamed) == records[1]
    foreach(_ -> nothing, streamed)

    attempts = Ref(0)
    server = HTTP.serve!("127.0.0.1", 0; verbose=false) do req
        if req.target == "/paths"
            HTTP.Response(200, compressed("https://example.com/stream\n"))
        elseif req.target == "/retry-paths"
            attempts[] += 1
            attempts[] == 1 ? HTTP.Response(503) : HTTP.Response(200, compressed("https://example.com/recovered\n"))
        elseif req.target == "/wet"
            HTTP.Response(200, compressed(corerecord("hello")))
        else
            HTTP.Response(404)
        end
    end

    try
        port = hasproperty(server.listener, :server) ? last(getsockname(server.listener.server)) : HTTP.port(server)
        base = "http://127.0.0.1:$(Int(port))"
        @test collect(wetpaths("$base/paths")) == ["https://example.com/stream"]
        retryconfig = Dict("retries" => 1, "factor" => 1.0)
        @test collect(wetpaths("$base/retry-paths", retryconfig)) == ["https://example.com/recovered"]
        @test attempts[] == 2

        remote = collect(wets(URI("$base/wet"); languages=["eng"]))
        configured = collect(wets(URI("$base/wet"), retryconfig; languages=["eng"]))
        @test length(configured) == 1
        @test MonsieurPapin.content(first(configured)) == "hello"
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
