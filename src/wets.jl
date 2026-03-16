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

struct WET{U,C,L}
    uri::Snippet{U}
    content::Snippet{C}
    languages::Snippet{L}
    date::DateTime
    length::Int
    score::Float64
end

update(value, wet::WET) = WET(wet.uri, wet.content, wet.languages, wet.date, wet.length, value)

const urilimit = 4096
const contentlimit = 12000
const languagelimit = 64

const warcprefix = codeunits("WARC/1.0")
const typeprefix = codeunits("WARC-Type:")
const conversion = codeunits("conversion")
const uriprefix = codeunits("WARC-Target-URI:")
const languageprefix = codeunits("WARC-Identified-Content-Language:")
const dateprefix = codeunits("WARC-Date:")
const lengthprefix = codeunits("Content-Length:")

# --- Accessors ---

function clean(bytes::AbstractVector{UInt8})
    kept = length(bytes)
    while kept > 0 && (bytes[kept] & 0xc0) == 0x80
        kept -= 1
    end
    if kept > 0 && (bytes[kept] & 0x80) != 0
        # Check if the leading byte indicates a character that fits
        b = bytes[kept]
        needed = (b & 0xe0) == 0xc0 ? 2 :
                 (b & 0xf0) == 0xe0 ? 3 :
                 (b & 0xf8) == 0xf0 ? 4 : 1
        if length(bytes) - kept + 1 < needed
            kept -= 1
        end
    end
    String(bytes[1:kept])
end

function text(snippet::Snippet{N}, limit::Int=snippet.length) where {N}
    len = min(limit, snippet.length)
    bytes = Vector{UInt8}(undef, len)
    tuple = Ref(snippet.bytes)
    GC.@preserve tuple bytes unsafe_copyto!(pointer(bytes), Base.unsafe_convert(Ptr{UInt8}, tuple), len)
    clean(bytes)
end

uri(wet::WET) = text(wet.uri)
content(wet::WET) = text(wet.content)
content(wet::WET, limit::Int) = text(wet.content, limit)
language(wet::WET) = text(wet.languages)
languages(wet::WET) = filter(code -> !isempty(code), strip.(split(language(wet), ',')))

# --- High-level API ---

function wets(path::AbstractString; capacity=Threads.nthreads() * 10, wetroot="https://data.commoncrawl.org/", languages=nothing)
    isfile(path) && return Channel{WET{urilimit,contentlimit,languagelimit}}(capacity) do channel
        emit(channel, GzipDecompressorStream(open(path)), languages)
    end
    startswith(path, "http") ? wets(URI(path); capacity, languages) : wets(URI(wetroot * path); capacity, languages)
end

function wets(index::URI; capacity=Threads.nthreads() * 10, languages=nothing)
    Channel{WET{urilimit,contentlimit,languagelimit}}(capacity) do channel
        HTTP.open("GET", string(index)) do stream
            HTTP.startread(stream)
            emit(channel, GzipDecompressorStream(BufferedInputStream(stream)), languages)
        end
    end
end

wets(paths::AbstractVector{<:Union{AbstractString,URI}}; capacity=Threads.nthreads() * 10, wetroot="https://data.commoncrawl.org/", languages=nothing) =
    Channel{WET{urilimit,contentlimit,languagelimit}}(capacity) do c
        foreach(p -> foreach(w -> put!(c, w), p isa URI ? wets(p; capacity, languages) : wets(p; capacity, wetroot, languages)), paths)
    end

wets(paths::Channel{T}; capacity=Threads.nthreads() * 10, wetroot="https://data.commoncrawl.org/", languages=nothing) where {T<:Union{AbstractString,URI}} =
    Channel{WET{urilimit,contentlimit,languagelimit}}(capacity) do c
        foreach(p -> foreach(w -> put!(c, w), p isa URI ? wets(p; capacity, languages) : wets(p; capacity, wetroot, languages)), paths)
    end

# --- Processing Pipeline ---

function emit(channel, stream::IO, languages)
    line, body = Vector{UInt8}(), Vector{UInt8}(undef, contentlimit)
    sizehint!(line, 256)
    while !isnothing(read!(line, stream))
        matches(line, firstindex(line), warcprefix) || continue
        entry = record(line, body, stream, languages)
        isnothing(entry) || put!(channel, entry)
    end
end

