using HTTP, CodecZlib, ProgressMeter, Dates, Logging, BufferedStreams, DataStructures
using JSON: parsefile, parse

crawlpath = "https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
crawlroot = "https://data.commoncrawl.org/"
previewseconds = 8.0
query = "trading strategies"
openaicompatiblepath = "openai-compatible.json"

struct PathFeed end
struct PageFeed end
struct ReadyDrain end
struct BlockingDrain end

Candidate = NamedTuple{(:score, :page, :file, :snippet), Tuple{Float64, Int, Int, String}}
LlmResult = NamedTuple{(:candidate, :text), Tuple{Candidate, String}}
ScoredPage = NamedTuple{(:page, :file, :score, :bytes, :count), Tuple{Int, Int, Float64, Vector{UInt8}, Int}}

remaining(started, limit) = limit - (time() - started)

function budget!(meter, started, limit, halted)
    halted[] && return false
    ProgressMeter.update!(meter, remaining(started, limit); increment = false)
    if meter.triggered
        halted[] = true
        return false
    end
    true
end

function source(consume, url)
    HTTP.open("GET", url) do stream
        HTTP.startread(stream)
        stream.message.status == 200 || error("source failed status=$(stream.message.status) url=$(url)")
        consume(stream)
    end
end

decoded(response) = GzipDecompressorStream(BufferedInputStream(response))

function equals(data, start, stop, text)
    stop - start + 1 == ncodeunits(text) || return false
    for (offset, byte) in enumerate(codeunits(text))
        data[start + offset - 1] == byte || return false
    end
    true
end

function starts(data, start, stop, text)
    stop - start + 1 >= ncodeunits(text) || return false
    for (offset, byte) in enumerate(codeunits(text))
        data[start + offset - 1] == byte || return false
    end
    true
end

function value(data, start, stop, prefix)
    starts(data, start, stop, prefix) || return 0
    index = start + ncodeunits(prefix)
    while index <= stop && (data[index] == UInt8(' ') || data[index] == UInt8('\t'))
        index += 1
    end
    parsed = 0
    while index <= stop
        byte = data[index]
        UInt8('0') <= byte <= UInt8('9') || break
        parsed = parsed * 10 + (byte - UInt8('0'))
        index += 1
    end
    parsed
end

function conversion(data, start, stop)
    starts(data, start, stop, "WARC-Type:") || return false
    index = start + ncodeunits("WARC-Type:")
    while index <= stop && (data[index] == UInt8(' ') || data[index] == UInt8('\t'))
        index += 1
    end
    equals(data, index, stop, "conversion")
end

function header(info, buffer)
    size = position(buffer)
    size == 0 && return nothing
    data = buffer.data
    warc = false
    kind = false
    bytes = 0
    index = 1

    while index <= size
        lineend = index
        while lineend <= size && data[lineend] != UInt8('\n')
            lineend += 1
        end
        stop = lineend - 1
        stop >= index && data[stop] == UInt8('\r') && (stop -= 1)
        if stop >= index
            warc = warc || equals(data, index, stop, "WARC/1.0")
            kind = kind || conversion(data, index, stop)
            bytes = bytes > 0 ? bytes : value(data, index, stop, "Content-Length:")
        end
        index = lineend + 1
    end

    warc || return nothing
    info[] = (kind = kind, bytes = bytes)
    info[]
end

function record(info, source, meter, started, limit, headerbuffer, halted)
    while !eof(source)
        budget!(meter, started, limit, halted) || return nothing
        truncate(headerbuffer, 0)
        seekstart(headerbuffer)
        try
            copyuntil(headerbuffer, source, "\r\n\r\n"; keep = false)
        catch error
            error isa EOFError && return nothing
            rethrow(error)
        end
        entry = header(info, headerbuffer)
        isnothing(entry) && continue
        return entry
    end
    nothing
end

function capture!(source, bytes, scratch, meter, started, limit, halted, page, window)
    copied = 0
    remaining = bytes
    while remaining > 0
        budget!(meter, started, limit, halted) || break
        chunk = min(remaining, length(scratch))
        count = readbytes!(source, scratch, chunk)
        count == 0 && break
        if copied < window
            kept = min(window - copied, count)
            copyto!(page, copied + 1, scratch, 1, kept)
            copied += kept
        end
        remaining -= count
    end
    copied
end

function skip!(source, bytes, scratch, meter, started, limit, halted)
    remaining = bytes
    while remaining > 0
        budget!(meter, started, limit, halted) || break
        chunk = min(remaining, length(scratch))
        count = readbytes!(source, scratch, chunk)
        count == 0 && break
        remaining -= count
    end
    nothing
