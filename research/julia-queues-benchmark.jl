# Julia queue performance
# What's the performance like for maintaining a size-100 queue while 10K elements are inserted?
# How much does a precheck save versus always inserting and popping the worst?
# What happens to allocations and cost once a lock is added for the same workload?
# How much does a full `WET` payload change the maintenance cost relative to plain `Float64` scores?
#
# Results
# Maintaining a size-100 `BinaryMinMaxHeap` across 10K inserts stayed allocation-free for `Float64`.
# For that scalar case, checking `value < maximum(heap)` first was much cheaper than always pushing
# and then popping the worst element, and the locked precheck path stayed under a third of the
# unconditional insert/pop cost.
# The full `WET` payload changed the picture: the same workload was still faster with precheck than
# always insert/pop, but comparisons and heap maintenance now allocated noticeably because the payload
# is a nonisbits mutable struct rather than a scalar score.
# +-------------------------+--------------+--------+-----------+
# | payload / case          | median       | allocs | bytes     |
# +-------------------------+--------------+--------+-----------+
# | distance precheck       |   90.167 us  | 0      | 0         |
# | distance always         |  762.895 us  | 0      | 0         |
# | distance locked         |  224.166 us  | 0      | 0         |
# | wet precheck            |  169.583 us  | 6434   | 201.06 KiB|
# | wet always              |    1.706 ms  | 130189 | 3.97 MiB  |
# | wet locked              |  305.208 us  | 6434   | 201.06 KiB|
# +-------------------------+--------------+--------+-----------+

using BenchmarkTools, DataStructures, Logging, Random, Dates
using HTTP: URI
using MonsieurPapin: WET

Base.isless(first::WET, second::WET) = isless(first.score, second.score)

seed(::Val{:distance}, limit) = rand(MersenneTwister(1), limit)
entries(::Val{:distance}, count) = rand(MersenneTwister(2), count)

seed(::Val{:wet}, limit) = payloads(limit, MersenneTwister(1))
entries(::Val{:wet}, count) = payloads(count, MersenneTwister(2))

label(::Val{:distance}) = :distance
label(::Val{:wet}) = :wet
label(::Val{:precheck}) = :precheck
label(::Val{:always}) = :always
label(::Val{:locked_precheck}) = :locked_precheck

function payloads(count, generator)
    [WET(
        URI("https://example.com/$(index)"),
        DateTime(2026, 3, 3),
        "en",
        64,
        "content $(index)",
        rand(generator),
    ) for index in 1:count]
end

function frontier(kind, limit)
    heap = BinaryMinMaxHeap{eltype(seed(kind, 1))}()
    foreach(value -> push!(heap, value), seed(kind, limit))
    heap
end

function insert!(heap, value, limit, ::Val{:precheck})
    length(heap) < limit && return push!(heap, value)
    value < maximum(heap) || return heap
    popmax!(heap)
    push!(heap, value)
end

function insert!(heap, value, limit, ::Val{:always})
    push!(heap, value)
    length(heap) > limit && popmax!(heap)
    heap
end

maintain!(heap, values, limit, kind) = foreach(value -> insert!(heap, value, limit, kind), values)

function maintain!(heap, values, gate::ReentrantLock, limit)
    foreach(values) do value
        lock(gate) do
            insert!(heap, value, limit, Val(:precheck))
        end
    end
end

measure(payload, limit, values, ::Val{:precheck}) = @benchmark maintain!(heap, $values, $limit, $(Val(:precheck))) setup=(heap = Main.frontier($payload, $limit)) evals=1 seconds=0.5
measure(payload, limit, values, ::Val{:always}) = @benchmark maintain!(heap, $values, $limit, $(Val(:always))) setup=(heap = Main.frontier($payload, $limit)) evals=1 seconds=0.5
measure(payload, limit, values, ::Val{:locked_precheck}) = @benchmark maintain!(heap, $values, gate, $limit) setup=(heap = Main.frontier($payload, $limit); gate = ReentrantLock()) evals=1 seconds=0.5

cases() = (
    Val(:precheck),
    Val(:always),
    Val(:locked_precheck),
)

function run(limit=100, count=10_000, payloads=(Val(:distance), Val(:wet)))
    total = length(cases()) * length(payloads)
    @info "Queue benchmarks" threads=Threads.nthreads() limit count payloads=map(label, payloads) cases=total

    for payload in payloads
        values = entries(payload, count)
        for kind in cases()
            @info "Benchmark" payload=label(payload) limit count operation=label(kind)
            display(measure(payload, limit, values, kind))
        end
    end
end

run()
