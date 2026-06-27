using DataStructures: CircularBuffer
using StringViews

"""
    simhash(bytes::AbstractVector{UInt8})::UInt64

Generate a 64-bit SimHash fingerprint for the given byte array using 3-gram shingles.
"""
function simhash(bytes::AbstractVector{UInt8})
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

"""
    SeenSet(capacity) -> SeenSet

A fixed-capacity set of SimHash fingerprints with FIFO eviction — a bounded "seen set" for
duplicate detection. Pass it to `unique(seen, stream)` to drop pages already seen within the
window.
"""
struct SeenSet
    window::CircularBuffer{UInt64}
    seen::Set{UInt64}
end

SeenSet(capacity::Integer) = SeenSet(CircularBuffer{UInt64}(capacity), Set{UInt64}())

# True if `hash` was already present; otherwise records it (evicting the oldest when full).
function seen!(set::SeenSet, hash::UInt64)
    hash in set.seen && return true
    length(set.window) == set.window.capacity && delete!(set.seen, popfirst!(set.window))
    push!(set.window, hash)
    push!(set.seen, hash)
    false
end

function simhash(wet::WET{U,C,L}) where {U,C,L}
    reference = Ref(wet)
    GC.@preserve reference begin
        ptr = Base.unsafe_convert(Ptr{WET{U,C,L}}, reference) + contentoffset(WET{U,C,L})
        view = StringView(unsafe_wrap(Vector{UInt8}, Ptr{UInt8}(ptr), wet.content.length))
        simhash(view)
    end
end

seen!(set::SeenSet, wet::WET) = seen!(set, simhash(wet))
