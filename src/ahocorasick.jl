mutable struct AC{T}
    handle::UInt
end

function AC(keywords::Vector{<:AbstractString})
    RustWorker.load()
    joined = join(keywords, '\x1F')
    entry = AC{UInt32}(RustWorker.call(:build_aho_corasick, joined))
    finalizer(close, entry)
    entry
end

function AC(weights::AbstractDict{<:AbstractString,<:Real})
    RustWorker.load()
    patterns = collect(keys(weights))
    values = Float64[weights[pattern] for pattern in patterns]
    entry = AC{Float64}(RustWorker.call(:build_weighted_aho_corasick, join(patterns, '\x1F'), values))
    finalizer(close, entry)
    entry
end

function Base.close(entry::AC)
    entry.handle == 0 && return entry
    RustWorker.call(:close_aho_corasick, entry.handle)
    entry.handle = 0
    entry
end

function score(entry::AC{UInt32}, pointer::Ptr{UInt8}, length::Integer)
    RustWorker.call(:match_aho_corasick, entry.handle, UInt(pointer), UInt(length))
end

function score(entry::AC{Float64}, pointer::Ptr{UInt8}, length::Integer)
    RustWorker.call(:match_weighted_aho_corasick, entry.handle, UInt(pointer), UInt(length))
end

function score(entry::AC, text::AbstractString)
    score(entry, pointer(text), ncodeunits(text))
end
