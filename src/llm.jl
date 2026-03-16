url(config::Configuration) = string(config.baseurl, config.path)

headers(config::Configuration) =
    isempty(config.password) ?
    ["Content-Type" => "application/json"] :
    ["Content-Type" => "application/json", "Authorization" => "Bearer $(config.password)"]

# Updated to match the specific API format provided: model, system_prompt, input
request(config::Configuration, page::AbstractString) = Dict(
    "model" => config.model,
    "system_prompt" => config.systemprompt,
    "input" => string(config.input, "\n\n", page)
)

function translate(text::AbstractString, language::AbstractString, config::Configuration)
    translation = deepcopy(config)
    translation.systemprompt = "You translate text accurately. Output only the translation."
    translation.input = string("Translate the following text into the language identified by the Common Crawl WET language code ", language, ". Output only the translated text.")
    complete(text, translation)
end

translate(text::AbstractString, language::AbstractString) = translate(text, language, Configuration())

function translate(lines::AbstractVector{<:AbstractString}, language::AbstractString, config::Configuration)
    translation = deepcopy(config)
    translation.systemprompt = "You translate text accurately. Preserve line order. Output only the translated lines."
    translation.input = string("Translate each line into the language identified by the Common Crawl WET language code ", language, ". Preserve line order and output only the translated lines.")
    strip.(split(chomp(complete(join(lines, "\n"), translation)), '\n'))
end

translate(lines::AbstractVector{<:AbstractString}, language::AbstractString) = translate(lines, language, Configuration())

function translate(lines::AbstractVector{<:AbstractString}, languages::AbstractVector{<:AbstractString}, config::Configuration)
    isempty(languages) && return collect(lines)
    unique(vcat(collect(lines), mapreduce(language -> translate(lines, language, config), vcat, languages; init=String[])))
end

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
    body_str = String(response.body)
    
    # Parse the server response (which is JSON)
    data = JSON.parse(body_str)
    
    # Extract the actual text content from the response structure
    text_content = extract_content(data)
    
    # Return the clean text
    return text_content
end
