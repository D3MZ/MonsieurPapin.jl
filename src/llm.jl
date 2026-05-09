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



function get_message(data)
    for entry in data["output"]
        entry["type"] == "message" && return entry["content"]
    end
    return ""
end

function stripjson(text::AbstractString)
    return text[findfirst('{', text):findlast('}', text)]
end


