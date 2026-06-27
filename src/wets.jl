struct Snippet{N}
    bytes::NTuple{N,UInt8}
    length::Int
end

function Snippet(bytes::AbstractVector{UInt8}, start, stop, ::Val{N}) where {N}
    len = min(N, max(stop - start + 1, 0))
    len == 0 && return Snippet{N}((ntuple(i -> zero(UInt8), N)), 0)

    tuple = Ref{NTuple{N,UInt8}}()
    ptr = Base.unsafe_convert(Ptr{UInt8}, tuple)
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

rescore(wet::WET, value) = WET(wet.uri, wet.content, wet.languages, wet.date, wet.length, value)

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

# Largest length <= len that ends on a UTF-8 character boundary, for a content buffer.
function utf8boundary(bytes::AbstractVector{UInt8}, len::Integer)
    kept = len
    while kept > 0 && (bytes[kept] & 0xc0) == 0x80
        kept -= 1
    end
    if kept > 0 && (bytes[kept] & 0x80) != 0
        lead = bytes[kept]
        needed = (lead & 0xe0) == 0xc0 ? 2 :
                 (lead & 0xf0) == 0xe0 ? 3 :
                 (lead & 0xf8) == 0xf0 ? 4 : 1
        len - kept + 1 < needed && (kept -= 1)
    end
    kept
end

function decode(bytes::AbstractVector{UInt8})
    kept = utf8boundary(bytes, length(bytes))
    String(bytes[1:kept])
end

function text(snippet::Snippet{N}, limit::Int=snippet.length) where {N}
    len = min(limit, snippet.length)
    bytes = Vector{UInt8}(undef, len)
    tuple = Ref(snippet.bytes)
    GC.@preserve tuple bytes unsafe_copyto!(pointer(bytes), Base.unsafe_convert(Ptr{UInt8}, tuple), len)
    decode(bytes)
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

function wets(paths::Channel{T}; capacity=Threads.nthreads() * 10, wetroot="https://data.commoncrawl.org/", languages=nothing) where {T}
    Channel{WET{urilimit,contentlimit,languagelimit}}(capacity) do channel
        for path in paths
            HTTP.open("GET", wetroot * path) do stream
                HTTP.startread(stream)
                emit(channel, GzipDecompressorStream(BufferedInputStream(stream)), languages)
            end
        end
    end
end

# --- Processing Pipeline ---

function emit(channel, stream::IO, languages)
    line, buffer = Vector{UInt8}(), Vector{UInt8}(undef, contentlimit)
    sizehint!(line, 256)
    while !isnothing(readinto!(line, stream))
        matches(line, firstindex(line), warcprefix) || continue
        entry = parserecord(line, buffer, stream, languages)
        isnothing(entry) || put!(channel, entry)
    end
end

function parserecord(line, buffer, stream, languages)
    kind, accepted, address, tongue, moment, bytes = parseheader(line, stream, languages)
    keepable(kind, accepted, address, moment, bytes) || return (discard(stream, buffer, bytes); nothing)
    readbody(address, tongue, moment, bytes, buffer, stream)
end

function parseheader(line, stream, languages)
    kind, accepted, address, tongue, moment, bytes = false, isnothing(languages), nothing, nothing, nothing, 0
    while !isblank(line)
        kind = kind ? true : isconversion(line)
        address = parsefield(address, line, uriprefix, Val(urilimit))
        tongue, accepted = parsefield(tongue, accepted, line, languageprefix, Val(languagelimit), languages)
        moment = parsefield(moment, line, dateprefix)
        bytes = parsefield(bytes, line, lengthprefix)
        isnothing(readinto!(line, stream)) && return (kind, accepted, address, tongue, moment, bytes)
    end
    (kind, accepted, address, tongue, moment, bytes)
end

function readbody(address, tongue, moment, bytes, buffer, stream)
    kept = min(bytes, contentlimit)
    readbytes!(stream, buffer, kept) == kept || return nothing

    if kept > 0 && bytes > kept
        kept = utf8boundary(buffer, kept)
    end

    bytes > min(bytes, contentlimit) && discard(stream, buffer, bytes - min(bytes, contentlimit))
    WET(address, Snippet(buffer, firstindex(buffer), kept, Val(contentlimit)), something(tongue, Snippet("", Val(languagelimit))), moment, bytes, Inf)
