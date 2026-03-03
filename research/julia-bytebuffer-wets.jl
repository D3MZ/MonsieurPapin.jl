# Julia streaming performance
# Can we get close to allocation-free parsing if the whole decompressed WET file lives in one buffer
# and records only keep tuple spans back into that buffer?
# What's the cost of turning those spans into `@view`s on access?

using BenchmarkTools, CodecZlib, Dates, Logging
import Base: show

# Results
# Parsing directly from the decompressed byte buffer with exact byte-prefix matching cut the parse path
# down to 19 allocations total for the whole 21,321-record file, so the string-search allocations were
# the real problem in the earlier version.
# The remaining 3.67 MiB is mostly the output `Vector{WET}` plus the records themselves; once the spans
# exist, turning them into `@view`s is allocation-free and cheap.
# This means the "whole file in one buffer + span records + view accessors" design does get close to the
# low-allocation behavior you were aiming for, with the main tradeoff being retention of the full parent
# byte buffer for as long as any record survives.
# +----------------------+-----------+--------+----------+
# | case                 | median    | allocs | bytes    |
# +----------------------+-----------+--------+----------+
# | span parse           | 17.588 ms | 19     | 3.67 MiB |
# | content view         | 15.042 us | 0      | 0        |
# | all views            | 30.833 us | 0      | 0        |
# +----------------------+-----------+--------+----------+

struct WET
    uri::Tuple{Int,Int}
    language::Tuple{Int,Int}
    content::Tuple{Int,Int}
    date::DateTime
    length::Int
    score::Float64
end

const warc = codeunits("WARC/1.0")
const typeprefix = codeunits("WARC-Type:")
const conversion = codeunits("conversion")
const uriprefix = codeunits("WARC-Target-URI:")
const dateprefix = codeunits("WARC-Date:")
const languageprefix = codeunits("WARC-Identified-Content-Language:")
const lengthprefix = codeunits("Content-Length:")
const separator = codeunits("\r\n\r\n")

loadbuffer(path) = open(path) do file
    read(GzipDecompressorStream(file))
end

function matches(data, start, prefix)
    stop = start + length(prefix) - 1
    stop <= lastindex(data) || return false
    for offset in eachindex(prefix)
        data[start + offset - 1] == prefix[offset] || return false
    end
    true
end

function findheader(data, start)
    limit = lastindex(data) - length(warc) + 1
    index = start
    while index <= limit
        matches(data, index, warc) && return index
        index += 1
    end
end

function findseparator(data, start)
    limit = lastindex(data) - length(separator) + 1
    index = start
    while index <= limit
        matches(data, index, separator) && return index
        index += 1
    end
end

function findlineend(data, start, stop)
    index = start
    while index <= stop && data[index] != 0x0a
        index += 1
    end
    index
end

function trim(data, start, stop)
    while start <= stop && (data[start] == 0x20 || data[start] == 0x09)
        start += 1
    end
    data[stop] == 0x0d && (stop -= 1)
    (start, stop)
end

function linevalue(data, start, stop, prefix)
    matches(data, start, prefix) || return nothing
    valuestart = start + length(prefix)
    trim(data, valuestart, stop)
end

digit(byte) = Int(byte - 0x30)

function parseint(data, bounds)
    value = 0
    for index in first(bounds):last(bounds)
        value = 10 * value + digit(data[index])
    end
    value
end

function parsedatetime(data, bounds)
    start = first(bounds)
    DateTime(
        1000 * digit(data[start]) + 100 * digit(data[start + 1]) + 10 * digit(data[start + 2]) + digit(data[start + 3]),
        10 * digit(data[start + 5]) + digit(data[start + 6]),
        10 * digit(data[start + 8]) + digit(data[start + 9]),
        10 * digit(data[start + 11]) + digit(data[start + 12]),
        10 * digit(data[start + 14]) + digit(data[start + 15]),
        10 * digit(data[start + 17]) + digit(data[start + 18]),
    )
end

function wet(data, start)
    headerstart = findheader(data, start)
    isnothing(headerstart) && return nothing
    separator = findseparator(data, headerstart)
    isnothing(separator) && return nothing
    headerstop = separator - 1
    bodystart = separator + 4

    kind = false
    uri = nothing
    date = nothing
    language = nothing
    bytes = 0
    index = headerstart

    while index <= headerstop
        lineend = findlineend(data, index, headerstop)
        stop = min(headerstop, lineend - 1)
        if !kind
            value = linevalue(data, index, stop, typeprefix)
            if !isnothing(value)
                kind = last(value) - first(value) + 1 == length(conversion) && matches(data, first(value), conversion)
            end
        end
        isnothing(uri) && (uri = linevalue(data, index, stop, uriprefix))
        isnothing(date) && (date = linevalue(data, index, stop, dateprefix))
        isnothing(language) && (language = linevalue(data, index, stop, languageprefix))
        if bytes == 0
            value = linevalue(data, index, stop, lengthprefix)
            isnothing(value) || (bytes = parseint(data, value))
        end
        index = lineend + 1
    end

    if !kind || isnothing(uri) || isnothing(date) || isnothing(language) || bytes == 0
        return (wet = nothing, next = bodystart + max(bytes, 1))
    end
    bodystop = min(lastindex(data), bodystart + bytes - 1)
    (
        wet = WET(uri, language, (bodystart, bodystop), parsedatetime(data, date), bytes, Inf),
        next = bodystop + 1,
    )
end

function wets(data)
    items = WET[]
    index = firstindex(data)
    while true
        entry = wet(data, index)
        isnothing(entry) && return items
        isnothing(entry.wet) || push!(items, entry.wet)
        index = entry.next
    end
end

span(data, bounds) = @view data[first(bounds):last(bounds)]
uri(data, wet::WET) = span(data, wet.uri)
language(data, wet::WET) = span(data, wet.language)
content(data, wet::WET) = span(data, wet.content)

measure(data) = @benchmark wets($data) evals=1 seconds=0.5
measurecontent(data, entries) = @benchmark foreach(wet -> content($data, wet), $entries) evals=1 seconds=0.5
measurefields(data, entries) = @benchmark foreach(wet -> (uri($data, wet), language($data, wet), content($data, wet)), $entries) evals=1 seconds=0.5

function show(io::IO, data, wet::WET)
    println(io, "uri=", String(uri(data, wet)))
    println(io, "language=", String(language(data, wet)))
    println(io, "date=", wet.date)
    println(io, "length=", wet.length)
    println(io, "content=")
    println(io, String(content(data, wet)))
end

show(data, wet::WET) = show(stdout, data, wet)

function run(path=joinpath(dirname(@__DIR__), "data", "warc.wet.gz"))
    data = loadbuffer(path)
    entries = wets(data)
    @info "Streaming benchmarks" bytes=length(data) records=length(entries)
    @info "Benchmark" case=:span_parse
    display(measure(data))
    @info "Benchmark" case=:content_view
    display(measurecontent(data, entries))
    @info "Benchmark" case=:all_views
    display(measurefields(data, entries))
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && run()
