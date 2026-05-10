using CodecZlib
using Dates
using HTTP
using JSON
using MonsieurPapin
using Sockets
using Test

function llmserver(respond; seed="seed content")
    requests = Channel{Dict{String,Any}}(8)
    server = HTTP.serve!(ip"127.0.0.1", 0; verbose=false) do req::HTTP.Request
        req.method == "GET" && return HTTP.Response(200, seed)
        payload = JSON.parse(String(req.body))
        put!(requests, payload)
        HTTP.Response(200, JSON.json(respond(payload)))
    end
    host, port = getsockname(server.listener.server)
    (server=server, requests=requests, baseurl="http://$(host):$(Int(port))")
end

testsettings(baseurl; languages=["eng"], outputpath="research.md") = Dict(
    "crawl" => Dict("languages" => languages),
    "pipeline" => Dict("capacity" => 100, "threshold" => 0.6, "dedupe_capacity" => 1000, "keywords" => String[]),
    "embedding" => Dict("model" => "minishlab/potion-multilingual-128M"),
    "llm" => Dict("baseurl" => baseurl, "path" => "/v1/chat/completions", "model" => "qwen/qwen3.6-27b", "password" => "", "timeout" => 120),
    "output" => Dict("path" => outputpath),
    "prompts" => Dict("system" => "", "input" => "", "local_system" => "", "local_input" => "", "keywords_system" => "Extract keywords from this text.", "summary_system" => "Summarize this text."),
)

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
    "WARC-Target-URI: $(uri)\r\n" *
    "WARC-Date: 2026-03-03T00:00:00Z\r\n" *
    "WARC-Identified-Content-Language: $(language)\r\n" *
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
        messages = payload["messages"]
        user_msg = messages[2]["content"]
        message = occursin("Common Crawl WET language code deu", user_msg) ? "hallo" : "strategy"
        Dict("choices" => [Dict("message" => Dict("content" => message))])
    end

    try
        settings = testsettings(service.baseurl)
        sysprompt = "You extract trading strategies."
        inp = "Output JSON."
        data = request(;
            model=settings["llm"]["model"],
            systemprompt=sysprompt,
            input=string(inp, "\n\n", "page text"),
            baseurl=settings["llm"]["baseurl"],
            path=settings["llm"]["path"],
            password=settings["llm"]["password"],
            timeout=settings["llm"]["timeout"],
        )
        @test get_message(data) == "strategy"
        req = take!(service.requests)
        @test req["messages"][2]["content"] == string(inp, "\n\npage text")
        @test req["messages"][1]["role"] == "system"
        @test req["messages"][1]["content"] == sysprompt

        data = request(;
            model=settings["llm"]["model"],
            systemprompt="You translate text accurately. Output only the translation.",
            input="Translate the following text into the language identified by the Common Crawl WET language code deu. Output only the translated text.\n\nhello",
            baseurl=settings["llm"]["baseurl"],
            path=settings["llm"]["path"],
            password=settings["llm"]["password"],
            timeout=settings["llm"]["timeout"],
        )
        @test get_message(data) == "hallo"
        req = take!(service.requests)
        @test req["messages"][2]["content"] == "Translate the following text into the language identified by the Common Crawl WET language code deu. Output only the translated text.\n\nhello"
        @test req["messages"][1]["content"] == "You translate text accurately. Output only the translation."

        prompt = MonsieurPapin.prompt(excerpt("page text", "zho,eng", 0.2))
        @test occursin("LANGUAGE: zho,eng", prompt)
    finally
        close(service.server)
    end

    translated = llmserver(; seed="seed article") do payload
        message = "{\"keywords\": [\"breakout\",\"trend\"]}"
        Dict("choices" => [Dict("message" => Dict("content" => message))])
    end

    try
        settings = testsettings(translated.baseurl; languages=["fra"])
        result = keywords(settings, "seed article")
        @test result == ["breakout", "trend"]
        req = take!(translated.requests)
        @test occursin("seed article", req["messages"][2]["content"])
        @test !isnothing(req["response_format"])
        @test req["response_format"]["json_schema"]["name"] == "keywords"
        @test !isready(translated.requests)
    finally
        close(translated.server)
    end

    unservice = llmserver(; seed="seed article") do payload
        Dict("choices" => [Dict("message" => Dict("content" => "a short summary"))])
    end

    try
        settings = testsettings(unservice.baseurl; languages=["eng"])
        result = MonsieurPapin.summary(settings, "seed article")
        @test result == "a short summary"
        req = take!(unservice.requests)
        @test occursin("Summarize in at most 140 characters", req["messages"][2]["content"])
        @test !isready(unservice.requests)
    finally
        close(unservice.server)
    end

    emptyservice = llmserver(; seed="<html><body>Relative strength index momentum oscillator trading indicator overbought oversold</body></html>") do payload
        Dict("choices" => [Dict("message" => Dict("content" => ""))])
    end

    try
        outputpath = tempname()
        settings = testsettings(emptyservice.baseurl; languages=["eng"], outputpath=outputpath)
        task = MonsieurPapin.research(settings, [emptyservice.baseurl * "/seed"], wetpath(entryrecord("Gardening and cooking only."; uri="https://example.com/none")))
        wait(task)
        @test isfile(outputpath)
        @test isempty(read(outputpath, String))
        @test !isready(emptyservice.requests)
    finally
        close(emptyservice.server)
    end

    if get(ENV, "MONSIEURPAPIN_MODEL2VEC", "false") == "true"
        researchservice = llmserver(; seed="<html><body>Relative strength index is a momentum trading indicator used to spot overbought and oversold conditions.</body></html>") do payload
            user_msg = payload["messages"][2]["content"]
            message = occursin("SOURCE URL: https://example.com/rsi", user_msg) ?
                "Relative Strength Index measures momentum at https://example.com/rsi.\n```julia\nsignal(prices) = rsi(prices, 14) < 30 ? :buy : :hold\n```" :
                ""
            Dict("choices" => [Dict("message" => Dict("content" => message))])
        end

        try
            outputpath = tempname()
            settings = testsettings(researchservice.baseurl; languages=["eng"], outputpath=outputpath)
            path = wetpath(
                entryrecord("Relative strength index is a momentum trading indicator used to spot overbought and oversold conditions."; uri="https://example.com/rsi"),
                entryrecord("Tomato gardening for spring."; uri="https://example.com/garden"),
            )
            task = MonsieurPapin.research(settings, [researchservice.baseurl * "/seed"], path)
            wait(task)
            report = read(outputpath, String)
            req = take!(researchservice.requests)
            @test !isempty(report)
            @test occursin("https://example.com/rsi", report)
            @test occursin("```julia", report)
            @test occursin("SOURCE URL: https://example.com/rsi", req["messages"][2]["content"])
        finally
            close(researchservice.server)
        end
    end
end
