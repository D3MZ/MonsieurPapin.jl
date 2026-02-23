using CodecZlib
using Dates
using MonsieurPapin
using Test

struct MockTransport <: MonsieurPapin.AbstractTransport
    payloads::Dict{String, Vector{UInt8}}
end

function MonsieurPapin.open_url_stream(transport::MockTransport, url::String)::IO
    haskey(transport.payloads, url) || error("No fixture payload configured for $(url)")
    return IOBuffer(copy(transport.payloads[url]))
end

function gzip_text(text::String)::Vector{UInt8}
    return transcode(GzipCompressor, codeunits(text))
end

function fixture_text(name::String)::String
    path = joinpath(@__DIR__, "fixtures", name)
    return read(path, String)
end

function wet_paths_url_for(crawlpath::String)::String
    return "https://data.commoncrawl.org/crawl-data/$(crawlpath)/wet.paths.gz"
end

function warc_record_text(uri::String, date::String, language::String, content::String)::String
    return (
        "WARC/1.0\n" *
        "WARC-Type: conversion\n" *
        "WARC-Date: $(date)\n" *
        "WARC-Target-URI: $(uri)\n" *
        "WARC-Identified-Content-Language: $(language)\n" *
        "Content-Length: $(ncodeunits(content))\n\n" *
        "$(content)\n\n"
    )
end

