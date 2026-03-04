abstract type AbstractLLM end

struct LLM <: AbstractLLM
    baseurl::String
    path::String
    model::String
    password::String
    systemprompt::String
    input::String
    timeoutseconds::Int
end

LLM(;
    baseurl="http://localhost:1234",
    path="/api/v1/chat",
    model="qwen/qwen3.5-35b-a3b",
    password="",
    systemprompt="If a trading strategy exists then write a small description about it and the trading strategy as pseudo code wrapped in a code fence, otherwise do not output anything.",
    input="Evaluate this page excerpt for trading strategy relevance and follow the output rule.",
    timeoutseconds=120,
) = LLM(baseurl, path, model, password, systemprompt, input, timeoutseconds)

url(llm::LLM) = string(llm.baseurl, llm.path)

headers(llm::LLM) =
    isempty(llm.password) ?
    ["Content-Type" => "application/json"] :
    ["Content-Type" => "application/json", "Authorization" => "Bearer $(llm.password)"]

request(llm::LLM, page::AbstractString) = Dict(
    "model" => llm.model,
    "messages" => [
        Dict("role" => "system", "content" => llm.systemprompt),
        Dict("role" => "user", "content" => string(llm.input, "\n\n", page)),
    ],
)

function complete(page::AbstractString, llm::LLM)
    response = HTTP.post(url(llm); headers=headers(llm), body=JSON.json(request(llm, page)), readtimeout=llm.timeoutseconds)
    data = JSON.parse(String(response.body))
    data["choices"][1]["message"]["content"]
end

