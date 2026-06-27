using DataStructures: CircularBuffer
using StringViews

"""
    simhash(bytes::AbstractVector{UInt8})::UInt64

Generate a 64-bit SimHash fingerprint for the given byte array using 3-gram shingles.
"""
simhash(bytes::AbstractVector{UInt8}) =
    GC.@preserve bytes simhash(pointer(bytes), length(bytes), Vector{Int32}(undef, 64))

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

# SimHash over content addressed by a raw pointer, accumulating into a reused `v` buffer — no
# wrapper array and no per-call accumulator allocation.
function simhash(ptr::Ptr{UInt8}, n::Integer, v::AbstractVector{Int32})
    n < 3 && return UInt64(0)
    fill!(v, zero(Int32))
    m1 = 0xff51afd7ed558ccd
    m2 = 0xc4ceb9fe1a85ec53

    @inbounds for i in 1:(n - 2)
        h = (UInt64(unsafe_load(ptr, i)) << 32) ⊻ (UInt64(unsafe_load(ptr, i+1)) << 16) ⊻ UInt64(unsafe_load(ptr, i+2))
        h ⊻= UInt64(i)
        h = (h ⊻ (h >> 33)) * m1
        h = (h ⊻ (h >> 33)) * m2
        h ⊻= (h >> 33)

        # Branchless +1/-1 per bit: 2*bit - 1 maps bit 1 -> +1, bit 0 -> -1 (matches the
        # original branch exactly, so fingerprints are unchanged).
        @simd for j in 1:64
            v[j] += Int32(2) * Int32((h >> (j - 1)) & UInt64(1)) - one(Int32)
        end
    end

    fingerprint = UInt64(0)
    for j in 1:64
        v[j] > 0 && (fingerprint |= (UInt64(1) << (j-1)))
    end
    fingerprint
end

# `scratch`/`counts` are reusable buffers owned by the dedup loop, so a streamed WET is hashed
# without boxing the struct or allocating an accumulator. The convenience method allocates both.
function simhash(wet::WET{U,C,L}, scratch::Base.RefValue{WET{U,C,L}}, counts::AbstractVector{Int32}) where {U,C,L}
    scratch[] = wet
    GC.@preserve scratch begin
        ptr = Ptr{UInt8}(Base.unsafe_convert(Ptr{WET{U,C,L}}, scratch) + contentoffset(WET{U,C,L}))
        simhash(ptr, wet.content.length, counts)
    end
end
simhash(wet::WET{U,C,L}) where {U,C,L} = simhash(wet, Ref{WET{U,C,L}}(), Vector{Int32}(undef, 64))

seen!(set::SeenSet, wet::WET, scratch::Base.RefValue, counts::AbstractVector{Int32}) = seen!(set, simhash(wet, scratch, counts))
seen!(set::SeenSet, wet::WET) = seen!(set, simhash(wet))
