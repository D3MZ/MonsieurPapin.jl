# Julia channel performance
# What's the performance like for unbuffered channels, bounded channels, and threads on put and take operations?
# Performance differences on per-put and per-take for bounded channel or thread size?
# Performance differences on per-put and per-take for isbits and nonisbits types?

# Results
# Channel{T=Any}(sz::Int=0)
# Create a Channel with an internal buffer capable of storing up to sz objects.
# Channel(0) constructs an unbuffered channel. put! on an unbuffered channel blocks until a matching take! is called, and take! blocks until a matching put! occurs.
# Buffered primitive cases were flat across thread count, occupancy, and payload choice.
# Typed channels remove the buffered Payload boxing allocation, but Channel(0) still pays
# rendezvous cost and the Payload case still allocates on the unbuffered path.
# +------------+----------------------+------------+--------+-------+
# | payload    | case                 | median     | allocs | bytes |
# +------------+----------------------+------------+--------+-------+
# | isbits     | channel(n) put!      |   41.000 ns|      0 |     0 |
# | isbits     | channel(n) take!     |   41.000 ns|      0 |     0 |
# | isbits     | channel(0) put!      |   15.792 μs|      0 |     0 |
# | isbits     | channel(0) take!     |   29.584 μs|      0 |     0 |
# | nonisbits  | channel(n) put!      |   42.000 ns|      0 |     0 |
# | nonisbits  | channel(n) take!     |   42.000 ns|      0 |     0 |
# | nonisbits  | channel(0) put!      |   15.833 μs|      0 |     0 |
# | nonisbits  | channel(0) take!     |   29.125 μs|      0 |     0 |
# | payload    | channel(n) put!      |   42.000 ns|      0 |     0 |
# | payload    | channel(n) take!     |   42.000 ns|      0 |     0 |
# | payload    | channel(0) put!      |  105.417 μs|      1 |    32 |
# | payload    | channel(0) take!     |  118.375 μs|      1 |    32 |
# +------------+----------------------+------------+--------+-------+

using BenchmarkTools, Logging

@kwdef struct Payload
    string::String = "I'm a string, therefore making this nonisbits type"
    float::Float64 = 2.34
    int::Int = 3
end 

payload(::Val{:isbits}) = 0
payload(::Val{:nonisbits}) = Ref(0)
payload(::Val{:payload}) = Payload()

seed(::Val{:isbits}, occupancy) = collect(1:occupancy)
seed(::Val{:nonisbits}, occupancy) = Ref.(collect(1:occupancy))
seed(::Val{:payload}, occupancy) = fill(Payload(), occupancy)

label(::Val{:isbits}) = :isbits
label(::Val{:nonisbits}) = :nonisbits
label(::Val{:payload}) = :payload
label(::Val{:put}) = :put
label(::Val{:take}) = :take

channel(::Val{:isbits}, capacity) = Channel{Int}(capacity)
channel(::Val{:nonisbits}, capacity) = Channel{typeof(Ref(0))}(capacity)
channel(::Val{:payload}, capacity) = Channel{Payload}(capacity)

prime!(channel, entries) = foreach(entry -> put!(channel, entry), entries)

occupancy(::Val{:put}, capacity) = unique(filter(level -> level < capacity, (0, 1, capacity ÷ 2, capacity - 1)))
occupancy(::Val{:take}, capacity) = unique(filter(level -> 0 < level <= capacity, (1, 2, capacity ÷ 2, capacity)))

measure(::Val{:put}, kind, ::Val{0}, entry) = @benchmark put!(channel, $entry) setup=(channel = Main.channel($kind, 0); task = Threads.@spawn take!(channel); yield()) teardown=(fetch(task)) evals=1 seconds=0.5
measure(::Val{:take}, kind, ::Val{0}, entry) = @benchmark take!(channel) setup=(channel = Main.channel($kind, 0); task = Threads.@spawn put!(channel, $entry); yield()) teardown=(fetch(task)) evals=1 seconds=0.5

measure(::Val{:put}, kind, ::Val{capacity}, entries, entry) where {capacity} = @benchmark put!(channel, $entry) setup=(channel = Main.channel($kind, $capacity); prime!(channel, $entries)) evals=1 seconds=0.5
measure(::Val{:take}, kind, ::Val{capacity}, entries, entry) where {capacity} = @benchmark take!(channel) setup=(channel = Main.channel($kind, $capacity); prime!(channel, $entries)) evals=1 seconds=0.5

measure(operation::Val, kind, capacity, entry) = measure(operation, kind, Val(capacity), entry)
measure(operation::Val, kind, capacity, entries, entry) = measure(operation, kind, Val(capacity), entries, entry)

cases(capacities, operations) = sum(capacity == 0 ? 1 : length(occupancy(operation, capacity)) for operation in operations, capacity in capacities)

run(capacities=(0, 1, 64, 1024, 4096, 8192), payloads=(Val(:isbits), Val(:nonisbits), Val(:payload)), operations=(Val(:put), Val(:take))) = begin
    total = length(payloads) * cases(capacities, operations)
    @info "Channel benchmarks" threads=Threads.nthreads() capacities=collect(capacities) cases=total

    for kind in payloads
        entry = payload(kind)
        for operation in operations
            for capacity in capacities
                if capacity == 0
                    @info "Benchmark" payload=label(kind) operation=label(operation) capacity occupancy=:rendezvous
                    display(measure(operation, kind, capacity, entry))
                    continue
                end

                for level in occupancy(operation, capacity)
                    @info "Benchmark" payload=label(kind) operation=label(operation) capacity occupancy=level
                    display(measure(operation, kind, capacity, seed(kind, level), entry))
                end
            end
        end
    end
end

run()
