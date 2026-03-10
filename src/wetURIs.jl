function wetURIs(path::AbstractString; delimiator=codeunits("\n")[1], capacity=4)
    Channel{StringView}(capacity) do uris
        open(path) do file
            stream = GzipDecompressorStream(file)
            while !eof(stream)
                put!(uris, StringView(readuntil(stream, delimiator; keep=false)))
            end
        end
    end
end

function wetURIs(index::URI; delimiator=codeunits("\n")[1], capacity=4)
    Channel{StringView}(capacity) do uris
        HTTP.open("GET", string(index)) do stream
            HTTP.startread(stream)
            gzip = GzipDecompressorStream(BufferedInputStream(stream))
            while !eof(gzip)
                put!(uris, StringView(readuntil(gzip, delimiator; keep=false)))
            end
        end
    end
end
