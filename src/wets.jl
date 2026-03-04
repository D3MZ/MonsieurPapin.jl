struct Segment
    start::Int
    stop::Int
end

struct WET
    source::Int
    uri::Segment
    language::Segment
    content::Segment
    date::DateTime
    length::Int
    score::Float64
end

struct Wets
    entries::Channel{WET}
    buffers::Vector{Vector{UInt8}}
end

Base.iterate(pages::Wets, state...) = iterate(pages.entries, state...)
Base.eltype(::Type{Wets}) = WET
Base.IteratorSize(::Type{Wets}) = Base.SizeUnknown()

const warcprefix = codeunits("WARC/1.0")
const typeprefix = codeunits("WARC-Type:")
const conversion = codeunits("conversion")
const uriprefix = codeunits("WARC-Target-URI:")
const dateprefix = codeunits("WARC-Date:")
const languageprefix = codeunits("WARC-Identified-Content-Language:")
const lengthprefix = codeunits("Content-Length:")
const headerseparator = codeunits("\r\n\r\n")

loadbuffer(path::AbstractString) = open(path) do file
    read(GzipDecompressorStream(file))
end

loadbuffer(index::URI) = HTTP.open("GET", string(index)) do stream
    HTTP.startread(stream)
    read(GzipDecompressorStream(BufferedInputStream(stream)))
end

function matches(bytes, start, prefix)
    stop = start + length(prefix) - 1
    stop <= lastindex(bytes) || return false
    for offset in eachindex(prefix)
        bytes[start + offset - 1] == prefix[offset] || return false
    end
    true
end

function findheader(bytes, start)
    limit = lastindex(bytes) - length(warcprefix) + 1
    index = start
    while index <= limit
        matches(bytes, index, warcprefix) && return index
        index += 1
    end
end

function findseparator(bytes, start)
    limit = lastindex(bytes) - length(headerseparator) + 1
    index = start
    while index <= limit
        matches(bytes, index, headerseparator) && return index
        index += 1
    end
end

function findlineend(bytes, start, stop)
    index = start
    while index <= stop && bytes[index] != 0x0a
        index += 1
    end
    index
end

function trim(bytes, start, stop)
    while start <= stop && (bytes[start] == 0x20 || bytes[start] == 0x09)
        start += 1
    end
    bytes[stop] == 0x0d && (stop -= 1)
    Segment(start, stop)
end

function linevalue(bytes, start, stop, prefix)
    matches(bytes, start, prefix) || return nothing
    trim(bytes, start + length(prefix), stop)
end

Base.length(segment::Segment) = segment.stop - segment.start + 1

digit(byte) = Int(byte - 0x30)

function parseint(bytes, bounds)
    value = 0
    for index in bounds.start:bounds.stop
        value = 10 * value + digit(bytes[index])
    end
    value
end

function parsedatetime(bytes, bounds)
    start = bounds.start
    DateTime(
        1000 * digit(bytes[start]) + 100 * digit(bytes[start + 1]) + 10 * digit(bytes[start + 2]) + digit(bytes[start + 3]),
        10 * digit(bytes[start + 5]) + digit(bytes[start + 6]),
        10 * digit(bytes[start + 8]) + digit(bytes[start + 9]),
        10 * digit(bytes[start + 11]) + digit(bytes[start + 12]),
        10 * digit(bytes[start + 14]) + digit(bytes[start + 15]),
        10 * digit(bytes[start + 17]) + digit(bytes[start + 18]),
    )
end

function isconversion(bytes, start, stop)
    value = linevalue(bytes, start, stop, typeprefix)
    isnothing(value) && return false
    length(value) == Base.length(conversion) && matches(bytes, value.start, conversion)
end

field(value, bytes, start, stop, prefix) = isnothing(value) ? linevalue(bytes, start, stop, prefix) : value

function contentlength(value, bytes, start, stop)
    value != 0 && return value
    bounds = linevalue(bytes, start, stop, lengthprefix)
    isnothing(bounds) ? 0 : parseint(bytes, bounds)
