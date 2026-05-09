function request(; model::String, systemprompt::String, input::String,
                  baseurl::String, path::String, password::String="",
                  timeout::Int=120)
    body = Dict(
        "model" => model,
        "reasoning" => "off",
        "system_prompt" => systemprompt,
        "input" => input,
    )
    headers = ["Content-Type" => "application/json", "Authorization" => "Bearer $(password)"]
    response = HTTP.post(string(baseurl, path); headers=headers, body=JSON.json(body), readtimeout=timeout)
    return JSON.parse(String(response.body))
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


