using ProgressMeter

function wetURIs(path::AbstractString; delimiator=codeunits("\n")[1], capacity=Threads.nthreads()*2)
    Channel{String}(capacity, spawn=true) do uris
        open(path) do file
            stream = GzipDecompressorStream(file)
            while !eof(stream)
                put!(uris, String(readuntil(stream, delimiator; keep=false)))
            end
        end
    end
end

function wetURIs(index::URI; delimiator=codeunits("\n")[1], capacity=Threads.nthreads()*2)
    Channel{String}(capacity, spawn=true) do uris
        progressbar = Progress(100_000; dt=1)
        HTTP.open("GET", index) do stream
            HTTP.startread(stream)
            gzip = GzipDecompressorStream(BufferedInputStream(stream))
            while !eof(gzip)
                put!(uris, String(readuntil(gzip, delimiator; keep=false)))
                next!(progressbar)
            end
        end
        finish!(progressbar)
    end
end
