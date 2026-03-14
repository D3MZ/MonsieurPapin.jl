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

# Flexible parsing for different local LLM server responses
function result(data)
    # Handle the specific case of Any[...] string representation
    if data isa AbstractString
        # Use stripjson to find the real JSON inside
        clean = stripjson(data)
        try
            # If it's a stringified Dict/Array from Julia, it might fail standard JSON parse
            # But let's try
            return clean
        catch
            return data
        end
    end

    # Handle array of objects
    if data isa AbstractVector
        for item in data
            if item isa AbstractDict
                if get(item, "type", "") == "message"
                    return get(item, "content", "")
                end
            end
        end
        if !isempty(data)
            it = first(data)
            return it isa AbstractDict ? get(it, "content", get(it, "text", string(it))) : string(it)
        end
    end

    # Handle standard dictionary responses
    if data isa AbstractDict
        if haskey(data, "output")
            return data["output"]
        elseif haskey(data, "text")
            return data["text"]
        elseif haskey(data, "choices") && !isempty(data["choices"])
            choice = first(data["choices"])
            if choice isa AbstractDict
                if haskey(choice, "message")
                    msg = choice["message"]
                    return msg isa AbstractDict ? get(msg, "content", "") : string(msg)
                elseif haskey(choice, "text")
                    return choice["text"]
                end
            end
        end
    end

    return string(data)
end

function stripjson(text::AbstractString)
    # 1. Pre-clean: if it's a stringified Julia Object, it might have "content" => "..."
    # We look for the "content" key and capture its value accurately.
    # We look for the message content specifically.
    m_content = match(r"\"content\"\s*=>\s*\"(.*?)(?<!\\)\""s, text)
    if !isnothing(m_content)
        content = m_content.captures[1]
        unescaped = unescape_string(content)
        # If the unescaped content is a JSON object, strip it recursively
        if contains(unescaped, "{") && contains(unescaped, "}")
            return stripjson(unescaped)
        end
        return unescaped
    end

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
    
    # If the body is a direct JSON string from the server
    data = try
        JSON.parse(body_str)
    catch
        # If not, it's mixed chatter
        body_str
    end
    
    res = result(data)
    
    # If the result is a string containing JSON, strip it
    if res isa AbstractString && contains(res, "{") && contains(res, "}")
        return stripjson(res)
    end
    
    return string(res)
end