@testset "Download stage" begin
    @testset "fetch_wet_urls parses and normalizes index" begin
        crawlpath = "CC-MAIN-TEST-01"
        index_url = wet_paths_url_for(crawlpath)
        index_payload = gzip_text(fixture_text("wet_paths_sample.txt"))
        transport = MockTransport(Dict(index_url => index_payload))

        urls = fetch_wet_urls(crawlpath; transport = transport)

        expected = [
            "https://data.commoncrawl.org/crawl-data/CC-MAIN-TEST-01/segments/0000/wet/CC-MAIN-0000-0000.warc.wet.gz",
            "https://data.commoncrawl.org/crawl-data/CC-MAIN-TEST-01/segments/0000/wet/CC-MAIN-0000-0001.warc.wet.gz",
            "https://data.commoncrawl.org/crawl-data/CC-MAIN-TEST-01/segments/0000/wet/CC-MAIN-0000-0002.warc.wet.gz",
        ]

        @test urls == expected
    end

    @testset "wetstreams capacity uses RAM fraction" begin
        crawlpath = "CC-MAIN-TEST-CAPACITY"
        index_url = wet_paths_url_for(crawlpath)
        transport = MockTransport(Dict(index_url => gzip_text("")))

        settings = DownloadSettings(crawlpath = crawlpath, ram = 0.5f0)
        stage = start_download_stage(
            settings;
            embedding_batchsize = 4,
            progress_callback = progress -> nothing,
            transport = transport,
            total_memory_bytes = 256 * 1024 * 1024,
        )

        wait(stage)

        @test stage.wetstreams.sz_max == 2
        @test stage.warcs.sz_max == 8
        @test stage.stats.total_urls == 0
        @test stage.stats.completed_urls == 0
        @test stage.stats.failed_urls == 0
    end

    @testset "content-length parsing emits exact WARC payloads" begin
        crawlpath = "CC-MAIN-TEST-PARSE"
        index_url = wet_paths_url_for(crawlpath)
        wet_url = "https://data.commoncrawl.org/crawl-data/CC-MAIN-TEST-PARSE/segments/0000/wet/CC-MAIN-0000-0000.warc.wet.gz"

        index_payload = gzip_text("crawl-data/CC-MAIN-TEST-PARSE/segments/0000/wet/CC-MAIN-0000-0000.warc.wet.gz\n")
        warc_payload = gzip_text(fixture_text("warc_two_records.txt"))

        transport = MockTransport(Dict(index_url => index_payload, wet_url => warc_payload))

        stage = start_download_stage(
            DownloadSettings(crawlpath = crawlpath);
            embedding_batchsize = 2,
            progress_callback = progress -> nothing,
            transport = transport,
            total_memory_bytes = 64 * 1024 * 1024,
        )

        wait(stage)
        records = collect(stage.warcs)

        @test length(records) == 2

        @test records[1].uri == "https://example.com/a"
        @test records[1].length == 11
        @test records[1].content == "hello\nworld"
        @test records[1].date == DateTime(2025, 1, 15, 1, 2, 3)

        @test records[2].uri == "https://example.com/b"
        @test records[2].length == 13
        @test records[2].content == "second record"
        @test records[2].date == DateTime(2025, 1, 15, 1, 2, 3, 123)
    end

    @testset "offline pipeline emits progress and warcs" begin
        crawlpath = "CC-MAIN-TEST-E2E"
        index_url = wet_paths_url_for(crawlpath)
        wet_url_a = "https://data.commoncrawl.org/crawl-data/CC-MAIN-TEST-E2E/segments/0000/wet/CC-MAIN-0000-0000.warc.wet.gz"
        wet_url_b = "https://data.commoncrawl.org/crawl-data/CC-MAIN-TEST-E2E/segments/0000/wet/CC-MAIN-0000-0001.warc.wet.gz"

        index_payload = gzip_text(
            "crawl-data/CC-MAIN-TEST-E2E/segments/0000/wet/CC-MAIN-0000-0000.warc.wet.gz\n" *
            "crawl-data/CC-MAIN-TEST-E2E/segments/0000/wet/CC-MAIN-0000-0001.warc.wet.gz\n",
        )

        wet_payload_a = gzip_text(
            warc_record_text(
                "https://example.com/alpha",
                "2025-01-15T01:02:03Z",
                "en",
                "alpha content",
            ),
        )

        wet_payload_b = gzip_text(
            warc_record_text(
                "https://example.com/beta",
                "2025-01-15T01:02:03Z",
                "en",
                "beta content",
            ),
        )

        transport = MockTransport(
            Dict(
                index_url => index_payload,
                wet_url_a => wet_payload_a,
                wet_url_b => wet_payload_b,
            ),
        )

        progress_events = DownloadProgress[]
        progress_lock = ReentrantLock()
        progress_callback = function (progress::DownloadProgress)
            lock(progress_lock) do
                push!(progress_events, progress)
            end
            return nothing
        end

        stage = start_download_stage(
            DownloadSettings(crawlpath = crawlpath);
            embedding_batchsize = 2,
            progress_callback = progress_callback,
            transport = transport,
            total_memory_bytes = 64 * 1024 * 1024,
        )

        wait(stage)
        records = collect(stage.warcs)
        uris = sort(getfield.(records, :uri))

        @test uris == ["https://example.com/alpha", "https://example.com/beta"]

        @test length(progress_events) == 2
        completed = getfield.(progress_events, :completed_urls)
        @test completed == [1, 2]
        @test progress_events[end].total_urls == 2
        @test progress_events[end].failed_urls == 0
    end

    @testset "pipeline continues on download and parse errors" begin
        crawlpath = "CC-MAIN-TEST-ERRORS"
        index_url = wet_paths_url_for(crawlpath)
        wet_url_good = "https://data.commoncrawl.org/crawl-data/CC-MAIN-TEST-ERRORS/segments/0000/wet/CC-MAIN-0000-0000.warc.wet.gz"
        wet_url_bad_download = "https://data.commoncrawl.org/crawl-data/CC-MAIN-TEST-ERRORS/segments/0000/wet/CC-MAIN-0000-0001.warc.wet.gz"
        wet_url_bad_parse = "https://data.commoncrawl.org/crawl-data/CC-MAIN-TEST-ERRORS/segments/0000/wet/CC-MAIN-0000-0002.warc.wet.gz"

        index_payload = gzip_text(
            "crawl-data/CC-MAIN-TEST-ERRORS/segments/0000/wet/CC-MAIN-0000-0000.warc.wet.gz\n" *
            "crawl-data/CC-MAIN-TEST-ERRORS/segments/0000/wet/CC-MAIN-0000-0001.warc.wet.gz\n" *
            "crawl-data/CC-MAIN-TEST-ERRORS/segments/0000/wet/CC-MAIN-0000-0002.warc.wet.gz\n",
        )

        wet_payload_good = gzip_text(
            warc_record_text(
                "https://example.com/good",
                "2025-01-15T01:02:03Z",
                "en",
                "good content",
            ),
        )

        wet_payload_bad_parse = gzip_text(
            "WARC/1.0\n" *
            "WARC-Type: conversion\n" *
            "WARC-Date: 2025-01-15T01:02:03Z\n" *
            "WARC-Target-URI: https://example.com/bad\n\n" *
            "broken payload\n",
        )

        transport = MockTransport(
            Dict(
                index_url => index_payload,
                wet_url_good => wet_payload_good,
                wet_url_bad_parse => wet_payload_bad_parse,
            ),
        )

        progress_events = DownloadProgress[]
        progress_callback = progress -> begin
            push!(progress_events, progress)
            nothing
        end

        stage = start_download_stage(
            DownloadSettings(crawlpath = crawlpath);
            embedding_batchsize = 2,
            progress_callback = progress_callback,
            transport = transport,
            total_memory_bytes = 64 * 1024 * 1024,
        )

        wait(stage)
        records = collect(stage.warcs)

        @test length(records) == 1
        @test records[1].uri == "https://example.com/good"

        @test stage.stats.total_urls == 3
        @test stage.stats.completed_urls == 3
        @test stage.stats.failed_urls == 2
        @test progress_events[end].completed_urls == 3
        @test progress_events[end].failed_urls == 2
    end

    @testset "progressmeter callback updates deterministically" begin
        output = IOBuffer()
        callback = MonsieurPapin.default_progress_callback(3; output = output, dt = 0.0)

        callback(DownloadProgress(1, 3, 0))
        callback(DownloadProgress(2, 3, 0))
        callback(DownloadProgress(3, 3, 1))

        rendered = String(take!(output))
        @test occursin("Download Stage", rendered)
    end

    @testset "optional live smoke" begin
        if get(ENV, "MONSIEURPAPIN_LIVE_TESTS", "0") == "1"
            urls = fetch_wet_urls("CC-MAIN-2026-08")
            @test !isempty(urls)
            @test all(endswith(url, ".warc.wet.gz") for url in urls)
        else
            @test true
        end
    end
end
