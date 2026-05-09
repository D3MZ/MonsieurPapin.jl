using CodecZlib
using Dates
using HTTP
using JSON
using Sockets
using Test

function llmserver(respond; seed="seed content")
    requests = Channel{Dict{String,Any}}(8)
    server = HTTP.serve!(ip"127.0.0.1", 0; verbose=false) do request::HTTP.Request
        request.method == "GET" && return HTTP.Response(200, seed)
        payload = JSON.parse(String(request.body))
        put!(requests, payload)
        HTTP.Response(200, JSON.json(respond(payload)))
    end
    host, port = getsockname(server.listener.server)
    (server=server, requests=requests, baseurl="http://$(host):$(Int(port))")
end

excerpt(text, language, score=0.0) = WET(
    MonsieurPapin.Snippet("https://example.com", Val(32)),
    MonsieurPapin.Snippet(text, Val(64)),
    MonsieurPapin.Snippet(language, Val(32)),
    DateTime(2026, 3, 3),
    ncodeunits(text),
    score,
)

entryrecord(content; language="eng", uri="https://example.com") =
    "WARC/1.0\r\n" *
    "WARC-Type: conversion\r\n" *
    "WARC-Target-URI: $uri\r\n" *
    "WARC-Date: 2026-03-03T00:00:00Z\r\n" *
    "WARC-Identified-Content-Language: $language\r\n" *
    "Content-Length: $(ncodeunits(content))\r\n\r\n" *
    content

function wetpath(records...)
    path = tempname() * ".gz"
    open(path, "w") do file
        stream = GzipCompressorStream(file)
        foreach(records) do record
            write(stream, record)
        end
        close(stream)
    end
    path
end

@testset "llm" begin
    service = llmserver() do payload
        input = payload["input"]
        message = occursin("Common Crawl WET language code deu", input) ? "hallo" : "strategy"
        Dict("output" => [Dict("type" => "message", "content" => message)])
    end

    try
        config = Configuration(; baseurl=service.baseurl)
        sysprompt = "You extract trading strategies."
        inp = "Output JSON: {\"skip\": true} or {\"skip\": false}"
        data = request(;
            model=config.model,
            systemprompt=sysprompt,
            input=string(inp, "\n\n", "page text"),
            baseurl=config.baseurl,
            path=config.path,
            password=config.password,
            timeout=config.timeoutseconds,
        )
        @test extract_content(data) == "strategy"
        req = take!(service.requests)
        @test req["input"] == string(inp, "\n\npage text")
        @test req["system_prompt"] == sysprompt

        data = request(;
            model=config.model,
            systemprompt="You translate text accurately. Output only the translation.",
            input="Translate the following text into the language identified by the Common Crawl WET language code deu. Output only the translated text.\n\nhello",
            baseurl=config.baseurl,
            path=config.path,
            password=config.password,
            timeout=config.timeoutseconds,
        )
        @test extract_content(data) == "hallo"
        req = take!(service.requests)
        @test req["input"] == "Translate the following text into the language identified by the Common Crawl WET language code deu. Output only the translated text.\n\nhello"
        @test req["system_prompt"] == "You translate text accurately. Output only the translation."

        prompt = MonsieurPapin.prompt(excerpt("page text", "zho,eng", 0.2), config)
        @test occursin("LANGUAGE: zho,eng", prompt)
    finally
        close(service.server)
    end

    translated = llmserver(; seed="seed article") do payload
        message = "{\"keywords\":[\"breakout\",\"trend\"],\"query\":\"trading strategy\"}"
        Dict("output" => [Dict("type" => "message", "content" => message)])
    end

    try
        config = Configuration(; baseurl=translated.baseurl, languages=["fra"])
        MonsieurPapin.bootstrap(config, [translated.baseurl * "/seed"], "Find strategies")
        @test config.query == "trading strategy"
        @test config.keywords == ["breakout", "trend"]
        req = take!(translated.requests)
        @test occursin("Analyze the following Task and Seed Content.", req["input"])
        @test !isready(translated.requests)
    finally
        close(translated.server)
    end

    untranslated = llmserver(; seed="seed article") do payload
        message = "{\"keywords\":[\"breakout\",\"trend\"],\"query\":\"trading strategy\"}"
        Dict("output" => [Dict("type" => "message", "content" => message)])
    end

    try
        config = Configuration(; baseurl=untranslated.baseurl, languages=["eng"])
        MonsieurPapin.bootstrap(config, [untranslated.baseurl * "/seed"], "Find strategies")
        @test config.keywords == ["breakout", "trend"]
        req = take!(untranslated.requests)
        @test occursin("Analyze the following Task and Seed Content.", req["input"])
        @test !isready(untranslated.requests)
    finally
        close(untranslated.server)
    end

    emptyservice = llmserver(; seed="<html><body>Relative strength index momentum oscillator trading indicator overbought oversold</body></html>") do payload
        Dict("output" => [Dict("type" => "message", "content" => "")])
    end

    try
        outputpath = tempname()
        config = Configuration(; baseurl=emptyservice.baseurl, outputpath=outputpath, languages=["eng"])
        task = MonsieurPapin.research(config, [emptyservice.baseurl * "/seed"], wetpath(entryrecord("Gardening and cooking only."; uri="https://example.com/none")))
        wait(task)
        @test isfile(outputpath)
        @test isempty(read(outputpath, String))
        @test !isready(emptyservice.requests)
    finally
        close(emptyservice.server)
    end

    if get(ENV, "MONSIEURPAPIN_MODEL2VEC", "false") == "true"
        researchservice = llmserver(; seed="<html><body>Relative strength index is a momentum trading indicator used to spot overbought and oversold conditions.</body></html>") do payload
            input = payload["input"]
            message = occursin("SOURCE URL: https://example.com/rsi", input) ?
                "Relative Strength Index measures momentum at https://example.com/rsi.\n```julia\nsignal(prices) = rsi(prices, 14) < 30 ? :buy : :hold\n```" :
                ""
            Dict("output" => [Dict("type" => "message", "content" => message)])
        end

        try
            outputpath = tempname()
            config = Configuration(; baseurl=researchservice.baseurl, outputpath=outputpath, languages=["eng"])
            path = wetpath(
                entryrecord("Relative strength index is a momentum trading indicator used to spot overbought and oversold conditions."; uri="https://example.com/rsi"),
                entryrecord("Tomato gardening for spring."; uri="https://example.com/garden"),
            )
            task = MonsieurPapin.research(config, [researchservice.baseurl * "/seed"], path)
            wait(task)
            report = read(outputpath, String)
            req = take!(researchservice.requests)
            @test !isempty(report)
            @test occursin("https://example.com/rsi", report)
            @test occursin("```julia", report)
            @test occursin("SOURCE URL: https://example.com/rsi", req["input"])
        finally
            close(researchservice.server)
        end
    end
end
