struct Snippet{N}
    bytes::NTuple{N,UInt8}
    length::Int
end

function Snippet(bytes::AbstractVector{UInt8}, start, stop, ::Val{N}) where {N}
    len = min(N, max(stop - start + 1, 0))
    tuple = Ref{NTuple{N,UInt8}}()
    ptr = Base.unsafe_convert(Ptr{UInt8}, tuple)
    ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), ptr, 0, N)
    GC.@preserve bytes tuple unsafe_copyto!(ptr, pointer(bytes, start), len)
    Snippet{N}(tuple[], len)
end

Snippet(text::AbstractString, ::Val{N}) where {N} = (u = codeunits(text); Snippet(u, firstindex(u), lastindex(u), Val(N)))

struct WET{U,C}
    uri::Snippet{U}
    content::Snippet{C}
    date::DateTime
    length::Int
    score::Float64
end

update(value, wet::WET) = WET(wet.uri, wet.content, wet.date, wet.length, value)

const urilimit = 4096
const contentlimit = 12000

const warcprefix = codeunits("WARC/1.0")
const typeprefix = codeunits("WARC-Type:")
const conversion = codeunits("conversion")
const uriprefix = codeunits("WARC-Target-URI:")
const dateprefix = codeunits("WARC-Date:")
const lengthprefix = codeunits("Content-Length:")

# --- Accessors ---

function text(snippet::Snippet{N}, limit::Int=snippet.length) where {N}
    len = min(limit, snippet.length)
    bytes = Vector{UInt8}(undef, len)
    tuple = Ref(snippet.bytes)
    GC.@preserve tuple bytes unsafe_copyto!(pointer(bytes), Base.unsafe_convert(Ptr{UInt8}, tuple), len)
    String(bytes)
end

uri(wet::WET) = text(wet.uri)
content(wet::WET) = text(wet.content)
content(wet::WET, limit::Int) = text(wet.content, limit)

# --- High-level API ---

function wets(path::AbstractString; capacity=Threads.nthreads() * 10, wetroot="https://data.commoncrawl.org/")
    isfile(path) && return Channel{WET{urilimit,contentlimit}}(capacity) do channel
        emit(channel, GzipDecompressorStream(open(path)))
    end
    startswith(path, "http") ? wets(URI(path); capacity) : wets(URI(wetroot * path); capacity)
end

function wets(index::URI; capacity=Threads.nthreads() * 10)
    Channel{WET{urilimit,contentlimit}}(capacity) do channel
        HTTP.open("GET", string(index)) do stream
            HTTP.startread(stream)
            emit(channel, GzipDecompressorStream(BufferedInputStream(stream)))
        end
    end
end

wets(paths::AbstractVector{<:Union{AbstractString,URI}}; capacity=Threads.nthreads() * 10, wetroot="https://data.commoncrawl.org/") =
    Channel{WET{urilimit,contentlimit}}(capacity) do c
        foreach(p -> foreach(w -> put!(c, w), wets(p; capacity, wetroot)), paths)
    end

wets(paths::Channel{T}; capacity=Threads.nthreads() * 10, wetroot="https://data.commoncrawl.org/") where {T<:Union{AbstractString,URI}} =
    Channel{WET{urilimit,contentlimit}}(capacity) do c
        foreach(p -> foreach(w -> put!(c, w), wets(p; capacity, wetroot)), paths)
    end

# --- Processing Pipeline ---

function emit(channel, stream::IO)
    line, body = Vector{UInt8}(), Vector{UInt8}(undef, contentlimit)
    sizehint!(line, 256)
    while !isnothing(read!(line, stream))
        matches(line, firstindex(line), warcprefix) || continue
        entry = record(line, body, stream)
        isnothing(entry) || put!(channel, entry)
    end
end

function record(line, buffer, stream)
    kind, address, moment, bytes = header(line, stream)
    keep(kind, address, moment, bytes) || return (discard(stream, buffer, bytes); nothing)
    body(address, moment, bytes, buffer, stream)
