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
    "eng" => "English", "fra" => "French", "por" => "Portuguese", "deu" => "German",
    "ron" => "Romanian", "swe" => "Swedish", "dan" => "Danish", "bul" => "Bulgarian",
    "rus" => "Russian", "ces" => "Czech", "ell" => "Greek", "ukr" => "Ukrainian",
    "spa" => "Spanish", "nld" => "Dutch", "slk" => "Slovak", "hrv" => "Croatian",
    "pol" => "Polish", "lit" => "Lithuanian", "nob" => "Norwegian Bokmål", "nno" => "Norwegian Nynorsk",
    "fas" => "Persian", "slv" => "Slovenian", "guj" => "Gujarati", "lav" => "Latvian",
    "ita" => "Italian", "oci" => "Occitan", "nep" => "Nepali", "mar" => "Marathi",
    "bel" => "Belarusian", "srp" => "Serbian", "ltz" => "Luxembourgish", "asm" => "Assamese",
    "cym" => "Welsh", "snd" => "Sindhi", "gle" => "Irish", "fao" => "Faroese",
    "hin" => "Hindi", "pan" => "Punjabi", "ben" => "Bengali", "ori" => "Odia",
    "tgk" => "Tajik", "yid" => "Yiddish", "glg" => "Galician", "cat" => "Catalan",
    "isl" => "Icelandic", "sqi" => "Albanian", "afr" => "Afrikaans", "mkd" => "Macedonian",
    "sin" => "Sinhala", "urd" => "Urdu", "bos" => "Bosnian", "hye" => "Armenian",
    "zho" => "Chinese", "mya" => "Burmese", "ara" => "Arabic", "heb" => "Hebrew",
    "mlt" => "Maltese", "ind" => "Indonesian", "msa" => "Malay", "tgl" => "Tagalog",
    "ceb" => "Cebuano", "jav" => "Javanese", "sun" => "Sundanese", "war" => "Waray",
    "tam" => "Tamil", "tel" => "Telugu", "kan" => "Kannada", "mal" => "Malayalam",
    "tur" => "Turkish", "aze" => "Azerbaijani", "uzb" => "Uzbek", "kaz" => "Kazakh",
    "bak" => "Bashkir", "tat" => "Tatar", "tha" => "Thai", "lao" => "Lao",
    "fin" => "Finnish", "est" => "Estonian", "hun" => "Hungarian", "vie" => "Vietnamese",
    "khm" => "Khmer", "jpn" => "Japanese", "kor" => "Korean", "kat" => "Georgian",
    "eus" => "Basque", "hat" => "Haitian Creole", "swa" => "Swahili",
)
targetlanguages(codes) = join((get(languagenames, c, c) for c in codes), ", ")

function extractkeywords(settings, text; limitinput=2000, timeout=settings["llm"]["timeout"],
                          langs=settings["crawl"]["languages"])
    languages = targetlanguages(langs)
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
                            # blows past any timeout. Keywords are generated per language BATCH
                            # (~6 languages x ~25 concepts = ~150 elements per call), so 512 gives
                            # ample per-batch headroom without reintroducing a max_tokens cap.
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

