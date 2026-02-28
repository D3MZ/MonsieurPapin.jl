module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates
using HTTP: URI

export WARC, wetURIs, wets

const capacity = 10
const wetroot = "https://data.commoncrawl.org/"

struct WARC
    uri::URI
    date::DateTime
    language::String
    length::Int
    content::String
end

WARC(uri::AbstractString, date::AbstractString, language::AbstractString, length::AbstractString, content::String) = WARC(
    URI(uri),
    DateTime(date, dateformat"yyyy-mm-ddTHH:MM:SSZ"),
    String(language),
    parse(Int, length),
    content,
)

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

function value(lines, prefix)
    for line in lines
        startswith(line, prefix) && return strip(line[length(prefix)+1:end])
    end
end

bytes(lines) = parse(Int, value(lines, "Content-Length:"))

WARC(lines, content) = WARC(
    value(lines, "WARC-Target-URI:"),
    value(lines, "WARC-Date:"),
    value(lines, "WARC-Identified-Content-Language:"),
    value(lines, "Content-Length:"),
    content,
)

function header(stream)
    lines = String[]
    while !eof(stream)
        line = readline(stream)
        isempty(line) && isempty(lines) && continue
        isempty(line) && return lines
        push!(lines, line)
    end
    isempty(lines) ? nothing : lines
end

function wet(stream)
    while !eof(stream)
        lines = header(stream)
        isnothing(lines) && return nothing
        content = String(read(stream, bytes(lines)))
        value(lines, "WARC-Type:") == "conversion" || continue
        return WARC(lines, content)
    end
end

function emit(channel, stream)
    while !eof(stream)
        entry = wet(stream)
        isnothing(entry) && break
        put!(channel, entry)
    end
end

wets(path::AbstractString) = Channel{WARC}(capacity) do channel
    open(path) do file
        emit(channel, GzipDecompressorStream(file))
    end
end

wets(index::URI) = Channel{WARC}(capacity) do channel
    HTTP.open("GET", string(index)) do stream
        HTTP.startread(stream)
        emit(channel, GzipDecompressorStream(BufferedInputStream(stream)))
    end
end

end
