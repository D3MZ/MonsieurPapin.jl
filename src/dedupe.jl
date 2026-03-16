using DataStructures: CircularBuffer
using StringViews

"""
    simhash(bytes::AbstractVector{UInt8})::UInt64

Generate a 64-bit SimHash fingerprint for the given byte array using 3-gram shingles.
"""
function simhash(bytes::AbstractVector{UInt8})::UInt64
    v = zeros(Int32, 64)
    n = length(bytes)
    n < 3 && return UInt64(0)

    # Pre-calculate hash constants
    m1 = 0xff51afd7ed558ccd
    m2 = 0xc4ceb9fe1a85ec53

    @inbounds for i in 1:(n - 2)
        h = (UInt64(bytes[i]) << 32) ⊻ (UInt64(bytes[i+1]) << 16) ⊻ UInt64(bytes[i+2])
        h ⊻= UInt64(i)
        
        # Inlined hash64
        h = (h ⊻ (h >> 33)) * m1
        h = (h ⊻ (h >> 33)) * m2
        h ⊻= (h >> 33)

        for j in 1:64
            v[j] += ((h >> (j-1)) & 1) == 1 ? 1 : -1
        end
    end

    fingerprint = UInt64(0)
    for j in 1:64
        if v[j] > 0
            fingerprint |= (UInt64(1) << (j-1))
        end
    end
    return fingerprint
end

simhash(text::AbstractString) = simhash(codeunits(text))

struct Deduper
    window::CircularBuffer{UInt64}
    seen::Set{UInt64}
    
    function Deduper(capacity::Int)
        new(CircularBuffer{UInt64}(capacity), Set{UInt64}())
    end
end

function seen!(deduper::Deduper, hash::UInt64)::Bool
    if hash in deduper.seen
        return true
    end
    
    # CircularBuffer isfull check
    if length(deduper.window) == deduper.window.capacity
        oldest = popfirst!(deduper.window)
        delete!(deduper.seen, oldest)
    end
    
    push!(deduper.window, hash)
    push!(deduper.seen, hash)
    return false
end

isduplicate(deduper::Deduper, bytes::AbstractVector{UInt8}) = seen!(deduper, simhash(bytes))
isduplicate(deduper::Deduper, text::AbstractString) = seen!(deduper, simhash(text))

function isduplicate(deduper::Deduper, wet::WET{U,C}) where {U,C}
    reference = Ref(wet)
    GC.@preserve reference begin
        ptr = Base.unsafe_convert(Ptr{WET{U,C}}, reference) + contentoffset(WET{U,C})
        view = StringView(unsafe_wrap(Vector{UInt8}, Ptr{UInt8}(ptr), wet.content.length))
        isduplicate(deduper, view)
    end
end
