function request(; model::String, systemprompt::String, input::String,
                  baseurl::String, path::String, password::String="",
                  timeout::Int=120, responseformat=nothing)
    body = Dict(
        "model" => model,
        "messages" => [
            Dict("role" => "system", "content" => systemprompt),
            Dict("role" => "user", "content" => input),
        ],
    )
    !isnothing(responseformat) && (body["response_format"] = responseformat)
    headers = ["Content-Type" => "application/json", "Authorization" => "Bearer $(password)"]
    response = HTTP.post(string(baseurl, path); headers=headers, body=JSON.json(body), readtimeout=timeout)
    return JSON.parse(String(response.body))
end

message(data) = data["choices"][1]["message"]["content"]

function extractkeywords(settings, text; limitinput=2000)
    response = request(;
        model=settings["llm"]["model"],
        systemprompt=settings["prompts"]["keywords_system"],
        input=first(text, limitinput),
        baseurl=settings["llm"]["baseurl"],
        path=settings["llm"]["path"],
        password=settings["llm"]["password"],
        timeout=settings["llm"]["timeout"],
        responseformat=Dict(
            "type" => "json_schema",
            "json_schema" => Dict(
                "name" => "keywords",
                "strict" => "true",
                "schema" => Dict(
                    "type" => "object",
                    "properties" => Dict(
                        "keywords" => Dict(
                            "type" => "array",
                            "items" => Dict("type" => "string"),
                        ),
                    ),
                    "required" => ["keywords"],
                ),
            ),
        ),
    )
    return JSON.parse(message(response))["keywords"]
end

function summarize(settings, text; limit=140)
    response = request(;
        model=settings["llm"]["model"],
        systemprompt=settings["prompts"]["summary_system"],
        input=string("Summarize in at most $(limit) characters:\n\n", text),
        baseurl=settings["llm"]["baseurl"],
        path=settings["llm"]["path"],
        password=settings["llm"]["password"],
        timeout=settings["llm"]["timeout"],
    )
    return message(response)
end

