using Dates, Logging, MonsieurPapin

config() = MonsieurPapin.Configuration(
    query = "live casino poker slot togel taruhan online",
    threshold = 0.88,
    capacity = 10,
    model = "qwen/qwen3.5-9b",
    systemprompt = "Always output markdown. Never output blank. Echo the LOCAL_TIME value exactly as Local-Time. Echo the URI value exactly as URI. For every excerpt, write exactly this template:\n## Candidate\nLocal-Time: <LOCAL_TIME>\nURI: <URI>\nDecision: KEEP or SKIP\nLabel: Gambling or Marketing or Directory or Other\nSummary: at most twelve words.",
    input = "Classify whether this excerpt is a gambling page, a marketing page, a directory page, or other. Always return the template.",
    outputpath = "tmp/research.md",
)

function MonsieurPapin.prompt(wet::MonsieurPapin.WET, config::MonsieurPapin.Configuration)
    localtime = Dates.format(now(), dateformat"yyyy-mm-dd HH:MM:SS")
    string("LOCAL_TIME: ", localtime, "\nURI: ", MonsieurPapin.uri(wet), "\nSCORE: ", wet.score, "\n\n", MonsieurPapin.content(wet))
end

function prepare(path)
    open(path, "w") do file end
    path
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
    entries = MonsieurPapin.wets("data/warc.wet.gz"; capacity = client.capacity)
    filtered = MonsieurPapin.coarsefilter(client, entries)
    wait(MonsieurPapin.queue(client, filtered))
    finished = now()
    summarize(client.outputpath, started, finished)
    @info "Report generation finished" outputpath = client.outputpath processend = finished
end

@time run()
