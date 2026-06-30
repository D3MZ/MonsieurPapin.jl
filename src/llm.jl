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
    # answer directly anyway. Send both the nested (llama.cpp) and top-level (LM Studio) forms of
    # the flag; servers that don't recognize either form simply ignore it. message() additionally
    # falls back to reasoning_content if content is still empty (observed: LM Studio's engine
    # ignores this flag under response_format=json_schema regardless of which form is sent).
    if !thinking
        body["chat_template_kwargs"] = Dict("enable_thinking" => false)
        body["enable_thinking"] = false
    end
    headers = ["Content-Type" => "application/json", "Authorization" => "Bearer $(password)"]
    response = HTTP.post(string(baseurl, path); headers=headers, body=JSON.json(body), readtimeout=timeout)
    return JSON.parse(String(response.body))
end

# Some servers (observed: LM Studio's engine, specifically under response_format=json_schema)
# route the entire answer into reasoning_content and leave content empty regardless of the
# enable_thinking flag. Fall back so a structured/reasoning quirk doesn't surface as an empty
# string (and downstream JSON.parse("") -> UnexpectedEOF, which previously crashed a long run).
function message(data)
    msg = data["choices"][1]["message"]
    content = get(msg, "content", "")
    isempty(strip(content)) ? get(msg, "reasoning_content", "") : content
end

# Map the crawl's ISO-639-3 language codes to English names for the keyword prompt, so the target
# languages stay in sync with [crawl] languages instead of being hardcoded in the prompt text.
const languagenames = Dict(
    "aar" => "Afar", "abk" => "Abkhazian", "afr" => "Afrikaans", "aka" => "Akan",
    "amh" => "Amharic", "ara" => "Arabic", "asm" => "Assamese", "aym" => "Aymara",
    "aze" => "Azerbaijani", "bak" => "Bashkir", "bel" => "Belarusian", "ben" => "Bengali",
    "bih" => "Bihari", "bis" => "Bislama", "bod" => "Tibetan", "bos" => "Bosnian",
    "bre" => "Breton", "bul" => "Bulgarian", "cat" => "Catalan", "ceb" => "Cebuano",
    "ces" => "Czech", "chr" => "Cherokee", "cos" => "Corsican", "crs" => "Seselwa",
    "cym" => "Welsh", "dan" => "Danish", "deu" => "German", "div" => "Dhivehi",
    "dzo" => "Dzongkha", "ell" => "Greek", "eng" => "English", "epo" => "Esperanto",
    "est" => "Estonian", "eus" => "Basque", "fao" => "Faroese", "fas" => "Persian",
    "fij" => "Fijian", "fin" => "Finnish", "fra" => "French", "fry" => "Frisian",
    "gla" => "Scots Gaelic", "gle" => "Irish", "glg" => "Galician", "glv" => "Manx",
    "grn" => "Guarani", "guj" => "Gujarati", "hat" => "Haitian Creole", "hau" => "Hausa",
    "haw" => "Hawaiian", "heb" => "Hebrew", "hin" => "Hindi", "hmn" => "Hmong",
    "hrv" => "Croatian", "hun" => "Hungarian", "hye" => "Armenian", "ibo" => "Igbo",
    "iku" => "Inuktitut", "ile" => "Interlingue", "ina" => "Interlingua", "ind" => "Indonesian",
    "ipk" => "Inupiak", "isl" => "Icelandic", "ita" => "Italian", "jav" => "Javanese",
    "jpn" => "Japanese", "kal" => "Greenlandic", "kan" => "Kannada", "kas" => "Kashmiri",
    "kat" => "Georgian", "kaz" => "Kazakh", "kha" => "Khasi", "khm" => "Khmer",
    "kin" => "Kinyarwanda", "kir" => "Kyrgyz", "kor" => "Korean", "kur" => "Kurdish",
    "lao" => "Lao", "lat" => "Latin", "lav" => "Latvian", "lif" => "Limbu",
    "lin" => "Lingala", "lit" => "Lithuanian", "ltz" => "Luxembourgish", "lug" => "Ganda",
    "mal" => "Malayalam", "mar" => "Marathi", "mfe" => "Mauritian Creole", "mkd" => "Macedonian",
    "mlg" => "Malagasy", "mlt" => "Maltese", "mon" => "Mongolian", "mri" => "Maori",
    "msa" => "Malay", "mya" => "Burmese", "nau" => "Nauru", "nep" => "Nepali",
    "nld" => "Dutch", "nno" => "Norwegian Nynorsk", "nor" => "Norwegian", "nso" => "Northern Sotho",
    "nya" => "Nyanja", "oci" => "Occitan", "ori" => "Odia", "orm" => "Oromo",
    "pan" => "Punjabi", "pol" => "Polish", "por" => "Portuguese", "pus" => "Pashto",
    "que" => "Quechua", "roh" => "Romansh", "ron" => "Romanian", "run" => "Rundi",
    "rus" => "Russian", "sag" => "Sango", "san" => "Sanskrit", "sco" => "Scots",
    "sin" => "Sinhala", "slk" => "Slovak", "slv" => "Slovenian", "smo" => "Samoan",
    "sna" => "Shona", "snd" => "Sindhi", "som" => "Somali", "sot" => "Sesotho",
    "spa" => "Spanish", "sqi" => "Albanian", "srp" => "Serbian", "ssw" => "Swati",
    "sun" => "Sundanese", "swa" => "Swahili", "swe" => "Swedish", "syr" => "Syriac",
    "tam" => "Tamil", "tat" => "Tatar", "tel" => "Telugu", "tgk" => "Tajik",
    "tgl" => "Tagalog", "tha" => "Thai", "tir" => "Tigrinya", "ton" => "Tonga",
    "tsn" => "Tswana", "tso" => "Tsonga", "tuk" => "Turkmen", "tur" => "Turkish",
    "uig" => "Uighur", "ukr" => "Ukrainian", "urd" => "Urdu", "uzb" => "Uzbek",
    "ven" => "Venda", "vie" => "Vietnamese", "vol" => "Volapuk", "war" => "Waray",
    "wol" => "Wolof", "xho" => "Xhosa", "yid" => "Yiddish", "yor" => "Yoruba",
    "zha" => "Zhuang", "zho" => "Chinese", "zul" => "Zulu",
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

