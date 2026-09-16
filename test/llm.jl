using CodecZlib
using Dates
using HTTP
using JSON
using Model2Vec
using MonsieurPapin
using Sockets
using Test

include(joinpath(dirname(pathof(Model2Vec)), "..", "test", "fixtures.jl"))

function llmserver(respond; seed="seed content")
    requests = Channel{Dict{String,Any}}(8)
    server = HTTP.serve!("127.0.0.1", 0; verbose=false) do req::HTTP.Request
        req.method == "GET" && return HTTP.Response(200, ["Content-Length" => string(ncodeunits(seed)), "Connection" => "close"], seed)
        payload = JSON.parse(String(req.body))
        put!(requests, payload)
        HTTP.Response(200, JSON.json(respond(payload)))
    end
    port = hasproperty(server.listener, :server) ? last(getsockname(server.listener.server)) : HTTP.port(server)
    (server=server, requests=requests, baseurl="http://127.0.0.1:$(Int(port))")
end

testsettings(baseurl; languages=["eng"], outputpath="research.md", embeddingmodel="minishlab/potion-multilingual-128M") = Dict(
    "crawl" => Dict("languages" => languages, "manual_keywords" => Dict{String,Any}(), "retry" => Dict("retries" => 0, "factor" => 3.0)),
    "pipeline" => Dict("capacity" => 100, "threshold" => 0.6, "dedupe_capacity" => 1000, "dedupe_batchsize" => 10, "keywords" => String[], "keyword_cache" => tempname(), "min_keywords" => 1, "seeds" => String[]),
    "embedding" => Dict("model" => embeddingmodel),
    "llm" => Dict("provider" => "local", "baseurl" => baseurl, "path" => "/v1/chat/completions", "model" => "qwen/qwen3.6-27b", "password" => "", "timeout" => 120, "thinking" => false, "keyword_input_limit" => 2000, "parallel" => 1),
    "output" => Dict("path" => outputpath),
    "prompts" => Dict("system" => "", "input" => "", "keywords_system" => "Extract keywords from this text."),
)

mutable struct BootstrapMonitor
    calls::Int
    responses::Vector{Dict{String,Any}}
end

struct BootstrapBackend <: LLMBackend end
MonsieurPapin.admit(::BootstrapMonitor) = true
MonsieurPapin.attempt!(monitor::BootstrapMonitor) = (monitor.calls += 1)
MonsieurPapin.record!(monitor::BootstrapMonitor, response) = push!(monitor.responses, response)
MonsieurPapin.request(::BootstrapBackend, systemprompt::String, input::String) = Dict(
    "choices" => [Dict("message" => Dict("content" => "{\"keywords\":[\"breakout\"]}"))],
    "usage" => Dict("input" => 3, "output" => 2, "cacheRead" => 1, "cacheWrite" => 0, "totalTokens" => 6),
)

excerpt(text, language="eng", score=0.0) = WET(
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

@testset "bootstrap accounting" begin
    mktempdir() do dir
        vecpath = buildwordpiecefixture(joinpath(dir, "model"))
        settings = testsettings("unused"; languages=["eng", "fra"], embeddingmodel=vecpath)
        bootstrapmonitor = BootstrapMonitor(0, Dict{String,Any}[])
        MonsieurPapin.bootstrap(settings["crawl"], settings["pipeline"], settings["embedding"], BootstrapBackend(), settings["llm"], settings["prompts"], bootstrapmonitor)
        @test bootstrapmonitor.calls == 2
        @test length(bootstrapmonitor.responses) == 2
    end
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
            thinking=settings["llm"]["thinking"],
        )
        @test message(data) == "strategy"
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
            thinking=settings["llm"]["thinking"],
        )
        @test message(data) == "hallo"
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
        client = llm(settings["llm"])
        result = extractkeywords(client, settings["prompts"], "seed article"; limitinput=settings["llm"]["keyword_input_limit"], timeout=settings["llm"]["timeout"], langs=settings["crawl"]["languages"], monitor=NoUsage())
        @test result == ["breakout", "trend"]
        req = take!(translated.requests)
        @test occursin("seed article", req["messages"][2]["content"])
        @test !isready(translated.requests)
    finally
        close(translated.server)
    end


    emptyservice = llmserver(; seed="<html><body>Relative strength index momentum oscillator trading indicator overbought oversold</body></html>") do payload
        Dict("choices" => [Dict("message" => Dict("content" => ""))])
    end

    try
        mktempdir() do dir
            vecpath = buildwordpiecefixture(joinpath(dir, "model"))
            outputpath = tempname()
            settings = testsettings(emptyservice.baseurl; languages=["eng"], outputpath=outputpath, embeddingmodel=vecpath)
            task = MonsieurPapin.research(settings, [emptyservice.baseurl * "/seed"], wetpath(entryrecord("Gardening and cooking only."; uri="https://example.com/none")))
            wait(task)
            @test isfile(outputpath)
            @test isempty(read(outputpath, String))
            @test !isready(emptyservice.requests)
        end
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
            mktempdir() do dir
                vecpath = buildwordpiecefixture(joinpath(dir, "model"))
                outputpath = tempname()
                settings = testsettings(researchservice.baseurl; languages=["eng"], outputpath=outputpath, embeddingmodel=vecpath)
                path = wetpath(
                    entryrecord("Relative strength index is a momentum trading indicator used to spot overbought and oversold conditions."; uri="https://example.com/rsi"),
                    entryrecord("Tomato gardening for spring."; uri="https://example.com/garden"),
                )
                task = MonsieurPapin.research(settings, [researchservice.baseurl * "/seed"], path)
                wait(task)
                report = read(outputpath, String)
                requests = Dict{String,Any}[]
                while isready(researchservice.requests)
                    push!(requests, take!(researchservice.requests))
                end
                @test !isempty(requests)
                @test any(req -> occursin("SOURCE URL: https://example.com/rsi", req["messages"][2]["content"]), requests)
                @test !isempty(report)
                @test occursin("https://example.com/rsi", report)
                @test occursin("```julia", report)
            end
        finally
            close(researchservice.server)
        end
    end

    failing = HTTP.serve!("127.0.0.1", 0; verbose=false) do req
        req.method == "GET" && return HTTP.Response(200, "seed")
        HTTP.Response(500, ["Content-Length" => "7", "Connection" => "close"], "failure")
    end

    try
        port = hasproperty(failing.listener, :server) ? last(getsockname(failing.listener.server)) : HTTP.port(failing)
        settings = testsettings("http://127.0.0.1:$(Int(port))"; languages=["eng"])
        settings["llm"]["parallel"] = 1
        settings["output"]["path"] = tempname()
        failure_prompt = MonsieurPapin.prompt(excerpt("strategy"))
        client = llm(settings["llm"])
        task = @async extract([excerpt("strategy")], client, settings["output"], settings["prompts"]["system"], settings["prompts"]["input"], failure_prompt; mode="w", workers=1, monitor=NoUsage())
        @test_throws TaskFailedException wait(task)
        close(client)
    finally
        close(failing)
    end

    extraction = llmserver() do payload
        Dict("choices" => [Dict("message" => Dict("content" => "ok"))])
    end

    try
        settings = testsettings(extraction.baseurl; languages=["eng"])
        settings["llm"]["parallel"] = 1
        settings["output"]["path"] = tempname()
        client = llm(settings["llm"])
        task = @async extract([excerpt("strategy")], client, settings["output"], settings["prompts"]["system"], settings["prompts"]["input"], _ -> "ignored"; mode="w", workers=1, monitor=NoUsage())
        wait(task)
        @test isfile(settings["output"]["path"])
        @test occursin("ok", read(settings["output"]["path"], String))
    finally
        close(extraction.server)
    end
