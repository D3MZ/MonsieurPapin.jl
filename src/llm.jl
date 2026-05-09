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

