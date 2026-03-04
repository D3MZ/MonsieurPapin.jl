url(config::Configuration) = string(config.baseurl, config.path)

headers(config::Configuration) =
    isempty(config.password) ?
    ["Content-Type" => "application/json"] :
    ["Content-Type" => "application/json", "Authorization" => "Bearer $(config.password)"]

request(config::Configuration, page::AbstractString) = Dict(
    "model" => config.model,
    "messages" => [
        Dict("role" => "system", "content" => config.systemprompt),
        Dict("role" => "user", "content" => string(config.input, "\n\n", page)),
    ],
)

function complete(page::AbstractString, config::Configuration)
    response = HTTP.post(url(config); headers=headers(config), body=JSON.json(request(config, page)), readtimeout=config.timeoutseconds)
    data = JSON.parse(String(response.body))
    data["choices"][1]["message"]["content"]
end
