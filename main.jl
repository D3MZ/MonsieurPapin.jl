using HTTP, CodecZlib, ProgressMeter, Dates, Logging, BufferedStreams, DataStructures

crawlpath = "https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
crawlroot = "https://data.commoncrawl.org/"
previewseconds = 8.0
query = "trading strategies"

struct PathFeed end
struct PageFeed end

remaining(started, limit) = limit - (time() - started)

function budget!(meter, started, limit, halted)
    halted[] && return false
    update!(meter, remaining(started, limit); increment = false)
    if meter.triggered
        halted[] = true
        return false
    end
    true
end

function source(consume, url)
    HTTP.open("GET", url) do response
        consume(response)
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
    scratch = Vector{UInt8}(undef, 64 * 1024)
    sink = Vector{UInt8}(undef, 1)
    headerbuffer = IOBuffer()
    info = Ref((kind = false, bytes = 0))
    while true
        budget!(meter, started, limit, halted) || break
        item = record(info, source, meter, started, limit, headerbuffer, halted)
        halted[] && break
        isnothing(item) && break
        if item.kind
            buffer = take!(pool)
            used = capture!(source, item.bytes, scratch, meter, started, limit, halted, buffer, window)
            pages[] += 1
            consume((page = pages[], bytes = buffer, count = used, file = files[]))
        else
            capture!(source, item.bytes, scratch, meter, started, limit, halted, sink, 0)
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
    (page = page.page, file = page.file, score = distance(counts), bytes = page.bytes)
end

function produce!(pageschannel, crawlpath, crawlroot, meter, started, limit, halted, pool, window, pages, files)
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
    close(pageschannel)
end

function score!(scoreschannel, pageschannel, pool, targets)
    word = Vector{UInt8}(undef, 64)
    counts = zeros(Int, 2)
    for batch in pageschannel
        scored = NamedTuple{(:page, :file, :score), Tuple{Int, Int, Float64}}[]
        sizehint!(scored, length(batch))
        for page in batch
            result = score(page, word, counts, targets)
            push!(scored, (page = result.page, file = result.file, score = result.score))
            put!(pool, result.bytes)
        end
        put!(scoreschannel, scored)
    end
end

function queue!(frontier, score, page, file, limit)
    if length(frontier) < limit
        push!(frontier, (score, page, file))
        return nothing
    end
    score < first(maximum(frontier)) || return nothing
    popmax!(frontier)
    push!(frontier, (score, page, file))
    nothing
end

function crawl(crawlpath, crawlroot, previewseconds)
    started = time()
    budgetmeter = ProgressThresh(0.0; output = devnull)
    progress = ProgressUnknown(; desc = "crawl", showspeed = true, output = stdout, enabled = true, dt = 0.2)
    targets = (collect(codeunits("trading")), collect(codeunits("strategies")))
    window = 512
    poolsize = 128
    pageschannel = Channel{Vector{NamedTuple{(:page, :bytes, :count, :file), Tuple{Int, Vector{UInt8}, Int, Int}}}}(poolsize)
    scoreschannel = Channel{Vector{NamedTuple{(:page, :file, :score), Tuple{Int, Int, Float64}}}}(poolsize)
    pool = Channel{Vector{UInt8}}(poolsize)
    for _ in Base.OneTo(poolsize)
        put!(pool, Vector{UInt8}(undef, window))
    end

    files = Ref(0)
    pages = Ref(0)
    halted = Ref(false)
    pending = 0
    batch = 1024
    distance_total = 0.0
    frontier = BinaryMinMaxHeap{Tuple{Float64, Int, Int}}()
    frontierlimit = 10_000
    scorerworkers = 1

    producer = Threads.@spawn produce!(pageschannel, crawlpath, crawlroot, budgetmeter, started, previewseconds, halted, pool, window, pages, files)
    scorers = [Threads.@spawn score!(scoreschannel, pageschannel, pool, targets) for _ in Base.OneTo(scorerworkers)]
    closer = Threads.@spawn begin
        for task in scorers
            wait(task)
        end
        close(scoreschannel)
    end

    processed = 0
    for batchresult in scoreschannel
        for result in batchresult
            processed += 1
            distance_total += result.score
            queue!(frontier, result.score, result.page, result.file, frontierlimit)
            pending += 1
            if pending >= batch
                next!(progress; step = pending)
                pending = 0
            end
        end
    end

    wait(producer)
    wait(closer)
    pending > 0 && next!(progress; step = pending)
    finish!(progress)
    @info "crawl summary" query files = files[] pages = processed average_distance = (processed > 0 ? distance_total / processed : 0.0) queue_pages = length(frontier) best_distance = (isempty(frontier) ? 0.0 : first(minimum(frontier))) cutoff_distance = (isempty(frontier) ? 0.0 : first(maximum(frontier))) elapsed = canonicalize(Second(round(Int, time() - started)))
    (files = files[], pages = processed, averagedistance = (processed > 0 ? distance_total / processed : 0.0), queuepages = length(frontier), bestdistance = (isempty(frontier) ? 0.0 : first(minimum(frontier))), cutoffdistance = (isempty(frontier) ? 0.0 : first(maximum(frontier))), queue = frontier)
end

crawl(crawlpath, crawlroot, previewseconds)
