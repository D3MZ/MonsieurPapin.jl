function wetURIs(path::AbstractString; delimiator=codeunits("\n")[1], capacity=Threads.nthreads()*2)
    Channel{StringView}(capacity) do uris
        open(path) do file
            stream = GzipDecompressorStream(file)
            while !eof(stream)
                put!(uris, StringView(readuntil(stream, delimiator; keep=false)))
            end
        end
    end
end

function wetURIs(index::URI; delimiator=codeunits("\n")[1], capacity=Threads.nthreads()*2)
    Channel{StringView}(capacity) do uris
        open(`curl -L -s --fail $(string(index))`) do stream
            gzip = GzipDecompressorStream(BufferedInputStream(stream))
            while !eof(gzip)
                put!(uris, StringView(readuntil(gzip, delimiator; keep=false)))
            end
        end
    end
end
