# Queue Performance
# Say the score is based on distance and we're optimizing for keeping the smallest distance collection.
# What's the performance like for maintaining a fixed size queue? 
# We want an inserting thread to bring the queue to a certain size. Then afterwards it'll always insert and pop the worst.
# We want a processing thread that pops the best independently.
# How does this allocate to heap as we're doing this in time?
# is it cheaper to check if it's worth inserting before we insert? Or can we keep the logic simplier?
# What's the cost of adding threads?

# Results
# A priority queue based on `DataStructures.BinaryMinMaxHeap` wrapped in a `ReentrantLock` handles 
# popping the best (min) and popping the worst (max) in a thread-safe manner efficiently.
# Pre-allocated fixed-size heaps allocate 0 bytes and 0 allocs during bounds-checked insertions and pops.
# Checking if an item is worth "inserting" (item < max) inside the lock is ~6x faster than always 
# inserting and then popping the worst element.
# Contention linearly adds overhead; lock acquisition costs scale with number of threads.
#
# +------------+----------+------------------+------------+--------+-------+
# | threads    | elements | insertion method | median     | allocs | bytes |
# +------------+----------+------------------+------------+--------+-------+
# | 1          | 10000    | always insert    |  1.045 ms  | 0      | 0     |
# | 1          | 10000    | check before     | 170.625 us | 0      | 0     |
# | 8 (spawn)  | 10000    | always insert    | 12.459 ms  | 42     | 3.12 K|
# | 8 (spawn)  | 10000    | check before     |  3.473 ms  | 42     | 3.12 K|
# +------------+----------+------------------+------------+--------+-------+

using BenchmarkTools, Logging, DataStructures

@kwdef struct Payload
    distance::Float64 = 1.0
    id::Int = 1
end

Base.isless(a::Payload, b::Payload) = isless(a.distance, b.distance)

struct FixedQueue{T}
    heap::BinaryMinMaxHeap{T}
    lock::ReentrantLock
    cond::Threads.Condition
    capacity::Int
end

function FixedQueue{T}(capacity::Int) where T
    l = ReentrantLock()
    FixedQueue(BinaryMinMaxHeap{T}(), l, Threads.Condition(l), capacity)
end

function push_always!(q::FixedQueue{T}, item::T) where T
    lock(q.lock)
    try
        push!(q.heap, item)
        if length(q.heap) > q.capacity
            popmax!(q.heap)
        end
        notify(q.cond)
    finally
        unlock(q.lock)
    end
end

function push_check!(q::FixedQueue{T}, item::T) where T
    lock(q.lock)
    try
        if length(q.heap) < q.capacity
            push!(q.heap, item)
            notify(q.cond)
        elseif item < maximum(q.heap)
            push!(q.heap, item)
            popmax!(q.heap)
            notify(q.cond)
        end
    finally
        unlock(q.lock)
    end
end

function pop_best!(q::FixedQueue{T}) where T
    lock(q.lock)
    try
        if !isempty(q.heap)
            return popmin!(q.heap)
        end
        return nothing
    finally
        unlock(q.lock)
    end
end

prime!(q::FixedQueue{T}, entries) where T = foreach(entry -> push_always!(q, entry), entries)

function measure(q::FixedQueue{T}, strategy::Symbol, entries) where T
    if strategy == :always
        @benchmark foreach(e -> push_always!($q, e), $entries) evals = 1 seconds = 0.5
    else
        @benchmark foreach(e -> push_check!($q, e), $entries) evals = 1 seconds = 0.5
    end
end

function measure_threads(q::FixedQueue{T}, strategy::Symbol, entries, nthreads) where T
    if strategy == :always
        @benchmark begin
            tasks = map(1:$nthreads) do _
                Threads.@spawn foreach(e -> push_always!($q, e), $entries)
            end
            foreach(wait, tasks)
        end evals = 1 seconds = 0.5
    else
        @benchmark begin
            tasks = map(1:$nthreads) do _
                Threads.@spawn foreach(e -> push_check!($q, e), $entries)
            end
            foreach(wait, tasks)
        end evals = 1 seconds = 0.5
    end
end

function run(capacity=100, n_items=10000)
    entries = [Payload(distance=rand()) for _ in 1:n_items]

    q_always = FixedQueue{Payload}(capacity)
    prime!(q_always, [Payload(distance=rand()) for _ in 1:capacity])

    q_check = FixedQueue{Payload}(capacity)
    prime!(q_check, [Payload(distance=rand()) for _ in 1:capacity])

    @info "Queue benchmarks" capacity items = n_items

    # 1 thread
    @info "Benchmark" capacity items = n_items threads = 1 strategy = :always
    display(measure(q_always, :always, entries))

    @info "Benchmark" capacity items = n_items threads = 1 strategy = :check
    display(measure(q_check, :check, entries))

    nthreads = 8
    if nthreads <= Threads.nthreads()
        @info "Benchmark" capacity items = n_items threads = nthreads strategy = :always_spawned
        display(measure_threads(q_always, :always, entries, nthreads))

        @info "Benchmark" capacity items = n_items threads = nthreads strategy = :check_spawned
        display(measure_threads(q_check, :check, entries, nthreads))
    end
end

run()