end

function feed(consume, ::PathFeed, source::IO, meter, started, limit, halted)
    for path in eachline(source)
        budget!(meter, started, limit, halted) || break
        consume(path)
    end
end

function feed(consume, feedkind::PathFeed, url, meter, started, limit, halted)
    source(url) do response
        feed(consume, feedkind, decoded(response), meter, started, limit, halted)
    end
end

function feed(consume, ::PageFeed, source::IO, meter, started, limit, halted, pool, window, pages, files)
    headerstorage = Vector{UInt8}(undef, 64 * 1024)
    headerbuffer = IOBuffer(headerstorage; read = true, write = true, truncate = true, maxsize = length(headerstorage))
    info = Ref((kind = false, bytes = 0))
    while true
        budget!(meter, started, limit, halted) || break
        item = record(info, source, meter, started, limit, headerbuffer, halted)
        halted[] && break
        isnothing(item) && break
        if item.kind
            buffer = take!(pool)
            used = capture!(source, item.bytes, headerstorage, meter, started, limit, halted, buffer, window)
            pages[] += 1
            consume((page = pages[], bytes = buffer, count = used, file = files[]))
        else
            skip!(source, item.bytes, headerstorage, meter, started, limit, halted)
        end
    end
end

function feed(consume, feedkind::PageFeed, url, meter, started, limit, halted, pool, window, pages, files)
    source(url) do response
        feed(consume, feedkind, decoded(response), meter, started, limit, halted, pool, window, pages, files)
    end
end

letter(byte) = UInt8('A') <= byte <= UInt8('Z') ? byte + UInt8(32) : byte
token(byte) = (UInt8('a') <= byte <= UInt8('z')) || (UInt8('A') <= byte <= UInt8('Z'))

function equalword(word, size, target)
    size == length(target) || return false
    for index in eachindex(target)
        word[index] == target[index] || return false
    end
    true
end

function word!(word, size, counts, targets)
    size == 0 && return 0
    if equalword(word, size, first(targets))
        counts[firstindex(counts)] += 1
    elseif equalword(word, size, last(targets))
        counts[lastindex(counts)] += 1
    end
    0
end

function tokenize!(word, size, counts, targets, data, count)
    for index in Base.OneTo(count)
        byte = data[index]
        if token(byte)
            if size < length(word)
                size += 1
                word[size] = letter(byte)
            end
        else
            size = word!(word, size, counts, targets)
        end
    end
    size
end

function distance(counts)
    firstcount = counts[firstindex(counts)]
    lastcount = counts[lastindex(counts)]
    dot = firstcount + lastcount
    norm = sqrt(firstcount * firstcount + lastcount * lastcount)
    1.0 - (dot / (sqrt(2.0) * (norm + eps())))
end

function score(page, word, counts, targets)
    fill!(counts, 0)
    size = tokenize!(word, 0, counts, targets, page.bytes, page.count)
    word!(word, size, counts, targets)
    (page = page.page, file = page.file, score = distance(counts), bytes = page.bytes, count = page.count)
end

function produce!(pageschannel, crawlpath, crawlroot, meter, started, limit, halted, pool, window, pages, files)
    try
        pagebatch = NamedTuple{(:page, :bytes, :count, :file), Tuple{Int, Vector{UInt8}, Int, Int}}[]
        batchsize = 64
        feed(PathFeed(), crawlpath, meter, started, limit, halted) do path
            files[] += 1
            feed(PageFeed(), crawlroot * path, meter, started, limit, halted, pool, window, pages, files) do page
                push!(pagebatch, page)
                if length(pagebatch) >= batchsize
                    put!(pageschannel, pagebatch)
                    pagebatch = NamedTuple{(:page, :bytes, :count, :file), Tuple{Int, Vector{UInt8}, Int, Int}}[]
                end
            end
        end
        isempty(pagebatch) || put!(pageschannel, pagebatch)
    finally
        isopen(pageschannel) && close(pageschannel)
    end
end

function score!(scoreschannel, pageschannel, targets)
    word = Vector{UInt8}(undef, 64)
    counts = zeros(Int, 2)
    for batch in pageschannel
        scored = ScoredPage[]
        sizehint!(scored, length(batch))
        for page in batch
            result = score(page, word, counts, targets)
            push!(scored, result)
        end
        put!(scoreschannel, scored)
    end
end

function snippet(bytes, count)
    sample = Vector{UInt8}(undef, min(count, 512))
    for index in eachindex(sample)
        byte = bytes[index]
        sample[index] = (UInt8(' ') <= byte <= UInt8('~')) ? byte : UInt8(' ')
    end
    String(sample)
