function request(; model::String, systemprompt::String, input::String,
                  baseurl::String, path::String, password::String="",
                  timeout::Int=120, response_format=nothing)
    body = Dict(
        "model" => model,
        "messages" => [
            Dict("role" => "system", "content" => systemprompt),
            Dict("role" => "user", "content" => input),
        ],
    )
    !isnothing(response_format) && (body["response_format"] = response_format)
    headers = ["Content-Type" => "application/json", "Authorization" => "Bearer $(password)"]
    response = HTTP.post(string(baseurl, path); headers=headers, body=JSON.json(body), readtimeout=timeout)
    return JSON.parse(String(response.body))
end

get_message(data) = data["choices"][1]["message"]["content"]

function keywords(settings, text; limitinput=2000)
    response = request(;
        model=settings["llm"]["model"],
        systemprompt=settings["prompts"]["keywords_system"],
        input=first(text, limitinput),
        baseurl=settings["llm"]["baseurl"],
        path=settings["llm"]["path"],
        password=settings["llm"]["password"],
        timeout=settings["llm"]["timeout"],
        response_format=Dict(
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
    return JSON.parse(get_message(response))["keywords"]
end

function summary(settings, text; limit=140)
    response = request(;
        model=settings["llm"]["model"],
        systemprompt=settings["prompts"]["summary_system"],
        input=string("Summarize in at most $(limit) characters:\n\n", text),
        baseurl=settings["llm"]["baseurl"],
        path=settings["llm"]["path"],
        password=settings["llm"]["password"],
        timeout=settings["llm"]["timeout"],
    )
    return get_message(response)
end

