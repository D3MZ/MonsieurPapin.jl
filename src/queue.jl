using Base.Order: Ordering, ForwardOrdering, ReverseOrdering, Forward, Reverse, By
using DataStructures: BinaryHeap
import DataStructures: heapify!

score(wet::WET) = wet.score

# Mutable wrapper for cross-heap tracking. Both heaps hold references to the same object.
mutable struct Entry{T}
    id::UInt64
    item::T
end

"""
    BoundedPriorityQueue{T}(capacity[, order]) -> BoundedPriorityQueue

A fixed-capacity collection that keeps the best `capacity` items seen, evicting the worst when
full. `order` is `Forward` (lower score is better, e.g. embedding distance) or `Reverse` (higher
score is better, e.g. keyword weight). The single inter-stage primitive of the waterfall: it is
a bounded priority queue *and* a thread-safe, closeable, iterable channel.

- `insert!`/`pop!` are the synchronous core: `insert!` is zero-allocation `O(log n)`, `pop!`
  returns the current best (`O(n)`, deliberately — extraction is rare versus insertion).
- `put!`/`take!`/`close` are the concurrent pipe: `put!` never blocks (it evicts), `take!`
  blocks for the best available item until one arrives or the list is closed, and iteration
  drains best-first. A faster producer simply means only the strongest candidates survive.
"""
mutable struct BoundedPriorityQueue{T}
    worst::BinaryHeap{Entry{T}}  # worst at top → evict
    best::BinaryHeap{Entry{T}}   # best at top → extract
    deleted::Set{UInt64}         # ids evicted from worst but still lingering in best
    counter::UInt64
    higherbetter::Bool
    capacity::Int
    available::Threads.Condition # signals take! when an item arrives or the list closes
    open::Bool
end

function BoundedPriorityQueue{T}(capacity::Integer, order::Ordering=Forward) where {T}
    higherbetter = order isa ReverseOrdering
    low = By(entry -> score(entry.item))    # min-on-score at top
    high = ReverseOrdering(low)             # max-on-score at top
    worst = BinaryHeap{Entry{T}}(higherbetter ? low : high)
    best = BinaryHeap{Entry{T}}(higherbetter ? high : low)
    sizehint!(worst.valtree, capacity)
    sizehint!(best.valtree, capacity)
    BoundedPriorityQueue{T}(worst, best, Set{UInt64}(), UInt64(0), higherbetter, capacity, Threads.Condition(), true)
end

Base.length(list::BoundedPriorityQueue) = length(list.worst)
Base.isempty(list::BoundedPriorityQueue) = isempty(list.worst)
Base.eltype(::Type{<:BoundedPriorityQueue{T}}) where {T} = T
Base.eltype(list::BoundedPriorityQueue) = eltype(typeof(list))
isfull(list::BoundedPriorityQueue) = length(list) >= list.capacity

isbetter(list::BoundedPriorityQueue, a, b) = list.higherbetter ? score(a) > score(b) : score(a) < score(b)

# --- Synchronous core ---

function insert!(list::BoundedPriorityQueue{T}, item::T) where {T}
    entry = Entry(list.counter + 1, item)
    isfull(list) || return pushboth!(list, entry)
    isbetter(list, item, first(list.worst).item) || return list
    push!(list.deleted, pop!(list.worst).id)  # evict worst, remember its id for `best`
    pushboth!(list, entry)
end

function pushboth!(list::BoundedPriorityQueue, entry::Entry)
    list.counter = entry.id
    push!(list.worst, entry)
    push!(list.best, entry)
    list
end

insert!(list::BoundedPriorityQueue, source::Channel) = (foreach(item -> insert!(list, item), source); list)

function Base.pop!(list::BoundedPriorityQueue)
    while !isempty(list.best)
        entry = pop!(list.best)
        if entry.id in list.deleted
            delete!(list.deleted, entry.id)
            continue
        end
        remove!(list.worst, entry.id)
        return entry.item
    end
    nothing
end

function remove!(heap::BinaryHeap, id::UInt64)
    values = heap.valtree
    for i in eachindex(values)
        if values[i].id == id
            deleteat!(values, i)
            isempty(values) || heapify!(values, heap.ordering)
            return
        end
    end
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
