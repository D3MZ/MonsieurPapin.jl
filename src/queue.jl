using Base.Order: By, ReverseOrdering, ForwardOrdering, lt
using DataStructures: BinaryHeap

score(wet::WET) = wet.score

# Detect forward (lower=better) vs reverse (higher=better) from the ranking type.
# ReverseOrdering(By(f)) wraps as By{f, ReverseOrdering{ForwardOrdering}} in Base.Order.
_forward(::Type{<:By{F,ForwardOrdering}}) where {F} = true
_forward(::Type{<:By{F,ReverseOrdering{ForwardOrdering}}}) where {F} = false

# Mutable wrapper for cross-heap tracking. Both heaps hold references to the same object.
mutable struct QueueEntry{T}
    id::UInt64
    item::T
end
Base.isless(a::QueueEntry, b::QueueEntry) = score(a.item) < score(b.item)

struct WETQueue{Value, Ranking<:Base.Ordering}
    worst::BinaryHeap{QueueEntry{Value}}  # worst at top → evict
    best::BinaryHeap{QueueEntry{Value}}   # best at top → extract
    deleted::Set{UInt64}                  # IDs evicted from worst but still in best
    counter::Base.RefValue{UInt64}
    ranking::Ranking
    capacity::Int
end

function WETQueue(capacity::Int, ::Type{Value}, ranking::Ranking=By(score)) where {Value, Ranking<:Base.Ordering}
    forward = _forward(typeof(ranking))
    by_entry = By(e -> score(e.item))
    rev_entry = ReverseOrdering(by_entry)

    WETQueue{Value,Ranking}(
        forward ? BinaryHeap{QueueEntry{Value}}(rev_entry) : BinaryHeap{QueueEntry{Value}}(by_entry),
        forward ? BinaryHeap{QueueEntry{Value}}(by_entry)  : BinaryHeap{QueueEntry{Value}}(rev_entry),
        Set{UInt64}(),
        Ref(UInt64(0)),
        ranking,
        capacity,
    )
end

Base.length(queue::WETQueue) = length(queue.worst)
Base.isempty(queue::WETQueue) = isempty(queue.worst)
Base.eltype(::WETQueue{Value}) where {Value} = Value
isfull(queue::WETQueue) = length(queue) >= queue.capacity

function insert!(queue::WETQueue{<:WET,Ranking}, item::WET) where {Ranking}
    entry = QueueEntry(queue.counter[] + 1, item)
    !isfull(queue) && return _pushboth!(queue, entry)
    lt(queue.ranking, item, first(queue.worst).item) || return queue
    # Evict worst — track its ID so best heap can skip it
    evicted = pop!(queue.worst)
    push!(queue.deleted, evicted.id)
    _pushboth!(queue, entry)
end

function _pushboth!(queue::WETQueue, entry)
    queue.counter[] = entry.id
    push!(queue.worst, entry)
    push!(queue.best, entry)
    queue
end

insert!(queue::WETQueue{<:WET}, channel::Channel{<:WET}) =
    foreach(item -> insert!(queue, item), channel)

function Base.pop!(queue::WETQueue)
    isempty(queue) && return nothing
    # Pop best, skipping entries evicted from worst
    while !isempty(queue.best)
        entry = pop!(queue.best)
        if entry.id in queue.deleted
            delete!(queue.deleted, entry.id)
            continue
        end
        # Remove from worst heap too — scan for matching id
        _remove!(queue.worst, entry.id)
        return entry.item
    end
    nothing
end

function _remove!(heap::BinaryHeap, id::UInt64)
    values = heap.valtree
    for i in eachindex(values)
        if values[i].id == id
            deleteat!(values, i)
            isempty(values) || heapify!(values, heap.ordering)
            return
        end
    end
end

best!(queue::WETQueue) = pop!(queue)

function best(source; capacity=10, ranking=By(score))
    queue = WETQueue(capacity, eltype(source), ranking)
    insert!(queue, source)
    best!(queue)
end