end

function header(line, stream)
    kind, address, moment, bytes = false, nothing, nothing, 0
    while !blank(line)
        kind = kind ? true : isconversion(line)
        address = extract(address, line, uriprefix, Val(urilimit))
        moment = extract(moment, line, dateprefix)
        bytes = extract(bytes, line, lengthprefix)
        isnothing(read!(line, stream)) && return (kind, address, moment, bytes)
    end
    (kind, address, moment, bytes)
end

function body(address, moment, bytes, buffer, stream)
    kept = min(bytes, contentlimit)
    readbytes!(stream, buffer, kept) == kept || return nothing
    bytes > kept && discard(stream, buffer, bytes - kept)
    WET(address, Snippet(buffer, firstindex(buffer), kept, Val(contentlimit)), moment, bytes, Inf)
end

# --- Field Extraction ---

isconversion(line) = (v = linevalue(line, firstindex(line), stop(line), typeprefix); !isnothing(v) && length(v) == length(conversion) && matches(line, first(v), conversion))

extract(val::Snippet, line, prefix, limit) = val
extract(::Nothing, line, prefix, limit) = (b = linevalue(line, firstindex(line), stop(line), prefix); isnothing(b) ? nothing : Snippet(line, first(b), last(b), limit))

extract(val::DateTime, line, prefix) = val
extract(::Nothing, line, prefix) = (b = linevalue(line, firstindex(line), stop(line), prefix); isnothing(b) ? nothing : parsedatetime(line, b))

extract(val::Int, line, prefix) = val != 0 ? val : (b = linevalue(line, firstindex(line), stop(line), prefix); isnothing(b) ? 0 : parseint(line, b))

keep(kind, uri, date, len) = kind && !isnothing(uri) && !isnothing(date) && len != 0

function linevalue(bytes, start, stop, prefix)
    matches(bytes, start, prefix) || return nothing
    trim(bytes, start + length(prefix), stop)
end

function parseint(bytes, bounds)
    val = 0
    for i in bounds
        val = 10 * val + digit(bytes[i])
    end
    val
end

function parsedatetime(bytes, b)
    s = first(b)
    DateTime(1000digit(bytes[s]) + 100digit(bytes[s+1]) + 10digit(bytes[s+2]) + digit(bytes[s+3]),
        10digit(bytes[s+5]) + digit(bytes[s+6]), 10digit(bytes[s+8]) + digit(bytes[s+9]),
        10digit(bytes[s+11]) + digit(bytes[s+12]), 10digit(bytes[s+14]) + digit(bytes[s+15]),
        10digit(bytes[s+17]) + digit(bytes[s+18]))
end

# --- Low-level Utilities ---

function matches(bytes, start, prefix)
    stop = start + length(prefix) - 1
    stop <= lastindex(bytes) && @views(bytes[start:stop]) == prefix
end

function trim(bytes, start, stop)
    while start <= stop && (bytes[start] == 0x20 || bytes[start] == 0x09)
        start += 1
    end
    bytes[stop] == 0x0d && (stop -= 1)
    start:stop
end

stop(bytes) = (i = lastindex(bytes); i >= firstindex(bytes) && bytes[i] == 0x0a && (i -= 1); i >= firstindex(bytes) && bytes[i] == 0x0d && (i -= 1); i)
blank(bytes) = stop(bytes) < firstindex(bytes)
digit(byte) = Int(byte - 0x30)

function read!(bytes, stream)
    resize!(bytes, 0)
    while !eof(stream)
        push!(bytes, read(stream, UInt8))
        bytes[end] == 0x0a && return bytes
    end
    isempty(bytes) ? nothing : bytes
end

function discard(stream, buffer, count)
    rem = count
    while rem > 0
        w = min(rem, length(buffer))
        readbytes!(stream, buffer, w) == w || return nothing
        rem -= w
    end
    stream
end
