abstract type LLMBackend end

struct OpenAIEndpoint <: LLMBackend
    settings::AbstractDict
end

mutable struct PiWorker
    process::Base.Process
    lock::ReentrantLock
end

mutable struct PiRPC <: LLMBackend
    workers::Vector{PiWorker}
    settings::AbstractDict
    nextworker::Threads.Atomic{Int}
end

llm(settings::AbstractDict) = llm(Val(Symbol(settings["provider"])), settings)
llm(::Val{:local}, settings::AbstractDict) = OpenAIEndpoint(settings)
llm(::Val{Symbol("openai-codex")}, settings::AbstractDict) = PiRPC(settings)

function PiRPC(settings::AbstractDict)
    command = vcat(settings["command"], ["--provider", settings["provider"], "--model", settings["model"]])
    workers = [PiWorker(open(Cmd(String.(command)), "r+"), ReentrantLock()) for _ in 1:settings["parallel"]]
    PiRPC(workers, settings, Threads.Atomic{Int}(0))
end

Base.close(::OpenAIEndpoint) = nothing
function Base.close(worker::PiWorker)
    close(worker.process.in)
    isopen(worker.process.out) && read(worker.process.out, String)
    wait(worker.process, false)
    isopen(worker.process.out) && close(worker.process.out)
end
Base.close(client::PiRPC) = foreach(close, client.workers)

mutable struct CodexAppServer
    io::IO
    lock::ReentrantLock
    nextid::Threads.Atomic{Int}
    timeout::Real
end

function CodexAppServer(settings::AbstractDict, timeout::Real)
    io = open(Cmd(String.(settings["command"])), "r+")
    server = CodexAppServer(io, ReentrantLock(), Threads.Atomic{Int}(0), timeout)
    rpc(server, settings["initialize_method"], settings["initialize_params"])
    println(io, JSON.json(Dict("method" => settings["initialized_method"])))
    flush(io)
    server
end

CodexAppServer(settings::AbstractDict) = CodexAppServer(settings, settings["timeout"])

function timedreadline(io::IO, timeout::Real)
    task = Threads.@spawn readline(io)
    Base.timedwait(() -> istaskdone(task), timeout) == :timed_out && begin
        close(io)
        error("Timed out waiting $(timeout) seconds for Pi app-server response")
    end
    fetch(task)
end

function rpc(server::CodexAppServer, method::String, params)
    id = Threads.atomic_add!(server.nextid, 1) + 1
    lock(server.lock) do
        println(server.io, JSON.json(Dict("id" => id, "method" => method, "params" => params)))
        flush(server.io)
        while true
            response = JSON.parse(timedreadline(server.io, server.timeout))
            ("id" in keys(response)) || continue
            response["id"] == id || continue
            ("error" in keys(response)) && error(string("Pi app-server RPC error for ", method, ": ", JSON.json(response["error"])))
            return response["result"]
        end
    end
end

usage(server::CodexAppServer, settings::AbstractDict) = rpc(server, settings["method"], settings["params"])
Base.close(server::CodexAppServer) = close(server.io)

struct NoUsage end

mutable struct UsageMonitor
    server::CodexAppServer
    settings::AbstractDict
    limitname::String
    calls::Threads.Atomic{Int}
    attempts::Threads.Atomic{Int}
    stopped::Threads.Atomic{Bool}
    baseline::Dict{String,Float64}
    lastsample::Dict{String,Float64}
    lastattempts::Int
    estimate::Any
    usage::Dict{String,Any}
    lock::ReentrantLock
    lastsnapshot::Any
    task::Task
end

function usagewindows(snapshot, limitname::String)
    limits = snapshot["rateLimitsByLimitId"]
    limit = first(filter(entry -> entry[2]["limitName"] == limitname, limits))[2]
    windows = (("primary", limit["primary"]), ("secondary", limit["secondary"]))
    filter(window -> window[2] !== nothing, windows)
