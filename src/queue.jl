using Base.Order: By, ReverseOrdering, lt
using DataStructures: heapify!

struct WETQueue{Value, Ranking<:Base.Ordering, HeapOrdering<:Base.Ordering}
    heap::BinaryHeap{Value, HeapOrdering}
    capacity::Int
    ranking::Ranking
end

score(wet::WET) = wet.score

function WETQueue(capacity::Int, ::Type{Value}, ranking::Ranking=By(score)) where {Value<:WET, Ranking<:Base.Ordering}
    WETQueue(BinaryHeap{Value}(ReverseOrdering(ranking)), capacity, ranking)
end

Base.length(queue::WETQueue) = length(queue.heap)
Base.isempty(queue::WETQueue) = isempty(queue.heap)
Base.eltype(::WETQueue{Value}) where {Value} = Value
isfull(queue::WETQueue) = length(queue) >= queue.capacity
better(queue::WETQueue, left::WET, right::WET) = lt(queue.ranking, left, right)

function insert!(queue::WETQueue{<:WET}, item::WET)
    !isfull(queue) && return push!(queue.heap, item)
    better(queue, item, first(queue.heap)) || return queue.heap
    pop!(queue.heap)
    push!(queue.heap, item)
end

insert!(queue::WETQueue{<:WET}, channel::Channel{<:WET}) =
    foreach(item -> insert!(queue, item), channel)

function Base.pop!(queue::WETQueue)
    values = queue.heap.valtree
    index = firstindex(values)
    best = first(values)
    for step in Iterators.drop(eachindex(values), 1)
        lt(queue.ranking, values[step], best) || continue
        index = step
        best = values[step]
    end
    deleteat!(values, index)
    isempty(values) || heapify!(values, queue.heap.ordering)
    best
end

best!(queue::WETQueue) = isempty(queue) ? nothing : pop!(queue)

function best(source; capacity=10, ranking=By(score))
    queue = WETQueue(capacity, eltype(source), ranking)
    insert!(queue, source)
    best!(queue)
end
