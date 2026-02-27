# Julia channel performance
# What's the performance like for unbuffered channels, bounded channels, and threads on put and take operations?
# Performance differences on per-put and per-take for bounded channel or thread size?
# Performance differences on per-put and per-take for isbits and nonisbits types?

# Results
# Buffered primitive cases were flat across thread count, occupancy, and payload choice.
# Channel(0) remains ~376x-749x slower than the buffered ~41-42 ns cases because each
# successful transfer is a rendezvous with handoff / wakeup / scheduling cost.
# +------------+------------------+-----------+--------+-------+
# | payload    | case             | median    | allocs | bytes |
# +------------+------------------+-----------+--------+-------+
# | isbits     | buffered put!    | 42.000 ns | 0      | 0     |
# | isbits     | buffered take!   | 41.000 ns | 0      | 0     |
# | isbits     | channel0 put!    | 16.042 us | 0      | 0     |
# | isbits     | channel0 take!   | 30.709 us | 0      | 0     |
# | nonisbits  | buffered put!    | 42.000 ns | 0      | 0     |
# | nonisbits  | buffered take!   | 41.000 ns | 0      | 0     |
# | nonisbits  | channel0 put!    | 15.792 us | 0      | 0     |
# | nonisbits  | channel0 take!   | 30.833 us | 0      | 0     |
# | payload    | buffered put!    | 42.000 ns | 1      | 32    |
# | payload    | buffered take!   | 41.000 ns | 0      | 0     |
# | payload    | channel0 put!    | 15.834 us | 1      | 32    |
# | payload    | channel0 take!   | 29.666 us | 1      | 32    |
# +------------+------------------+-----------+--------+-------+

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

prime!(channel, entries) = foreach(entry -> put!(channel, entry), entries)

occupancy(::Val{:put}, capacity) = unique(filter(level -> level < capacity, (0, 1, capacity ÷ 2, capacity - 1)))
occupancy(::Val{:take}, capacity) = unique(filter(level -> 0 < level <= capacity, (1, 2, capacity ÷ 2, capacity)))

measure(::Val{:put}, ::Val{0}, entry) = @benchmark put!(channel, $entry) setup=(channel = Channel(0); task = Threads.@spawn take!(channel); yield()) teardown=(fetch(task)) evals=1 seconds=0.5
measure(::Val{:take}, ::Val{0}, entry) = @benchmark take!(channel) setup=(channel = Channel(0); task = Threads.@spawn put!(channel, $entry); yield()) teardown=(fetch(task)) evals=1 seconds=0.5

measure(::Val{:put}, ::Val{capacity}, entries, entry) where {capacity} = @benchmark put!(channel, $entry) setup=(channel = Channel($capacity); prime!(channel, $entries)) evals=1 seconds=0.5
measure(::Val{:take}, ::Val{capacity}, entries, entry) where {capacity} = @benchmark take!(channel) setup=(channel = Channel($capacity); prime!(channel, $entries)) evals=1 seconds=0.5

measure(operation::Val, capacity, entry) = measure(operation, Val(capacity), entry)
measure(operation::Val, capacity, entries, entry) = measure(operation, Val(capacity), entries, entry)

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
                    display(measure(operation, capacity, entry))
                    continue
                end

                for level in occupancy(operation, capacity)
                    @info "Benchmark" payload=label(kind) operation=label(operation) capacity occupancy=level
                    display(measure(operation, capacity, seed(kind, level), entry))
                end
            end
        end
    end
end

run()