end

@testset "persistent RPC" begin
    script = joinpath(dirname(@__DIR__), "test", "fake_rpc.jl")
    command = ["julia", "--startup-file=no", "--project=$(dirname(@__DIR__))", script]
    rpcsettings = Dict("command" => command, "provider" => "test-provider", "model" => "test-model", "parallel" => 1, "timeout" => 10)
    client = PiRPC(rpcsettings)
    response = request(client, "system", "input")
    @test message(response) == "rpc response"
    configured = request(client, "system", "configured-rpc")
    @test occursin("--provider test-provider --model test-model", message(configured))
    close(client)

    errorclient = PiRPC(Dict("command" => vcat(command, ["rpc-error"]), "provider" => "test-provider", "model" => "test-model", "parallel" => 1, "timeout" => 10))
    @test_throws ErrorException request(errorclient, "system", "input")
    close(errorclient)

    timeoutclient = PiRPC(Dict("command" => vcat(command, ["rpc-timeout"]), "provider" => "test-provider", "model" => "test-model", "parallel" => 1, "timeout" => 0.01))
    @test_throws ErrorException request(timeoutclient, "system", "input")
    close(timeoutclient)

    usagesettings = Dict(
        "command" => command,
        "initialize_method" => "initialize",
        "initialized_method" => "initialized",
        "initialize_params" => Dict("clientInfo" => Dict("name" => "test", "version" => "1")),
        "timeout" => 10,
        "method" => "account/rateLimits/read",
        "params" => Dict(),
        "limit_name" => "test-limit",
    )
    server = CodexAppServer(usagesettings)
    snapshot = usage(server, usagesettings)
    @test snapshot["rateLimits"]["primary"]["usedPercent"] == 12
    @test snapshot["rateLimitsByLimitId"]["test-limit"]["limitName"] == "test-model"
    close(server)

    logpath = tempname()
    monitor = UsageMonitor(merge(usagesettings, Dict("interval" => 0.01, "drop" => 10, "log" => logpath)))
    sleep(0.03)

    MonsieurPapin.attempt!(monitor)
    MonsieurPapin.record!(monitor, Dict("usage" => Dict(
        "input" => 3, "output" => 2, "cacheRead" => 1, "cacheWrite" => 4, "totalTokens" => 10,
        "cost" => Dict("input" => 0.3, "output" => 0.2, "cacheRead" => 0.1, "cacheWrite" => 0.4, "total" => 1.0),
    )))
    MonsieurPapin.attempt!(monitor)
    MonsieurPapin.record!(monitor, Dict("usage" => Dict(
        "input" => 7, "output" => 5, "cacheRead" => 2, "cacheWrite" => 6, "totalTokens" => 14,
        "cost" => Dict("input" => 0.7, "output" => 0.5, "cacheRead" => 0.2, "cacheWrite" => 0.6, "total" => 2.0),
    )))
    close(monitor)
    log = read(logpath, String)
    @test count(==('\n'), log) >= 2
    @test occursin("remainingPercent", log)
    @test occursin("attempts", log)
    entries = JSON.parse.(filter(!isempty, split(log, '\n')))
    finalentry = entries[end]
    @test finalentry["calls"] == 2
    @test finalentry["usage"]["input"] == 10
    @test finalentry["usage"]["output"] == 7
    @test finalentry["usage"]["cacheRead"] == 3
    @test finalentry["usage"]["cacheWrite"] == 10
    @test finalentry["usage"]["totalTokens"] == 24
    @test finalentry["usage"]["cost"]["total"] == 3.0
end