end

# --- Field Parsing ---

isconversion(line) = (v = linevalue(line, firstindex(line), lineend(line), typeprefix); !isnothing(v) && length(v) == length(conversion) && matches(line, first(v), conversion))

parsefield(val::Snippet, line, prefix, limit) = val
parsefield(::Nothing, line, prefix, limit) = (b = linevalue(line, firstindex(line), lineend(line), prefix); isnothing(b) ? nothing : Snippet(line, first(b), last(b), limit))
parsefield(val::Snippet, accepted, line, prefix, limit, languages) = (val, accepted)

function parsefield(::Nothing, accepted, line, prefix, limit, languages)
    bounds = linevalue(line, firstindex(line), lineend(line), prefix)
    isnothing(bounds) && return (nothing, accepted)
    matched = accepted || accepts(languages, line, bounds)
    matched ? (Snippet(line, first(bounds), last(bounds), limit), matched) : (nothing, matched)
end

parsefield(val::DateTime, line, prefix) = val
parsefield(::Nothing, line, prefix) = (b = linevalue(line, firstindex(line), lineend(line), prefix); isnothing(b) ? nothing : parsedatetime(line, b))

parsefield(val::Int, line, prefix) = val != 0 ? val : (b = linevalue(line, firstindex(line), lineend(line), prefix); isnothing(b) ? 0 : parseint(line, b))

keepable(kind, accepted, uri, date, len) = kind && accepted && !isnothing(uri) && !isnothing(date) && len != 0

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
        val = 10 * val + todigit(bytes[i])
    end
    val
end

function parsedatetime(bytes, b)
    s = first(b)
    DateTime(1000todigit(bytes[s]) + 100todigit(bytes[s+1]) + 10todigit(bytes[s+2]) + todigit(bytes[s+3]),
        10todigit(bytes[s+5]) + todigit(bytes[s+6]), 10todigit(bytes[s+8]) + todigit(bytes[s+9]),
        10todigit(bytes[s+11]) + todigit(bytes[s+12]), 10todigit(bytes[s+14]) + todigit(bytes[s+15]),
        10todigit(bytes[s+17]) + todigit(bytes[s+18]))
end

# --- Low-level Utilities ---

function matches(bytes, start, prefix)
    width = length(prefix)
    stop = start + width - 1
    stop > lastindex(bytes) && return false
    for i in 0:width-1
        bytes[start + i] == prefix[i+1] || return false
    end
    return true
end

function matches(bytes, start, stop, text::AbstractString)
    stop - start + 1 == ncodeunits(text) || return false
    for i in 0:(stop - start)
        bytes[start + i] == codeunits(text)[i+1] || return false
    end
    true
end

function trim(bytes, left, right)
    while left <= right && (bytes[left] == 0x20 || bytes[left] == 0x09)
        left += 1
    end
    bytes[right] == 0x0d && (right -= 1)
    left:right
end

lineend(bytes) = (i = lastindex(bytes); i >= firstindex(bytes) && bytes[i] == 0x0a && (i -= 1); i >= firstindex(bytes) && bytes[i] == 0x0d && (i -= 1); i)
isblank(bytes) = lineend(bytes) < firstindex(bytes)
todigit(byte) = Int(byte - 0x30)

# Read one line (excluding the trailing newline) into the reused buffer. The buffer keeps its
# capacity across calls, so steady-state header parsing is allocation-free — unlike `readuntil`,
# which allocates a fresh array per line.
function readinto!(bytes, stream)
    eof(stream) && return nothing
    resize!(bytes, 0)
    while !eof(stream)
        byte = read(stream, UInt8)
        byte == 0x0a && break
        push!(bytes, byte)
    end
    bytes
end

function discard(stream, buffer, count)
    rem = count
    while rem > 0
        w = min(rem, length(buffer))
        readbytes!(stream, buffer, w)
        rem -= w
    end
    stream
end
