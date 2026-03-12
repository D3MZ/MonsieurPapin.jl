using Base.Order: By, ReverseOrdering
import DataStructures: heapify!

struct WETQueue{Value, Ordering<:Base.Ordering}
    heap::BinaryHeap{Value, Ordering}
    capacity::Int
end

score(wet::WET) = wet.score

function WETQueue(capacity::Int, ::Type{Value}) where {Value<:WET}
    WETQueue(BinaryHeap{Value}(ReverseOrdering(By(score))), capacity)
end

Base.length(queue::WETQueue) = length(queue.heap)
Base.isempty(queue::WETQueue) = isempty(queue.heap)
isfull(queue::WETQueue) = length(queue) >= queue.capacity

function insert!(queue::WETQueue{<:WET}, item::WET)
    !isfull(queue) && return push!(queue.heap, item)
    score(item) < score(first(queue.heap)) || return queue.heap
    pop!(queue.heap)
    push!(queue.heap, item)
end

insert!(queue::WETQueue{<:WET}, channel::Channel{<:WET}) =
    foreach(item -> insert!(queue, item), channel)

function bestindex(values)
    index = firstindex(values)
    best = first(values)
    for step in Iterators.drop(eachindex(values), 1)
        score(values[step]) < score(best) || continue
        index = step
        best = values[step]
    end
    index
end

function Base.pop!(queue::WETQueue)
    values = queue.heap.valtree
    index = bestindex(values)
    best = values[index]
    deleteat!(values, index)
    isempty(values) || heapify!(values, queue.heap.ordering)
    best
end

best!(queue::WETQueue) = isempty(queue) ? nothing : pop!(queue)

function best(source; capacity=10)
    queue = WETQueue(capacity, eltype(source))
    insert!(queue, source)
    best!(queue)
end