end

function usagebaseline(snapshot, limitname::String)
    Dict(name => Float64(window["usedPercent"]) for (name, window) in usagewindows(snapshot, limitname))
end

function overlimit(monitor::UsageMonitor, snapshot)
    any(window -> Float64(window[2]["usedPercent"]) - monitor.baseline[window[1]] >= monitor.settings["drop"], usagewindows(snapshot, monitor.limitname))
end

function logusage(monitor::UsageMonitor, snapshot)
    windows = [Dict(
        "name" => name,
        "usedPercent" => window["usedPercent"],
        "remainingPercent" => 100 - window["usedPercent"],
        "windowDurationMins" => window["windowDurationMins"],
        "resetsAt" => window["resetsAt"],
    ) for (name, window) in usagewindows(snapshot, monitor.limitname)]
    observedusage = lock(monitor.lock) do
        deepcopy(monitor.usage)
    end
    entry = Dict(
        "timestamp" => string(Dates.now()),
        "calls" => monitor.calls[],
        "attempts" => monitor.attempts[],
        "usage" => observedusage,
        "callsPerPercentagePoint" => monitor.estimate,
        "limitName" => monitor.limitname,
        "windows" => windows,
    )
    open(monitor.settings["log"], "a") do file
        println(file, JSON.json(entry))
    end
    nothing
end

function UsageMonitor(settings::AbstractDict, timeout::Real)
    server = CodexAppServer(settings, timeout)
    snapshot = usage(server, settings)
    baseline = usagebaseline(snapshot, settings["limit_name"])
    monitor = UsageMonitor(server, settings, settings["limit_name"], Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), Threads.Atomic{Bool}(false), baseline, baseline, 0, nothing, Dict{String,Any}(), ReentrantLock(), snapshot, Task(() -> nothing))
    logusage(monitor, snapshot)
    monitor.task = Threads.@spawn begin
        while !monitor.stopped[]
            sleep(settings["interval"])
            snapshot = usage(server, settings)
            monitor.lastsnapshot = snapshot
            current = usagebaseline(snapshot, settings["limit_name"])
            delta = sum(values(current)) - sum(values(monitor.lastsample))
            delta > 0 && (monitor.estimate = (monitor.attempts[] - monitor.lastattempts) / delta)
            monitor.lastsample = current
            monitor.lastattempts = monitor.attempts[]
            logusage(monitor, snapshot)
            overlimit(monitor, snapshot) && (monitor.stopped[] = true)
        end
    end
    monitor
end

UsageMonitor(settings::AbstractDict) = UsageMonitor(settings, settings["timeout"])

monitor(settings::AbstractDict) = monitor(Val(Symbol(settings["provider"])), settings)
monitor(::Val{:local}, settings::AbstractDict) = NoUsage()
monitor(::Val{Symbol("openai-codex")}, settings::AbstractDict) = UsageMonitor(settings["usage"], settings["timeout"])

admit(::NoUsage) = true
admit(monitor::UsageMonitor) = !monitor.stopped[]
attempt!(::NoUsage) = nothing
function attempt!(monitor::UsageMonitor)
    Threads.atomic_add!(monitor.calls, 1)
    Threads.atomic_add!(monitor.attempts, 1)
end
record!(::NoUsage, response) = nothing

function aggregateusage!(aggregate::AbstractDict, observed::AbstractDict)
    for (key, value) in observed
        if value isa AbstractDict
            key in keys(aggregate) ? aggregateusage!(aggregate[key], value) : (aggregate[key] = deepcopy(value))
        elseif value isa Number
            key in keys(aggregate) ? (aggregate[key] += value) : (aggregate[key] = value)
        else
            aggregate[key] = value
        end
    end
    aggregate
end

function record!(monitor::UsageMonitor, response)
    lock(monitor.lock) do
        aggregateusage!(monitor.usage, response["usage"])
    end
    nothing
