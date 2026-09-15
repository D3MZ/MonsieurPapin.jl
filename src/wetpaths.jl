using ProgressMeter

function wetpaths(path::AbstractString; delimiter=codeunits("\n")[1], capacity=Threads.nthreads()*2, monitor=nothing)
    Channel{String}(capacity, spawn=true) do uris
        if startswith(path, "http")
            progressbar = Progress(100_000; dt=1)
            HTTP.open("GET", path) do stream
                HTTP.startread(stream)
                gzip = GzipDecompressorStream(BufferedInputStream(stream))
                while !eof(gzip) && pipelineactive(monitor)
                    uri = String(readuntil(gzip, delimiter; keep=false))
                    pipelineactive(monitor) || break
                    put!(uris, uri)
                    next!(progressbar)
                end
            end
            finish!(progressbar)
        else
            open(path) do file
                stream = GzipDecompressorStream(file)
                while !eof(stream) && pipelineactive(monitor)
                    uri = String(readuntil(stream, delimiter; keep=false))
                    pipelineactive(monitor) || break
                    put!(uris, uri)
                end
            end
        end
    end
end

function wetpaths(path::AbstractString, retryconfig::AbstractDict; delimiter=codeunits("\n")[1], capacity=Threads.nthreads()*2, monitor=nothing)
    isfile(path) && return wetpaths(path; delimiter, capacity, monitor)
    wetpaths(URI(path), retryconfig; delimiter, capacity, monitor)
end

function wetpaths(path::URI, retryconfig::AbstractDict; delimiter=codeunits("\n")[1], capacity=Threads.nthreads()*2, monitor=nothing)
    Channel{String}(capacity, spawn=true) do uris
        progressbar = Progress(100_000; dt=1)
        HTTP.request("GET", string(path); body=UInt8[], iofunction=stream -> begin
            response = HTTP.startread(stream)
            response.status == 200 || return
            gzip = GzipDecompressorStream(BufferedInputStream(stream))
            while !eof(gzip) && pipelineactive(monitor)
                uri = String(readuntil(gzip, delimiter; keep=false))
                pipelineactive(monitor) || break
                put!(uris, uri)
                next!(progressbar)
            end
        end, retry=true, retries=retryconfig["retries"],
        retry_delays=Base.ExponentialBackOff(n=retryconfig["retries"], factor=retryconfig["factor"]))
        finish!(progressbar)
    end
end
