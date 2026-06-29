function request(; model::String, systemprompt::String, input::String,
                  baseurl::String, path::String, password::String="",
                  timeout::Int=120, responseformat=nothing, maxtokens=nothing, temperature=nothing,
                  thinking::Bool=false)
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
    # Thinking is off by default: reasoning models (e.g. Qwen3) otherwise spend the whole token
    # budget on chain-of-thought and return empty content, and the extraction pipeline wants the
    # answer directly anyway. Servers that don't understand this field ignore it.
    thinking || (body["chat_template_kwargs"] = Dict("enable_thinking" => false))
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
        thinking=get(settings["llm"], "thinking", false),
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
                            # Bound the array so the grammar forces it closed. Without an upper
                            # bound a reasoning model (e.g. Qwen3) keeps emitting grammar-valid
                            # elements indefinitely — observed 17k+ tokens for one call, which
                            # blows past any timeout. 30 concepts x up to ~16 target languages
                            # ~= 480 elements, so 512 leaves headroom without capping max_tokens.
                            "items" => Dict("type" => "string"),
                            "maxItems" => 512,
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
        thinking=get(settings["llm"], "thinking", false),
    )
    return message(response)
end

