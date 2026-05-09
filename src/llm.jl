function request(; model::String, systemprompt::String, input::String,
                  baseurl::String, path::String, password::String="",
                  timeout::Int=120)
    body = Dict(
        "model" => model,
        "reasoning" => "off",
        "system_prompt" => systemprompt,
        "input" => input,
    )
    headers = ["Content-Type" => "application/json", "Authorization" => "Bearer $(password)"]
    response = HTTP.post(string(baseurl, path); headers=headers, body=JSON.json(body), readtimeout=timeout)
    return JSON.parse(String(response.body))
end

get_message(data) = data["output"][1]["content"]

function keywords(settings, text; limitinput=2000)
    response = request(;
        model=settings["llm"]["model"],
        systemprompt=settings["prompts"]["keywords_system"],
        input=first(text, limitinput),
        baseurl=settings["llm"]["baseurl"],
        path=settings["llm"]["path"],
        password=settings["llm"]["password"],
        timeout=settings["llm"]["timeout"],
    )
    return JSON.parse(get_message(response))
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