end

Base.close(::NoUsage) = nothing
function Base.close(monitor::UsageMonitor)
    monitor.stopped[] = true
    wait(monitor.task)
    logusage(monitor, monitor.lastsnapshot)
    close(monitor.server)
end

function request(; model::String, systemprompt::String, input::String,
                  baseurl::String, path::String, password::String,
                  timeout::Int, responseformat=nothing, maxtokens=nothing, temperature=nothing,
                  thinking::Bool)
    body = Dict(
        "model" => model,
        "messages" => [
            Dict("role" => "system", "content" => systemprompt),
            Dict("role" => "user", "content" => input),
        ],
    )
    isnothing(responseformat) || (body["response_format"] = responseformat)
    isnothing(maxtokens) || (body["max_tokens"] = maxtokens)
    isnothing(temperature) || (body["temperature"] = temperature)
    thinking || (body["chat_template_kwargs"] = Dict("enable_thinking" => false); body["enable_thinking"] = false)
    headers = ["Content-Type" => "application/json", "Authorization" => "Bearer $(password)"]
    response = HTTP.post(string(baseurl, path); headers=headers, body=JSON.json(body), readtimeout=timeout, retry=false)
    JSON.parse(String(response.body))
end

request(client::OpenAIEndpoint, systemprompt::String, input::String) = request(;
    model=client.settings["model"], systemprompt, input,
    baseurl=client.settings["baseurl"], path=client.settings["path"], password=client.settings["password"],
    timeout=client.settings["timeout"], thinking=client.settings["thinking"])

function pitranscript(content)
    content isa AbstractString && return content
    join(block["text"] for block in content if block["type"] == "text")
end

function request(client::PiRPC, systemprompt::String, input::String)
    worker = client.workers[mod1(Threads.atomic_add!(client.nextworker, 1) + 1, length(client.workers))]
    lock(worker.lock) do
        id = string(time_ns())
        println(worker.process, JSON.json(Dict("id" => id, "type" => "prompt", "message" => string(systemprompt, "\n\n", input))))
        flush(worker.process)
        answer = Ref{String}()
        usage = Ref{Any}()
        while true
            event = JSON.parse(timedreadline(worker.process, client.settings["timeout"]))
            event["type"] == "error" && error(string("Pi RPC error: ", JSON.json(event)))
            event["type"] == "response" && !event["success"] && error(string("Pi RPC command error: ", JSON.json(event)))
            ("error" in keys(event)) && error(string("Pi RPC error: ", JSON.json(event)))
            event["type"] == "message_end" && event["message"]["role"] == "assistant" &&
                event["message"]["stopReason"] == "error" && error(string("Pi assistant error: ", JSON.json(event["message"])))
            event["type"] == "message_end" && event["message"]["role"] == "assistant" &&
                (answer[] = pitranscript(event["message"]["content"]); usage[] = event["message"]["usage"])
            event["type"] == "agent_settled" && return Dict(
                "choices" => [Dict("message" => Dict("content" => answer[]))],
                "usage" => usage[],
            )
        end
    end
end

message(data) = data["choices"][1]["message"]["content"]

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
targetlanguages(codes) = join((languagenames[c] for c in codes), ", ")

function extractkeywords(client::LLMBackend, prompts::AbstractDict, text;
                          limitinput, timeout, langs, monitor)
    admit(monitor) || error("LLM call rejected by usage monitor")
    attempt!(monitor)
    languages = targetlanguages(langs)
    response = request(client, prompts["keywords_system"], string("Target languages: ", languages, "\n\nText:\n", first(text, limitinput)))
    record!(monitor, response)
    JSON.parse(message(response))["keywords"]
end

function summarize(client::LLMBackend, prompts::AbstractDict, text; limit)
    response = request(client, prompts["summary_system"], string("Summarize in at most ", limit, " characters:\n\n", text))
    message(response)
end
