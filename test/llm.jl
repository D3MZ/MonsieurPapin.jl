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

@testset "llm" begin
    service = llmserver() do payload
        input = payload["input"]
        message = occursin("Common Crawl WET language code deu", input) ? "hallo" : "strategy"
        Dict("output" => [Dict("type" => "message", "content" => message)])
    end

    try
        config = Configuration(; baseurl=service.baseurl)
        @test complete("page text", config) == "strategy"
        request = take!(service.requests)
        @test request["input"] == string(config.input, "\n\npage text")
        @test request["system_prompt"] == config.systemprompt

        @test translate("hello", "deu", config) == "hallo"
        request = take!(service.requests)
        @test request["input"] == "Translate the following text into the language identified by the Common Crawl WET language code deu. Output only the translated text.\n\nhello"
        @test request["system_prompt"] == "You translate text accurately. Output only the translation."

        prompt = MonsieurPapin.prompt(excerpt("page text", "zho,eng", 0.2), config)
        @test occursin("LANGUAGE: zho,eng", prompt)
    finally
        close(service.server)
    end

    translated = llmserver(; seed="seed article") do payload
        input = payload["input"]
        message =
            occursin("Analyze the following Task and Seed Content.", input) ?
            "{\"keywords\":[\"breakout\",\"trend\"],\"query\":\"trading strategy\"}" :
            "cassure\ntendance"
        Dict("output" => [Dict("type" => "message", "content" => message)])
    end

    try
        config = Configuration(; baseurl=translated.baseurl, languages=["fra"])
        MonsieurPapin.bootstrap(config, [translated.baseurl * "/seed"], "Find strategies")
        @test config.query == "trading strategy"
        @test config.keywords == ["breakout", "trend", "cassure", "tendance"]
        take!(translated.requests)
        request = take!(translated.requests)
        @test request["input"] == "Translate each line into the language identified by the Common Crawl WET language code fra. Preserve line order and output only the translated lines.\n\nbreakout\ntrend"
    finally
        close(translated.server)
    end

    untranslated = llmserver(; seed="seed article") do _
        Dict("output" => [Dict("type" => "message", "content" => "{\"keywords\":[\"breakout\",\"trend\"],\"query\":\"trading strategy\"}")])
    end

    try
        config = Configuration(; baseurl=untranslated.baseurl)
        MonsieurPapin.bootstrap(config, [untranslated.baseurl * "/seed"], "Find strategies")
        @test config.keywords == ["breakout", "trend"]
        take!(untranslated.requests)
        @test !isready(untranslated.requests)
    finally
        close(untranslated.server)
    end
end
