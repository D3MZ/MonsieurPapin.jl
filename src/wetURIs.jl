using ProgressMeter

function wetURIs(path::AbstractString; delimiator=codeunits("\n")[1], capacity=Threads.nthreads()*2)
    Channel{String}(capacity, spawn=true) do uris
        if startswith(path, "http")
            progressbar = Progress(100_000; dt=1)
            HTTP.open("GET", URI(path)) do stream
                HTTP.startread(stream)
                gzip = GzipDecompressorStream(BufferedInputStream(stream))
                while !eof(gzip)
                    put!(uris, String(readuntil(gzip, delimiator; keep=false)))
                    next!(progressbar)
                end
            end
            finish!(progressbar)
        else
            open(path) do file
                stream = GzipDecompressorStream(file)
                while !eof(stream)
                    put!(uris, String(readuntil(stream, delimiator; keep=false)))
                end
            end
        end
    end
end