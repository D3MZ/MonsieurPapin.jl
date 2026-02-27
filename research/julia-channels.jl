# Julia channel performance
# What's the performance like for unbuffered channels, bounded channels, and threads on put and take operations?
# Performance differences on per-put and per-take for bounded channel or thread size?
# Performance differences on per-put and per-take for isbits and nonisbits types?

# Results
# For the current buffered primitive benchmark, thread count, occupancy, and payload type
# had no meaningful effect.
# Unbuffered Channel(0) is ~500x slower than the buffered ~40 ns cases because
# every successful transfer requires both sides to complete each rendezvous, including handoff /
# wakeup / scheduling costs.
# Buffered isbits put!: ~42 ns
# Buffered isbits take!: ~41 ns
# Buffered nonisbits put!: ~42 ns
# Buffered nonisbits take!: ~41 ns
# Buffered payload put!: ~42 ns
# Buffered payload take!: ~41 ns
# Channel(0) rendezvous from put! side, isbits: ~15.792 us
# Channel(0) rendezvous from take! side, isbits: ~29.875 us
# Channel(0) rendezvous from put! side, nonisbits: ~15.792 us
# Channel(0) rendezvous from take! side, nonisbits: ~29.875 us
# Channel(0) rendezvous from put! side, payload: ~15.833 us
# Channel(0) rendezvous from take! side, payload: ~30.750 us

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
