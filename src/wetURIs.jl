wetURI(entry) = URI(startswith(entry, "http") ? entry : wetroot * entry)

wetURIs(path::AbstractString) = Channel{URI}(capacity) do uris
    open(path) do file
        for entry in eachline(GzipDecompressorStream(file))
            put!(uris, wetURI(entry))
        end
    end
end

wetURIs(index::URI) = Channel{URI}(capacity) do uris
    HTTP.open("GET", string(index)) do stream
        HTTP.startread(stream)
        for entry in eachline(GzipDecompressorStream(BufferedInputStream(stream)))
            put!(uris, wetURI(entry))
        end
    end
end
