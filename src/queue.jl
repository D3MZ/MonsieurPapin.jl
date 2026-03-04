Base.isless(first::WET, second::WET) = isless(first.score, second.score)

struct Frontier{Value}
    heap::BinaryMinMaxHeap{Value}
    capacity::Int
end

frontier(capacity::Int, ::Type{Value}) where {Value} = Frontier(BinaryMinMaxHeap{Value}(), capacity)

Base.length(entries::Frontier) = length(entries.heap)
Base.isempty(entries::Frontier) = isempty(entries.heap)

function insert!(entries::Frontier{Value}, item::Value) where {Value}
    length(entries) < entries.capacity && return push!(entries.heap, item)
    item < maximum(entries.heap) || return entries.heap
    popmax!(entries.heap)
    push!(entries.heap, item)
end

drain!(entries::Frontier{Value}, source) where {Value} = foreach(item -> insert!(entries, item), source)

best!(entries::Frontier) = isempty(entries) ? nothing : popmin!(entries.heap)

function best(source; capacity=10)
    entries = frontier(capacity, eltype(source))
    drain!(entries, source)
    best!(entries)
end

function best(pages::Wets; capacity=10)
    item = best(pages.entries; capacity)
    isnothing(item) ? nothing : (pages=pages, wet=item)
end
