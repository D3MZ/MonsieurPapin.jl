using Base.Order: Ordering, ReverseOrdering, Forward, Reverse, By
using DataStructures: MutableBinaryHeap

score(wet::WET) = wet.score

"""
    BoundedPriorityQueue{T}(capacity[, order]) -> BoundedPriorityQueue

A fixed-capacity collection that keeps the best `capacity` items seen, evicting the worst when
full. `order` is `Forward` (lower score is better, e.g. embedding distance) or `Reverse` (higher
score is better, e.g. keyword weight). The single inter-stage primitive of the waterfall: it is
a bounded priority queue *and* a thread-safe, closeable, iterable channel.

Items live by value in a fixed `items` arena (slots reused on eviction). Two mutable heaps hold
only `Int` slot handles — the worst on top of one, the best on top of the other — cross-linked
so eviction and extraction remove from *both* in `O(log n)`. Memory is strictly `O(capacity)`:
no per-item boxing and no lazily-deleted backlog, so a fast producer feeding a slow consumer
keeps only the strongest `capacity` survivors resident.

- `insert!`/`pop!` are the synchronous core: `insert!` evicts the worst when full and allocates
  nothing in steady state; `pop!` returns the current best. Both are `O(log n)`.
- `put!`/`take!`/`close` are the concurrent pipe: `put!` never blocks (it evicts), `take!`
  blocks for the best available item until one arrives or the list is closed, and iteration
  drains best-first.
"""
mutable struct BoundedPriorityQueue{T}
    items::Vector{T}                # arena: items[slot] holds an item by value
    worst::MutableBinaryHeap{Int}   # slots, worst-by-score on top → evict
    best::MutableBinaryHeap{Int}    # slots, best-by-score on top → extract
    worsth::Vector{Int}             # slot -> its stable handle in the worst heap
    besth::Vector{Int}              # slot -> its stable handle in the best heap
    free::Vector{Int}               # reusable slots freed by eviction/extraction
    capacity::Int
    higherbetter::Bool
    @atomic threshold::Float64      # lockless admission hint: score of the current worst when full
    available::Threads.Condition    # signals take! when an item arrives or the list closes
    open::Bool
end

function BoundedPriorityQueue{T}(capacity::Integer, order::Ordering=Forward) where {T}
    higherbetter = order isa ReverseOrdering
    items = T[]
    sizehint!(items, capacity)
    byscore = By(slot -> score(items[slot]))
    rev = ReverseOrdering(byscore)
    # worst-on-top: lowest score when higher-is-better, highest score otherwise.
    worst = MutableBinaryHeap{Int}(higherbetter ? byscore : rev)
    best = MutableBinaryHeap{Int}(higherbetter ? rev : byscore)
    BoundedPriorityQueue{T}(items, worst, best, Int[], Int[], Int[], Int(capacity),
                            higherbetter, acceptall(higherbetter), Threads.Condition(), true)
end

Base.length(list::BoundedPriorityQueue) = length(list.worst)
Base.isempty(list::BoundedPriorityQueue) = isempty(list.worst)
Base.eltype(::Type{<:BoundedPriorityQueue{T}}) where {T} = T
Base.eltype(list::BoundedPriorityQueue) = eltype(typeof(list))
isfull(list::BoundedPriorityQueue) = length(list) >= list.capacity

isbetter(list::BoundedPriorityQueue, a, b) = list.higherbetter ? score(a) > score(b) : score(a) < score(b)

# Threshold sentinel that admits everything (no cutoff until the list fills).
acceptall(higherbetter::Bool) = higherbetter ? -Inf : Inf

# Lockless fast-path admission: would an item of this score plausibly survive insertion? Read
# without the lock so a hot producer can skip the vast majority of doomed `put!`s once the list is
# full. The read may be stale, so `insert!` still re-checks under the lock — this only trims work.
admits(list::BoundedPriorityQueue, s::Real) =
    list.higherbetter ? s > (@atomic list.threshold) : s < (@atomic list.threshold)

# Refresh the admission threshold to the current worst score (or accept-all when not full). Called
# only from `insert!`/`pop!`, which run under the list lock in concurrent use.
function syncthreshold!(list::BoundedPriorityQueue)
    @atomic list.threshold = isfull(list) ?
        Float64(score(list.items[first(list.worst)])) : acceptall(list.higherbetter)
    nothing
end

# --- Synchronous core ---

function insert!(list::BoundedPriorityQueue{T}, item::T) where {T}
    if isfull(list)
        worstslot = first(list.worst)
        isbetter(list, item, list.items[worstslot]) || return list  # reject before touching the arena
        evict!(list, worstslot)
    end
    pushslot!(list, slot!(list, item))
    syncthreshold!(list)
    list
end

# Place an item into a free slot (or grow the arena to capacity), returning the slot.
function slot!(list::BoundedPriorityQueue{T}, item::T) where {T}
    isempty(list.free) || (slot = pop!(list.free); list.items[slot] = item; return slot)
    push!(list.items, item)
    push!(list.worsth, 0)
    push!(list.besth, 0)
    lastindex(list.items)
end

function pushslot!(list::BoundedPriorityQueue, slot::Int)
    list.worsth[slot] = push!(list.worst, slot)
    list.besth[slot] = push!(list.best, slot)
    list
end

# Drop the worst slot from both heaps and return it to the free list.
function evict!(list::BoundedPriorityQueue, slot::Int)
    pop!(list.worst)                       # slot is the worst heap's top
    delete!(list.best, list.besth[slot])
    push!(list.free, slot)
end

insert!(list::BoundedPriorityQueue, source::Channel) = (foreach(item -> insert!(list, item), source); list)

function Base.pop!(list::BoundedPriorityQueue)
    isempty(list.best) && return nothing
    slot = pop!(list.best)
    delete!(list.worst, list.worsth[slot])
    item = list.items[slot]
    push!(list.free, slot)
    syncthreshold!(list)
    item
end

# --- Concurrent pipe ---

function Base.put!(list::BoundedPriorityQueue, item)
    lock(list.available)
    try
        insert!(list, item)
        notify(list.available)
    finally
        unlock(list.available)
    end
    list
end

function Base.take!(list::BoundedPriorityQueue)
    lock(list.available)
    try
        while isempty(list) && list.open
            wait(list.available)
        end
        return pop!(list)
    finally
        unlock(list.available)
    end
end

function Base.close(list::BoundedPriorityQueue)
    lock(list.available)
    try
        list.open = false
        notify(list.available; all=true)
    finally
        unlock(list.available)
    end
    nothing
end

Base.isopen(list::BoundedPriorityQueue) = list.open

function Base.iterate(list::BoundedPriorityQueue, ::Nothing=nothing)
    item = take!(list)
    isnothing(item) ? nothing : (item, nothing)
end
Base.IteratorSize(::Type{<:BoundedPriorityQueue}) = Base.SizeUnknown()
