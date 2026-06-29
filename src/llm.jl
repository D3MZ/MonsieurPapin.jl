function request(; model::String, systemprompt::String, input::String,
                  baseurl::String, path::String, password::String="",
                  timeout::Int=120, responseformat=nothing, maxtokens=nothing, temperature=nothing)
    body = Dict(
        "model" => model,
        "messages" => [
            Dict("role" => "system", "content" => systemprompt),
            Dict("role" => "user", "content" => input),
        ],
    )
    !isnothing(responseformat) && (body["response_format"] = responseformat)
    !isnothing(maxtokens) && (body["max_tokens"] = maxtokens)      # hard bound: stop runaway generation
    !isnothing(temperature) && (body["temperature"] = temperature)
    headers = ["Content-Type" => "application/json", "Authorization" => "Bearer $(password)"]
    response = HTTP.post(string(baseurl, path); headers=headers, body=JSON.json(body), readtimeout=timeout)
    return JSON.parse(String(response.body))
end

message(data) = data["choices"][1]["message"]["content"]

# Map the crawl's ISO-639-3 language codes to English names for the keyword prompt, so the target
# languages stay in sync with [crawl] languages instead of being hardcoded in the prompt text.
const languagenames = Dict(
    "eng" => "English", "deu" => "German", "rus" => "Russian", "jpn" => "Japanese",
    "zho" => "Chinese", "spa" => "Spanish", "fra" => "French", "por" => "Portuguese",
    "ita" => "Italian", "pol" => "Polish", "nld" => "Dutch", "kor" => "Korean",
    "ara" => "Arabic", "hin" => "Hindi", "tur" => "Turkish", "vie" => "Vietnamese",
)
targetlanguages(codes) = join((get(languagenames, c, c) for c in codes), ", ")

function extractkeywords(settings, text; limitinput=2000, timeout=settings["llm"]["timeout"])
    languages = targetlanguages(settings["crawl"]["languages"])
    response = request(;
        model=settings["llm"]["model"],
        systemprompt=settings["prompts"]["keywords_system"],
        input=string("Target languages: ", languages, "\n\nText:\n", first(text, limitinput)),
        baseurl=settings["llm"]["baseurl"],
        path=settings["llm"]["path"],
        password=settings["llm"]["password"],
        timeout=timeout,
        maxtokens=3500,        # safety bound; the bounded prompt naturally finishes well under this
        temperature=0.2,
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

