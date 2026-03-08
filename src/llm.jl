url(config::Configuration) = string(config.baseurl, config.path)

headers(config::Configuration) =
    isempty(config.password) ?
    ["Content-Type" => "application/json"] :
    ["Content-Type" => "application/json", "Authorization" => "Bearer $(config.password)"]

request(config::Configuration, page::AbstractString) = Dict(
    "model" => config.model,
    "system_prompt" => config.systemprompt,
    "input" => string(config.input, "\n\n", page),
)

outputs(data) = get(data, "output", Any[])
messages(data) = filter(entry -> get(entry, "type", "") == "message", outputs(data))
text(entry) = get(entry, "content", get(entry, "text", JSON.json(entry)))
result(data) = isempty(messages(data)) ? "" : text(first(messages(data)))

function complete(page::AbstractString, config::Configuration)
    response = HTTP.post(url(config); headers=headers(config), body=JSON.json(request(config, page)), readtimeout=config.timeoutseconds)
    data = JSON.parse(String(response.body))
    result(data)
end
