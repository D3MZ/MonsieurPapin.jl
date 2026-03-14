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

    function hash64(h::UInt64)
        h = (h ⊻ (h >> 33)) * 0xff51afd7ed558ccd
        h = (h ⊻ (h >> 33)) * 0xc4ceb9fe1a85ec53
        h = h ⊻ (h >> 33)
        return h
    end

    @inbounds for i in 1:(n - 2)
        # Use a more spread-out packing for the shingle
        h_seed = (UInt64(bytes[i]) << 32) ⊻ (UInt64(bytes[i+1]) << 16) ⊻ UInt64(bytes[i+2])
        # Add a "positional" salt to reduce sequential bias
        h = hash64(h_seed ⊻ UInt64(i))

        for j in 0:63
            if ((h >> j) & 1) == 1
                v[j+1] += 1
            else
                v[j+1] -= 1
            end
        end
    end

    fingerprint = UInt64(0)
    for j in 0:63
        if v[j+1] > 0
            fingerprint |= (UInt64(1) << j)
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