end

function fields(bytes, headerstart, headerstop)
    kind = false
    uri = nothing
    date = nothing
    language = nothing
    lengthvalue = 0
    index = headerstart

    while index <= headerstop
        lineend = findlineend(bytes, index, headerstop)
        stop = min(headerstop, lineend - 1)
        kind = kind ? true : isconversion(bytes, index, stop)
        uri = field(uri, bytes, index, stop, uriprefix)
        date = field(date, bytes, index, stop, dateprefix)
        language = field(language, bytes, index, stop, languageprefix)
        lengthvalue = contentlength(lengthvalue, bytes, index, stop)
        index = lineend + 1
    end

    (kind, uri, date, language, lengthvalue)
end

function bounds(bytes, start)
    headerstart = findheader(bytes, start)
    isnothing(headerstart) && return nothing
    separator = findseparator(bytes, headerstart)
    isnothing(separator) && return nothing
    (headerstart = headerstart, headerstop = separator - 1, contentstart = separator + 4)
end

keep(kind, uri, date, language, lengthvalue) =
    kind && !isnothing(uri) && !isnothing(date) && !isnothing(language) && lengthvalue != 0

function parsedwet(bytes, source, uri, date, language, lengthvalue, contentstart)
    contentstop = min(lastindex(bytes), contentstart + lengthvalue - 1)
    WET(source, uri, language, Segment(contentstart, contentstop), parsedatetime(bytes, date), lengthvalue, Inf), contentstop + 1
end

function parsed(bytes, start, source)
    range = bounds(bytes, start)
    isnothing(range) && return nothing
    kind, uri, date, language, lengthvalue = fields(bytes, range.headerstart, range.headerstop)
    keep(kind, uri, date, language, lengthvalue) || return (wet = nothing, next = range.contentstart + max(lengthvalue, 1))
    wet, next = parsedwet(bytes, source, uri, date, language, lengthvalue, range.contentstart)
    (wet = wet, next = next)
end

function emit(channel, bytes, source)
    index = firstindex(bytes)
    while true
        entry = parsed(bytes, index, source)
        isnothing(entry) && return channel
        isnothing(entry.wet) || put!(channel, entry.wet)
        index = entry.next
    end
end

function wets(buffers::Vector{Vector{UInt8}}; capacity=10)
    entries = Channel{WET}(capacity) do channel
        foreach(enumerate(buffers)) do entry
            emit(channel, last(entry), first(entry))
        end
    end
    Wets(entries, buffers)
end

function streamwets(paths; capacity=10)
    buffers = Vector{Vector{UInt8}}()
    entries = Channel{WET}(capacity) do channel
        foreach(paths) do path
            buffer = loadbuffer(path)
            push!(buffers, buffer)
            emit(channel, buffer, length(buffers))
        end
    end
    Wets(entries, buffers)
end

wets(bytes::Vector{UInt8}; capacity=10) = wets([bytes]; capacity)
wets(path::AbstractString; capacity=10) = wets(loadbuffer(path); capacity)
wets(index::URI; capacity=10) = wets(loadbuffer(index); capacity)
wets(paths::AbstractVector{<:Union{AbstractString,URI}}; capacity=10) = streamwets(paths; capacity)
wets(paths::Channel{URI}; capacity=10) = streamwets(paths; capacity)

bytes(pages::Wets, wet::WET) = pages.buffers[wet.source]
span(pages::Wets, wet::WET, segment::Segment) = @view bytes(pages, wet)[segment.start:segment.stop]
uri(pages::Wets, wet::WET) = span(pages, wet, wet.uri)
language(pages::Wets, wet::WET) = span(pages, wet, wet.language)
content(pages::Wets, wet::WET) = span(pages, wet, wet.content)
scored(wet::WET, value) = WET(wet.source, wet.uri, wet.language, wet.content, wet.date, wet.length, value)