end

function candidate(item::ScoredPage)
    (score = item.score, page = item.page, file = item.file, snippet = snippet(item.bytes, item.count))
end

function queue!(frontier, item::Candidate, limit)
    if length(frontier) < limit
        push!(frontier, item)
        return true
    end
    item.score < maximum(frontier).score || return false
    popmax!(frontier)
    push!(frontier, item)
    true
end

function configured(path)
    configuration = parsefile(path)
    (baseurl = configuration["base_url"],
     path = configuration["path"],
     model = configuration["model"],
     password = configuration["password"],
     systemprompt = configuration["system_prompt"],
     input = configuration["input"],
     outputpath = configuration["output_path"],
     maxpages = configuration["max_pages"],
     timeoutseconds = configuration["timeout_seconds"])
end

function escaped(text)
    replace(text, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t")
end

function visible(text)
    clean = replace(text, r"(?s)<think>.*?</think>" => "")
    clean = replace(clean, r"(?s)<thinking>.*?</thinking>" => "")
    strip(clean)
end

function endpoint(settings)
    startswith(settings.path, "/") ? settings.baseurl * settings.path : settings.baseurl * "/" * settings.path
end

function payload(settings, item::Candidate)
    input = settings.input * "\n\npage=$(item.page) file=$(item.file) score=$(item.score)\n" * item.snippet
    "{\"model\":\"$(escaped(settings.model))\",\"system_prompt\":\"$(escaped(settings.systemprompt))\",\"input\":\"$(escaped(input))\"}"
end

function content(body::AbstractVector{UInt8})
    parsed = try
        parse(String(body))
    catch
        nothing
    end
    content(parsed)
end

content(::Nothing) = ""
content(text::AbstractString) = visible(text)
content(::Any) = ""

function content(data::AbstractVector)
    for entry in data
        text = content(entry)
        isempty(text) || return text
    end
    ""
end

function content(data::AbstractDict)
    for key in ("choices", "message", "output", "output_text", "content", "text", "response")
        text = content(get(data, key, nothing))
        isempty(text) || return text
    end
    ""
end

function headers(settings)
    settings.password == "" ? ["Content-Type" => "application/json"] : ["Content-Type" => "application/json", "Authorization" => "Bearer $(settings.password)"]
end

function request(settings, item::Candidate)
    response = HTTP.post(endpoint(settings); headers = headers(settings), body = payload(settings, item), readtimeout = settings.timeoutseconds)
    response.status == 200 || return (candidate = item, text = "")
    (candidate = item, text = content(response.body))
end

function consume!(requests, responses, settings)
    while true
        item = take!(requests)
        item === nothing && break
        try
            put!(responses, request(settings, item))
        catch error
            @info "llm request failed" error
            put!(responses, (candidate = item, text = ""))
        end
    end
    nothing
end

function write!(report, result::LlmResult)
    isempty(result.text) && return 0
    write(report, "\n\n## page=$(result.candidate.page) file=$(result.candidate.file) score=$(result.candidate.score)\n\n")
    write(report, result.text)
    1
end

function collect!(result::LlmResult, report, completed, written, meter)
    completed[] += 1
    written[] += write!(report, result)
    next!(meter)
    nothing
end

function collect!(responses, report, completed, written, meter, ::ReadyDrain)
    while isready(responses)
        collect!(take!(responses), report, completed, written, meter)
    end
    nothing
end

function collect!(responses, report, completed, written, meter, ::BlockingDrain)
    collect!(take!(responses), report, completed, written, meter)
    collect!(responses, report, completed, written, meter, ReadyDrain())
end

function dispatch!(frontier, requests, submitted, limit)
    while submitted[] < limit && !isempty(frontier) && !isfull(requests)
        put!(requests, popmin!(frontier))
        submitted[] += 1
    end
    nothing
end

function channels(poolsize, window)
    pages = Channel{Vector{NamedTuple{(:page, :bytes, :count, :file), Tuple{Int, Vector{UInt8}, Int, Int}}}}(poolsize)
    scores = Channel{Vector{ScoredPage}}(poolsize)
    buffers = Channel{Vector{UInt8}}(poolsize)
    for _ in Base.OneTo(poolsize)
        put!(buffers, Vector{UInt8}(undef, window))
    end
    (pages = pages, scores = scores, buffers = buffers)
end

function llm(settings)
    submitted = Ref(0)
    completed = Ref(0)
    written = Ref(0)
    workers = 1
    requests = Channel{Union{Nothing, Candidate}}(workers)
    responses = Channel{LlmResult}(max(settings.maxpages, workers))
    consumers = settings.maxpages > 0 ? [Threads.@spawn consume!(requests, responses, settings) for _ in Base.OneTo(workers)] : Task[]
    (submitted = submitted, completed = completed, written = written, workers = workers, requests = requests, responses = responses, consumers = consumers)
end

function stream!(scores, frontier, frontierlimit, state, settings, report, llmprogress, crawlprogress, buffers)
    processed = 0
    distancetotal = 0.0
    for batch in scores
        for item in batch
            processed += 1
            distancetotal += item.score
            queue!(frontier, candidate(item), frontierlimit)
            put!(buffers, item.bytes)
            settings.maxpages == 0 || begin
                dispatch!(frontier, state.requests, state.submitted, settings.maxpages)
                collect!(state.responses, report, state.completed, state.written, llmprogress, ReadyDrain())
            end
            next!(crawlprogress)
        end
    end
    (processed = processed, distancetotal = distancetotal)
end

function drain!(frontier, settings, state, report, llmprogress)
    settings.maxpages == 0 && return nothing
    while state.completed[] < state.submitted[] || (state.submitted[] < settings.maxpages && !isempty(frontier))
        dispatch!(frontier, state.requests, state.submitted, settings.maxpages)
        state.completed[] < state.submitted[] ? collect!(state.responses, report, state.completed, state.written, llmprogress, BlockingDrain()) : collect!(state.responses, report, state.completed, state.written, llmprogress, ReadyDrain())
    end
    nothing
end

function stop!(settings, state)
    settings.maxpages == 0 && return nothing
    for _ in Base.OneTo(state.workers)
        put!(state.requests, nothing)
    end
    for consumer in state.consumers
        wait(consumer)
    end
    nothing
end

function crawl(crawlpath, crawlroot, previewseconds)
    started = time()
    budgetmeter = ProgressThresh(0.0; output = devnull)
    crawlprogress = ProgressUnknown(; desc = "crawl pages", showspeed = true, output = stderr, enabled = true, dt = 0.2)
    llmprogress = ProgressUnknown(; desc = "llm writes", showspeed = true, output = stderr, enabled = true, dt = 0.2, spinner = true)
    targets = (collect(codeunits("trading")), collect(codeunits("strategies")))
    window = 512
    poolsize = 128
    streams = channels(poolsize, window)
    files = Ref(0)
    pages = Ref(0)
    halted = Ref(false)
    frontier = BinaryMinMaxHeap{Candidate}()
    frontierlimit = 10_000
    scorerworkers = Threads.nthreads() > 1 ? Threads.nthreads() - 1 : 1
    settings = configured(openaicompatiblepath)
    state = llm(settings)
    producer = Threads.@spawn produce!(streams.pages, crawlpath, crawlroot, budgetmeter, started, previewseconds, halted, streams.buffers, window, pages, files)
    scorers = [Threads.@spawn score!(streams.scores, streams.pages, targets) for _ in Base.OneTo(scorerworkers)]
    closer = Threads.@spawn begin
        try
            for scorer in scorers
                wait(scorer)
            end
        finally
            isopen(streams.scores) && close(streams.scores)
        end
    end
    report = settings.maxpages > 0 ? open(settings.outputpath, "a") : nothing
    statistics = (processed = 0, distancetotal = 0.0)
    try
        statistics = stream!(streams.scores, frontier, frontierlimit, state, settings, report, llmprogress, crawlprogress, streams.buffers)
        wait(producer)
        wait(closer)
        finish!(crawlprogress)
        drain!(frontier, settings, state, report, llmprogress)
    finally
        stop!(settings, state)
        finish!(llmprogress)
        isnothing(report) || close(report)
    end
    averagedistance = statistics.processed > 0 ? statistics.distancetotal / statistics.processed : 0.0
    bestdistance = isempty(frontier) ? 0.0 : minimum(frontier).score
    cutoffdistance = isempty(frontier) ? 0.0 : maximum(frontier).score
    @info "crawl summary" query files = files[] pages = statistics.processed average_distance = averagedistance queue_pages = length(frontier) best_distance = bestdistance cutoff_distance = cutoffdistance llm_entries = state.written[] output_path = settings.outputpath elapsed = canonicalize(Second(round(Int, time() - started)))
    (files = files[], pages = statistics.processed, averagedistance = averagedistance, queuepages = length(frontier), bestdistance = bestdistance, cutoffdistance = cutoffdistance, llmentries = state.written[], queue = frontier)
end

if abspath(PROGRAM_FILE) == @__FILE__
    crawl(crawlpath, crawlroot, previewseconds)
end
