url(config::Configuration) = string(config.baseurl, config.path)

headers(config::Configuration) =
    isempty(config.password) ?
    ["Content-Type" => "application/json"] :
    ["Content-Type" => "application/json", "Authorization" => "Bearer $(config.password)"]

request(config::Configuration, page::AbstractString) = Dict(
    "model" => config.model,
    "input" => string(config.systemprompt, "\n\n", config.input, "\n\n", page),
)

content(data) = first(filter(entry -> entry["type"] == "message", data["output"]))["content"]

function complete(page::AbstractString, config::Configuration)
    response = HTTP.post(url(config); headers=headers(config), body=JSON.json(request(config, page)), readtimeout=config.timeoutseconds)
    data = JSON.parse(String(response.body))
    content(data)
end
