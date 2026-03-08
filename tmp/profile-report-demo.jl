using Dates, Logging, MonsieurPapin

Base.@kwdef mutable struct Report
    candidates::Int = 0
    attempts::Int = 0
    messages::Int = 0
    blanks::Int = 0
    errors::Int = 0
end

config() = MonsieurPapin.Configuration(
    query = "network marketing bisnis online investasi",
    threshold = 0.82,
    capacity = 3,
    previewlength = 300,
    model = "qwen/qwen3.5-9b",
    systemprompt = "Always output markdown. Never output blank. Echo the LOCAL_TIME value exactly as Local-Time. Echo the URI value exactly as URI. For every excerpt, write exactly this template:\n## Candidate\nLocal-Time: <LOCAL_TIME>\nURI: <URI>\nDecision: KEEP or SKIP\nLabel: Gambling or Marketing or Directory or Other\nSummary: at most twelve words.",
    input = "Classify whether this excerpt is a gambling page, a marketing page, a directory page, or other. Always return the template.",
    outputpath = "tmp/research.md",
    timeoutseconds = 1200,
)

function MonsieurPapin.prompt(pages::MonsieurPapin.Wets, wet::MonsieurPapin.WET, config::MonsieurPapin.Configuration)
    bytes = MonsieurPapin.content(pages, wet)
    stop = min(lastindex(bytes), config.previewlength)
    text = String(@view bytes[firstindex(bytes):stop])
    localtime = Dates.format(now(), dateformat"yyyy-mm-dd HH:MM:SS")
    string("LOCAL_TIME: ", localtime, "\nURI: ", String(MonsieurPapin.uri(pages, wet)), "\nSCORE: ", wet.score, "\n\n", text)
end

function prepare(path)
    open(path, "w") do file end
    path
end

function report!(file, pages, wet, config, report)
    report.candidates += 1
    report.attempts += 1
    try
        output = MonsieurPapin.complete(MonsieurPapin.prompt(pages, wet, config), config)
        if isempty(output)
            report.blanks += 1
            @info "LLM returned no final message" candidate = report.candidates uri = String(MonsieurPapin.uri(pages, wet))
        else
            report.messages += 1
            MonsieurPapin.append!(file, output)
            @info "LLM returned final message" candidate = report.candidates uri = String(MonsieurPapin.uri(pages, wet))
        end
    catch error
        report.errors += 1
        @info "LLM request failed" candidate = report.candidates uri = String(MonsieurPapin.uri(pages, wet)) error = sprint(showerror, error)
    end
end

function report(config)
    pages = MonsieurPapin.wets("data/warc.wet.gz"; capacity = config.capacity)
    filtered = MonsieurPapin.coarsefilter(config, pages)
    summary = Report()
    open(config.outputpath, "a") do file
        foreach(wet -> report!(file, filtered, wet, config, summary), Iterators.take(filtered, 3))
    end
    summary
end

stamp(text) = DateTime(match(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", text).match, dateformat"yyyy-mm-dd HH:MM:SS")
stamps(text) = stamp.([entry.match for entry in eachmatch(r"Local-Time:\s*\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", text)])

function summarize(path, started, finished)
    text = read(path, String)
    entries = stamps(text)
    isempty(entries) && return @info "Timing summary" processstart = started firstllm = nothing lastllm = nothing processend = finished startupdelay = nothing llmwindow = nothing total = finished - started
    firstentry = first(entries)
    lastentry = last(entries)
    @info "Timing summary" processstart = started firstllm = firstentry lastllm = lastentry processend = finished startupdelay = firstentry - started llmwindow = lastentry - firstentry total = finished - started
end

function run()
    client = config()
    prepare(client.outputpath)
    started = now()
    @info "Starting report generation" query = client.query outputpath = client.outputpath processstart = started
    summary = report(client)
    finished = now()
    summarize(client.outputpath, started, finished)
    @info "LLM summary" candidates = summary.candidates attempts = summary.attempts messages = summary.messages blanks = summary.blanks errors = summary.errors
    @info "Report generation finished" outputpath = client.outputpath processend = finished
end

run()
