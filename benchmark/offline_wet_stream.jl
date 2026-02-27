using HTTP, CodecZlib, BufferedStreams, BenchmarkTools, Logging, JSON, Sockets

include(joinpath(@__DIR__, "..", "main.jl"))

pathindex = crawlpath
pathroot = crawlroot
livepathroot = crawlroot
filecount = 1
previewseconds = 120.0
entry = "crawl-data/CC-MAIN-2026-08/segments/1770395505396.36/wet/CC-MAIN-20260206181458-20260206211458-00000.warc.wet.gz"
streampath = joinpath(@__DIR__, "data", "wet-1-stream.gz")
mirrorroot = joinpath(@__DIR__, "local_cc")
limitpercent = 1.0

function copy!(target, source, scratch)
    while !eof(source)
        count = readbytes!(source, scratch)
        count == 0 && break
        write(target, view(scratch, Base.OneTo(count)))
    end
    nothing
end

function fetch(consume, url)
    HTTP.open("GET", url) do stream
        consume(stream)
    end
end

function paths(pathindex, count)
    entries = String[]
    fetch(pathindex) do stream
        HTTP.startread(stream)
        stream.message.status == 200 || error("path index failed status=$(stream.message.status)")
        for current in eachline(GzipDecompressorStream(BufferedInputStream(stream)))
            push!(entries, current)
            length(entries) >= count && break
        end
    end
    entries
end

function stream!(pathindex, pathroot, streampath, count)
    isfile(streampath) && return streampath
    entries = paths(pathindex, count)
    mkpath(dirname(streampath))
    open(streampath, "w") do target
        scratch = Vector{UInt8}(undef, 256 * 1024)
        for (index, current) in enumerate(entries)
            url = pathroot * current
            @info "streaming wet file" index total = length(entries) url
            fetch(url) do stream
                HTTP.startread(stream)
                stream.message.status == 200 || error("wet file failed status=$(stream.message.status) url=$(url)")
                copy!(target, stream, scratch)
            end
        end
    end
    streampath
end

function mirror!(streampath, mirrorroot, entry)
    destination = joinpath(mirrorroot, entry)
    mkpath(dirname(destination))
    cp(streampath, destination; force = true)
    indexpath = joinpath(mirrorroot, "crawl-data", "CC-MAIN-2026-08", "wet.paths.gz")
    mkpath(dirname(indexpath))
    open(indexpath, "w") do target
        compressed = GzipCompressorStream(target)
        write(compressed, entry * "\n")
        close(compressed)
    end
    mirrorroot
end

function mirror(mirrorroot, port)
    script = """
    using HTTP, Sockets
    mirrorroot = $(repr(mirrorroot))
    port = $(port)
    function route(request)
        target = first(split(request.target, '?'; limit = 2))
        relative = startswith(target, "/") ? target[2:end] : target
        localpath = normpath(joinpath(mirrorroot, relative))
        allowed = localpath == mirrorroot || startswith(localpath, mirrorroot * "/")
        allowed || return HTTP.Response(404)
        isfile(localpath) || return HTTP.Response(404)
        HTTP.Response(200, read(localpath))
    end
    server = HTTP.serve!(route, ip"127.0.0.1", port; verbose = false)
    wait(server)
    """
    run(`$(Base.julia_cmd()) --project=$(Base.active_project()) -e $script`; wait = false)
end

function mirror!(address)
    for _ in Base.OneTo(200)
        response = try
            HTTP.get(address; connect_timeout = 1, readtimeout = 1, retries = 0)
        catch
            nothing
        end
        response isa HTTP.Response && response.status == 200 && return nothing
        sleep(0.05)
    end
    error("mirror startup failed")
end

function port()
    listener = Sockets.listen(ip"127.0.0.1", 0)
    address = getsockname(listener)
    close(listener)
    address[2]
end

function settings(openaicompatiblepath)
    configuration = parsefile(openaicompatiblepath)
    configuration["max_pages"] = 0
    localpath = joinpath(@__DIR__, "data", "openai-compatible.offline.json")
    open(localpath, "w") do target
        JSON.print(target, configuration)
    end
    localpath
end

function measure(crawlpath, crawlroot, previewseconds)
    timed = @timed crawl(crawlpath, crawlroot, previewseconds)
    events = timed.gcstats.poolalloc + timed.gcstats.bigalloc + timed.gcstats.malloc + timed.gcstats.realloc
    pages = timed.value.pages
    pagespersecond = timed.time > 0 ? pages / timed.time : 0.0
    bytesperpage = pages > 0 ? timed.bytes / pages : 0.0
    eventsperpage = pages > 0 ? events / pages : 0.0
    (pages = pages, elapsedseconds = timed.time, pagespersecond = pagespersecond, allocatedbytes = timed.bytes, allocationevents = events, bytesperpage = bytesperpage, eventsperpage = eventsperpage)
end

deviation(base, value) = abs(value - base) / (base + eps()) * 100

function benchmarkoffline(pathindex, pathroot, livepathroot, streampath, filecount, previewseconds, mirrorroot, entry, limitpercent)
    stream!(pathindex, pathroot, streampath, filecount)
    mirror!(streampath, mirrorroot, entry)
    settingspath = settings(openaicompatiblepath)
    currentport = port()
    mirrorindex = "http://127.0.0.1:$(currentport)/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
    mirrorrooturl = "http://127.0.0.1:$(currentport)/"
    server = mirror(mirrorroot, currentport)
    mirror!(mirrorindex)
    previous = openaicompatiblepath
    try
        global openaicompatiblepath = settingspath
        crawl(mirrorindex, mirrorrooturl, 1.0)
        crawl(mirrorindex, livepathroot, 1.0)
        live = measure(mirrorindex, livepathroot, previewseconds)
        mirrored = measure(mirrorindex, mirrorrooturl, previewseconds)
        live.pages == mirrored.pages || error("page mismatch live=$(live.pages) mirror=$(mirrored.pages)")
        bytespercent = deviation(live.bytesperpage, mirrored.bytesperpage)
        eventspercent = deviation(live.eventsperpage, mirrored.eventsperpage)
        @info "live benchmark" live...
        @info "offline http mirror benchmark" mirrored...
        @info "allocation deviation percent" bytes_per_page = bytespercent events_per_page = eventspercent
        bytespercent <= limitpercent || error("bytes/page deviation exceeded $(limitpercent)%")
        eventspercent <= limitpercent || error("allocs/page deviation exceeded $(limitpercent)%")
        display(@benchmark crawl($mirrorindex, $mirrorrooturl, $previewseconds) samples=1 evals=1)
    finally
        Base.process_running(server) && Base.kill(server)
        wait(server)
        global openaicompatiblepath = previous
    end
    nothing
end

benchmarkoffline(pathindex, pathroot, livepathroot, streampath, filecount, previewseconds, mirrorroot, entry, limitpercent)
