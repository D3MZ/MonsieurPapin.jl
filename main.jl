using HTTP, CodecZlib, ProgressMeter, Dates, Logging, BufferedStreams

crawlpath = "https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
crawlroot = "https://data.commoncrawl.org/"
previewseconds = 8.0

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

function skipbytes!(source, bytes, scratch, meter, started, limit, halted)
    remaining = bytes
    while remaining > 0
        budget!(meter, started, limit, halted) || break
        chunk = min(remaining, length(scratch))
        count = readbytes!(source, scratch, chunk)
        count == 0 && break
        remaining -= count
    end
end

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
            kind = kind || (starts(data, index, stop, "WARC-Type:") && equals(data, index + ncodeunits("WARC-Type:") + 1, stop, "conversion"))
            bytes = bytes > 0 ? bytes : value(data, index, stop, "Content-Length:")
        end

        index = lineend + 1
    end

    warc || return nothing
    info[] = (kind = kind, bytes = bytes)
    info[]
end

function record(info, source, meter, started, limit, scratch, headerbuffer, halted)
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
        skipbytes!(source, entry.bytes, scratch, meter, started, limit, halted)
        return entry.kind
    end
    nothing
end

function stream(consume, ::PathFeed, source::IO, meter, started, limit, halted)
    for path in eachline(source)
        budget!(meter, started, limit, halted) || break
        consume(path)
    end
end

function stream(consume, feed::PathFeed, url, meter, started, limit, halted)
    source(url) do response
        stream(consume, feed, decoded(response), meter, started, limit, halted)
    end
end

function stream(consume, ::PageFeed, source::IO, meter, started, limit, halted)
    scratch = Vector{UInt8}(undef, 64 * 1024)
    headerbuffer = IOBuffer()
    info = Ref((kind = false, bytes = 0))
    while true
        budget!(meter, started, limit, halted) || break
        item = record(info, source, meter, started, limit, scratch, headerbuffer, halted)
        halted[] && break
        isnothing(item) && break
        item && consume()
    end
end

function stream(consume, feed::PageFeed, url, meter, started, limit, halted)
    source(url) do response
        stream(consume, feed, decoded(response), meter, started, limit, halted)
    end
end

function crawl(crawlpath, crawlroot, previewseconds)
    started = time()
    budgetmeter = ProgressThresh(0.0; output = devnull)
    progress = ProgressUnknown(; desc = "crawl", showspeed = true, output = stdout, enabled = true, dt = 0.2)
    files = 0
    pages = 0
    pending = 0
    batch = 1024
    halted = Ref(false)

    stream(PathFeed(), crawlpath, budgetmeter, started, previewseconds, halted) do path
        stream(PageFeed(), crawlroot * path, budgetmeter, started, previewseconds, halted) do
            pages += 1
            pending += 1
            if pending >= batch
                next!(progress; step = pending)
                pending = 0
            end
        end
        halted[] || (files += 1)
    end

    pending > 0 && next!(progress; step = pending)
    finish!(progress)
    @info "crawl summary" files pages elapsed = canonicalize(Second(round(Int, time() - started)))
    (files = files, pages = pages)
end

crawl(crawlpath, crawlroot, previewseconds)
