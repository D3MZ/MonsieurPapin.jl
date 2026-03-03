mutable struct WET
    uri::URI
    date::DateTime
    language::String
    length::Int
    content::String
    score::Float64
end

struct Header
    kind
    uri
    date
    language
    length::Int
end

WET(uri::AbstractString, date::AbstractString, language::AbstractString, length::AbstractString, content::String) = WET(
    URI(uri),
    DateTime(date, dateformat"yyyy-mm-ddTHH:MM:SSZ"),
    String(language),
    parse(Int, length),
    content,
    Inf,
)

function value(lines, prefix)
    for line in lines
        startswith(line, prefix) && return strip(line[length(prefix)+1:end])
    end
end

function value(text::AbstractString, prefix)
    start = findfirst(prefix, text)
    isnothing(start) && return nothing
    firstvalue = nextind(text, last(start))
    text[firstvalue] == ' ' && (firstvalue = nextind(text, firstvalue))
    stop = something(findnext('\n', text, firstvalue), nextind(text, lastindex(text)))
    lastvalue = prevind(text, stop)
    text[lastvalue] == '\r' && (lastvalue = prevind(text, lastvalue))
    text[firstvalue:lastvalue]
end

Header(text::AbstractString) = Header(
    value(text, "WARC-Type:"),
    value(text, "WARC-Target-URI:"),
    value(text, "WARC-Date:"),
    value(text, "WARC-Identified-Content-Language:"),
    parse(Int, value(text, "Content-Length:")),
)

keep(header::Header) = header.kind == "conversion" && !isnothing(header.language)

WET(header::Header, content) = WET(
    String(header.uri),
    String(header.date),
    String(header.language),
    string(header.length),
    content,
)

function header(stream, buffer)
    while !eof(stream)
        truncate(buffer, 0)
        seekstart(buffer)
        copyuntil(buffer, stream, "\r\n\r\n")
        text = unsafe_string(pointer(buffer.data), buffer.size)
        isempty(text) && continue
        return Header(text)
    end
end

function wet(stream)
    wet(stream, IOBuffer())
end

function wet(stream, buffer)
    while true
        entry = header(stream, buffer)
        isnothing(entry) && return nothing
        content = String(read(stream, entry.length))
        keep(entry) || continue
        return WET(entry, content)
    end
end

function emit(channel, stream)
    buffer = IOBuffer()
    while true
        entry = wet(stream, buffer)
        isnothing(entry) && break
        put!(channel, entry)
    end
end

wets(path::AbstractString; capacity=10) =
    Channel{WET}(capacity) do channel
        open(path) do file
            emit(channel, GzipDecompressorStream(file))
        end
    end

wets(index::URI; capacity=10) =
    Channel{WET}(capacity) do channel
        HTTP.open("GET", string(index)) do stream
            HTTP.startread(stream)
            emit(channel, GzipDecompressorStream(BufferedInputStream(stream)))
        end
    end
