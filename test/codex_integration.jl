#!/usr/bin/env julia
using BufferedStreams
using CodecZlib
using HTTP
using JSON
using MonsieurPapin
using TOML
using Test

# test/codex_integration.jl run
#
# Opt-in real-data validation. Reads archive paths from the configured Common Crawl index,
# then runs those actual WET archives through parsing, keyword filtering, SimHash deduplication,
# embedding selection, and the authenticated Codex extraction stage. The standalone file is not
# included by ordinary CI; the literal `run` argument is required to make subscription use explicit.
"run" in ARGS || error("Pass the literal run argument to enable the subscription integration test")

root = dirname(@__DIR__)
settings = TOML.parsefile(joinpath(root, "settings.toml"))
crawl = settings["crawl"]
integration = settings["integration"]
artifacts = joinpath(root, integration["output"])
mkpath(artifacts)

function firstpaths(path::String, count::Int)
    paths = String[]
    HTTP.request("GET", path; body=UInt8[], iofunction=stream -> begin
        response = HTTP.startread(stream)
        response.status == 200 || return
        gzip = GzipDecompressorStream(BufferedInputStream(stream))
        delimiter = codeunits("\n")[1]
        append!(paths, (String(readuntil(gzip, delimiter; keep=false)) for _ in 1:count))
    end, retry=true, retries=crawl["retry"]["retries"],
    retry_delays=Base.ExponentialBackOff(n=crawl["retry"]["retries"], factor=crawl["retry"]["factor"]))
    paths
end

function writepaths(path::String, paths)
    open(path, "w") do file
        gzip = GzipCompressorStream(file)
        foreach(paths) do entry
            write(gzip, entry, '\n')
        end
        close(gzip)
    end
end

mktempdir() do dir
    paths = firstpaths(crawl["path"], integration["archives"])
    @test length(paths) == integration["archives"]
    index = joinpath(dir, "selected.paths.gz")
    writepaths(index, paths)

    settings["crawl"]["path"] = index
    settings["output"]["path"] = joinpath(artifacts, "research.md")
    settings["llm"]["usage"]["log"] = joinpath(artifacts, "usage.jsonl")
    open(settings["llm"]["usage"]["log"], "w") do file
        flush(file)
    end

    wait(research(settings))

    @test isfile(settings["output"]["path"])
    @test isfile(settings["llm"]["usage"]["log"])
    entries = JSON.parse.(filter(!isempty, split(read(settings["llm"]["usage"]["log"], String), '\n')))
    @test !isempty(entries)
    @test all(entry -> entry["limitName"] == settings["llm"]["usage"]["limit_name"], entries)
    @test entries[end]["calls"] > 0
    @test entries[end]["attempts"] == entries[end]["calls"]
    @info "Codex integration complete" archives=paths calls=entries[end]["calls"] output=settings["output"]["path"] usage=settings["llm"]["usage"]["log"]
end
