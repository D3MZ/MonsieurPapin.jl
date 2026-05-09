url(config::Configuration) = string(config.baseurl, config.path)

headers(config::Configuration) =
    isempty(config.password) ?
    ["Content-Type" => "application/json"] :
    ["Content-Type" => "application/json", "Authorization" => "Bearer $(config.password)"]

# Updated to match the specific API format provided: model, system_prompt, input
request(config::Configuration, page::AbstractString) = Dict(
    "model" => config.model,
    "reasoning" => "off",
    "system_prompt" => config.systemprompt,
    "input" => string(config.input, "\n\n", page),
)

function translate(text::AbstractString, language::AbstractString, config::Configuration)
    translation = deepcopy(config)
    translation.systemprompt = "You translate text accurately. Output only the translation."
    translation.input = string("Translate the following text into the language identified by the Common Crawl WET language code ", language, ". Output only the translated text.")
    complete(text, translation)
end

translate(text::AbstractString, language::AbstractString) = translate(text, language, Configuration())

# Deeply extract content from various response structures
function extract_content(data)
    # 1. If it's a message array, look for the first message type
    if data isa AbstractVector
        for item in data
            res = extract_content(item)
            !isempty(res) && return res
        end
    # 2. If it's a dict, look for content, text, or message fields
    elseif data isa AbstractDict
        if get(data, "type", "") == "message"
            return get(data, "content", "")
        elseif haskey(data, "content")
            return extract_content(data["content"])
        elseif haskey(data, "output")
            return extract_content(data["output"])
        elseif haskey(data, "text")
            return extract_content(data["text"])
        elseif haskey(data, "choices")
            return extract_content(data["choices"])
        elseif haskey(data, "message")
            return extract_content(data["message"])
        end
    # 3. If it's already a string, we are done
    elseif data isa AbstractString
        return data
    end
    return ""
end

function stripjson(text::AbstractString)
    # Aggressively extract the largest valid-looking JSON object {...}
    first_brace = findfirst('{', text)
    last_brace = findlast('}', text)
    
    if !isnothing(first_brace) && !isnothing(last_brace)
        return text[first_brace:last_brace]
    end
    
    return text
end

function complete(page::AbstractString, config::Configuration)
    response = HTTP.post(url(config); headers=headers(config), body=JSON.json(request(config, page)), readtimeout=config.timeoutseconds)
    data = JSON.parse(String(response.body))
    text = extract_content(data)
    isempty(text) && return ""
    
    # Try structured JSON, fall back to raw text
    result = try JSON.parse(stripjson(text)) catch; nothing end
    if result isa AbstractDict && get(result, "skip", false) == true
        return ""
    elseif result isa AbstractDict
        name = get(result, "name", "")
        code = get(result, "code", "")
        if !isempty(name) || !isempty(code)
            source = get(result, "source", "")
            desc = get(result, "description", "")
            return "## $(name)\n**Source:** $(source)\n\n$(desc)\n\n\`\`\`\n$(code)\n\`\`\`\n"
        end
    end
    
    return text
end