function record(line, buffer, stream, languages)
    kind, accepted, address, tongue, moment, bytes = header(line, stream, languages)
    keep(kind, accepted, address, moment, bytes) || return (discard(stream, buffer, bytes); nothing)
    body(address, tongue, moment, bytes, buffer, stream)
end

function header(line, stream, languages)
    kind, accepted, address, tongue, moment, bytes = false, isnothing(languages), nothing, nothing, nothing, 0
    while !blank(line)
        kind = kind ? true : isconversion(line)
        address = extract(address, line, uriprefix, Val(urilimit))
        tongue, accepted = extract(tongue, accepted, line, languageprefix, Val(languagelimit), languages)
        moment = extract(moment, line, dateprefix)
        bytes = extract(bytes, line, lengthprefix)
        isnothing(read!(line, stream)) && return (kind, accepted, address, tongue, moment, bytes)
    end
    (kind, accepted, address, tongue, moment, bytes)
end

function body(address, tongue, moment, bytes, buffer, stream)
    kept = min(bytes, contentlimit)
    readbytes!(stream, buffer, kept) == kept || return nothing
    
    if kept > 0 && bytes > kept
        last_start = kept
        while last_start > 0 && (buffer[last_start] & 0xc0) == 0x80
            last_start -= 1
        end
        if last_start > 0 && (buffer[last_start] & 0x80) != 0
            b = buffer[last_start]
            needed = (b & 0xe0) == 0xc0 ? 2 :
                     (b & 0xf0) == 0xe0 ? 3 :
                     (b & 0xf8) == 0xf0 ? 4 : 1
            if kept - last_start + 1 < needed
                kept = last_start - 1
            end
        end
    end

    bytes > min(bytes, contentlimit) && discard(stream, buffer, bytes - min(bytes, contentlimit))
    WET(address, Snippet(buffer, firstindex(buffer), kept, Val(contentlimit)), something(tongue, Snippet("", Val(languagelimit))), moment, bytes, Inf)
end

# --- Field Extraction ---

isconversion(line) = (v = linevalue(line, firstindex(line), stop(line), typeprefix); !isnothing(v) && length(v) == length(conversion) && matches(line, first(v), conversion))

extract(val::Snippet, line, prefix, limit) = val
extract(::Nothing, line, prefix, limit) = (b = linevalue(line, firstindex(line), stop(line), prefix); isnothing(b) ? nothing : Snippet(line, first(b), last(b), limit))
extract(val::Snippet, accepted, line, prefix, limit, languages) = (val, accepted)

function extract(::Nothing, accepted, line, prefix, limit, languages)
    bounds = linevalue(line, firstindex(line), stop(line), prefix)
    isnothing(bounds) && return (nothing, accepted)
    matched = accepted || accepts(languages, line, bounds)
    matched ? (Snippet(line, first(bounds), last(bounds), limit), matched) : (nothing, matched)
end

extract(val::DateTime, line, prefix) = val
extract(::Nothing, line, prefix) = (b = linevalue(line, firstindex(line), stop(line), prefix); isnothing(b) ? nothing : parsedatetime(line, b))

extract(val::Int, line, prefix) = val != 0 ? val : (b = linevalue(line, firstindex(line), stop(line), prefix); isnothing(b) ? 0 : parseint(line, b))

keep(kind, accepted, uri, date, len) = kind && accepted && !isnothing(uri) && !isnothing(date) && len != 0

function linevalue(bytes, start, stop, prefix)
    matches(bytes, start, prefix) || return nothing
    trim(bytes, start + length(prefix), stop)
end

accepts(::Nothing, bytes, bounds) = true

function accepts(languages::AbstractVector{<:AbstractString}, bytes, bounds)
    start = first(bounds)
    stop = last(bounds)
    while start <= stop
        tokenstop = start
        while tokenstop <= stop && bytes[tokenstop] != UInt8(',')
            tokenstop += 1
        end
        token = trim(bytes, start, tokenstop - 1)
        for code in languages
            matches(bytes, first(token), last(token), code) && return true
        end
        start = tokenstop + 1
    end
    false
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

function matches(bytes, start, stop, text::AbstractString)
    stop - start + 1 == ncodeunits(text) || return false
    for (offset, byte) in enumerate(codeunits(text))
        bytes[start + offset - 1] == byte || return false
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
