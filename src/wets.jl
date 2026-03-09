struct Snippet{N}
    bytes::NTuple{N,UInt8}
    length::Int
end

struct WET{U,C}
    uri::Snippet{U}
    content::Snippet{C}
    date::DateTime
    length::Int
    score::Float64
end

const urilimit = 4096
const contentlimit = 12000

const warcprefix = codeunits("WARC/1.0")
const typeprefix = codeunits("WARC-Type:")
const conversion = codeunits("conversion")
const uriprefix = codeunits("WARC-Target-URI:")
const dateprefix = codeunits("WARC-Date:")
const lengthprefix = codeunits("Content-Length:")
function matches(bytes, start, prefix)
    stop = start + length(prefix) - 1
    stop <= lastindex(bytes) || return false
    for offset in eachindex(prefix)
        bytes[start + offset - 1] == prefix[offset] || return false
    end
    true
end

function trim(bytes, start, stop)
    while start <= stop && (bytes[start] == 0x20 || bytes[start] == 0x09)
        start += 1
    end
    bytes[stop] == 0x0d && (stop -= 1)
    start:stop
end

function linevalue(bytes, start, stop, prefix)
    matches(bytes, start, prefix) || return nothing
    trim(bytes, start + length(prefix), stop)
end

digit(byte) = Int(byte - 0x30)

function parseint(bytes, bounds)
    value = 0
    for index in bounds
        value = 10 * value + digit(bytes[index])
    end
    value
end

function parsedatetime(bytes, bounds)
    start = first(bounds)
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
    length(value) == length(conversion) && matches(bytes, first(value), conversion)
end

function stop(bytes)
    index = lastindex(bytes)
    index >= firstindex(bytes) && bytes[index] == 0x0a && (index -= 1)
    index >= firstindex(bytes) && bytes[index] == 0x0d && (index -= 1)
    index
end

blank(bytes) = stop(bytes) < firstindex(bytes)

function read!(bytes, stream)
    resize!(bytes, 0)
    while !eof(stream)
        push!(bytes, read(stream, UInt8))
        bytes[lastindex(bytes)] == 0x0a && return bytes
    end
    isempty(bytes) ? nothing : bytes
end

type(bytes) = blank(bytes) ? false : isconversion(bytes, firstindex(bytes), stop(bytes))

function uri(value, bytes)
    !isnothing(value) && return value
    blank(bytes) && return nothing
    bounds = linevalue(bytes, firstindex(bytes), stop(bytes), uriprefix)
    isnothing(bounds) ? nothing : snippet(bytes, first(bounds), last(bounds), Val(urilimit))
end

function date(value, bytes)
    !isnothing(value) && return value
    blank(bytes) && return nothing
    bounds = linevalue(bytes, firstindex(bytes), stop(bytes), dateprefix)
    isnothing(bounds) ? nothing : parsedatetime(bytes, bounds)
end

function size(value, line)
    value != 0 && return value
    blank(line) && return 0
    bounds = linevalue(line, firstindex(line), stop(line), lengthprefix)
    isnothing(bounds) ? 0 : parseint(line, bounds)
end

keep(kind, uri, date, lengthvalue) = kind && !isnothing(uri) && !isnothing(date) && lengthvalue != 0
spanlength(start, stop) = max(stop - start + 1, 0)
limit(stop, start, capacity) = min(capacity, spanlength(start, stop))

function copybytes(bytes, start, lengthvalue, ::Val{N}) where {N}
    tuple = Ref{NTuple{N,UInt8}}()
    pointervalue = Base.unsafe_convert(Ptr{UInt8}, tuple)
    ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), pointervalue, 0, N)
    GC.@preserve bytes tuple unsafe_copyto!(pointervalue, pointer(bytes, start), lengthvalue)
    tuple[]
end

function snippet(bytes, start, stop, ::Val{N}) where {N}
    lengthvalue = limit(stop, start, N)
    Snippet(copybytes(bytes, start, lengthvalue, Val(N)), lengthvalue)
end

function snippet(text::AbstractString, ::Val{N}) where {N}
    units = codeunits(text)
    snippet(units, firstindex(units), lastindex(units), Val(N))
end

text(snippet::Snippet) = text(snippet, snippet.length)

function text(snippet::Snippet{N}, limit::Int) where {N}
    lengthvalue = min(limit, snippet.length)
    bytes = Vector{UInt8}(undef, lengthvalue)
    tuple = Ref(snippet.bytes)
    GC.@preserve tuple bytes unsafe_copyto!(pointer(bytes), Base.unsafe_convert(Ptr{UInt8}, tuple), lengthvalue)
    String(bytes)
end

uri(wet::WET) = text(wet.uri)
content(wet::WET) = text(wet.content)
content(wet::WET, limit::Int) = text(wet.content, limit)

function discard(stream, buffer, count)
    remaining = count
    while remaining > 0
        width = min(remaining, length(buffer))
        readbytes!(stream, buffer, width) == width || return nothing
        remaining -= width
    end
    stream
end

function header(line, stream)
    kind = false
    address = nothing
    moment = nothing
    bytes = 0

    while !blank(line)
        kind = kind ? true : type(line)
        address = uri(address, line)
        moment = date(moment, line)
        bytes = size(bytes, line)
        next = read!(line, stream)
        isnothing(next) && return nothing
        line = next
    end

    (kind, address, moment, bytes)
end

function body(address, moment, bytes, buffer, stream)
    kept = min(bytes, contentlimit)
    readbytes!(stream, buffer, kept) == kept || return nothing
    bytes > kept && discard(stream, buffer, bytes - kept)
    WET(address, snippet(buffer, firstindex(buffer), kept, Val(contentlimit)), moment, bytes, Inf)
end

function record(line, buffer, stream)
    entry = header(line, stream)
    isnothing(entry) && return nothing
    kind, address, moment, bytes = entry
    keep(kind, address, moment, bytes) || return (discard(stream, buffer, bytes); nothing)
    body(address, moment, bytes, buffer, stream)
end

function emit(channel, stream::IO)
    line = Vector{UInt8}(undef, 0)
    sizehint!(line, 256)
    body = Vector{UInt8}(undef, contentlimit)

    while true
        next = read!(line, stream)
        isnothing(next) && return channel
        matches(line, firstindex(line), warcprefix) || continue
        entry = record(line, body, stream)
        isnothing(entry) || put!(channel, entry)
    end
end

function wets(path::AbstractString; capacity=10)
    Channel{WET{urilimit,contentlimit}}(capacity) do channel
        open(path) do file
            emit(channel, BufferedInputStream(GzipDecompressorStream(file)))
        end
    end
end

function wets(index::URI; capacity=10)
    Channel{WET{urilimit,contentlimit}}(capacity) do channel
        HTTP.open("GET", string(index)) do stream
            HTTP.startread(stream)
            emit(channel, GzipDecompressorStream(BufferedInputStream(stream)))
        end
    end
end

function wets(paths::AbstractVector{<:Union{AbstractString,URI}}; capacity=10)
    Channel{WET{urilimit,contentlimit}}(capacity) do channel
        foreach(path -> foreach(wet -> put!(channel, wet), wets(path; capacity)), paths)
    end
end

function wets(paths::Channel{URI}; capacity=10)
    Channel{WET{urilimit,contentlimit}}(capacity) do channel
        foreach(path -> foreach(wet -> put!(channel, wet), wets(path; capacity)), paths)
    end
end

scored(wet::WET, value) = WET(wet.uri, wet.content, wet.date, wet.length, value)
