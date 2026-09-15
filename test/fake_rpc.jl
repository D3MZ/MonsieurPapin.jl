using JSON

for line in eachline(stdin)
    request = JSON.parse(line)
    if haskey(request, "method") && request["method"] == "initialize"
        println(stdout, JSON.json(Dict("id" => request["id"], "result" => Dict("initialized" => true))))
    elseif haskey(request, "method") && request["method"] == "account/rateLimits/read"
        "app-error" in ARGS && println(stdout, JSON.json(Dict("id" => request["id"], "error" => Dict("code" => -32000, "message" => "rate-limit failure"))))
        "app-error" in ARGS && continue
        println(stdout, JSON.json(Dict("id" => request["id"], "result" => Dict(
            "rateLimits" => Dict(
                "primary" => Dict("usedPercent" => 12, "windowDurationMins" => 300, "resetsAt" => 1_900_000_000),
                "secondary" => nothing,
            ),
            "rateLimitsByLimitId" => Dict(
                "test-limit" => Dict(
                    "limitName" => "test-model",
                    "primary" => Dict("usedPercent" => 12, "windowDurationMins" => 300, "resetsAt" => 1_900_000_000),
                    "secondary" => nothing,
                ),
            ),
        ))))
    elseif haskey(request, "type") && request["type"] == "prompt"
        "rpc-error" in ARGS && println(stdout, JSON.json(Dict("type" => "response", "command" => "prompt", "success" => false, "error" => "prompt failure")))
        "rpc-error" in ARGS && flush(stdout)
        "rpc-error" in ARGS && continue
        "rpc-timeout" in ARGS && continue
        println(stdout, JSON.json(Dict(
            "type" => "message_end",
            "message" => Dict(
                "role" => "assistant",
                "content" => [Dict("type" => "text", "text" => occursin("configured-rpc", request["message"]) ? join(ARGS, " ") : "rpc response")],
                "stopReason" => "stop",
                "usage" => Dict("input" => 3, "output" => 2),
            ),
        )))
        println(stdout, JSON.json(Dict("type" => "agent_settled")))
    end
    flush(stdout)
end
