using BenchmarkTools
using DataStructures
using Dates
using MonsieurPapin
using Test

always!(heap, value, capacity) = (push!(heap, value); length(heap) > capacity && popmax!(heap); heap)
maintainalways!(heap, values, capacity) = foreach(value -> always!(heap, value, capacity), values)
scores(count, offset=0) = [mod(1_664_525 * (index + offset) + 1_013_904_223, 2^31) / 2.0^31 for index in 1:count]

queued(score) = WET(
    MonsieurPapin.Snippet{1}((0x61,), 1),
    MonsieurPapin.Snippet{1}((0x61,), 1),
    DateTime(2026, 3, 4),
    1,
    score,
)

@testset "queue" begin
    entries = frontier(2, typeof(queued(0.0)))
    drain!(entries, queued.([0.9, 0.4, 0.1, 0.3]))
    @test length(entries) == 2
    @test best!(entries).score == 0.1
    @test best!(entries).score == 0.3
    @test isnothing(best!(entries))

    source = Channel{typeof(queued(0.0))}(4) do channel
        foreach(score -> put!(channel, queued(score)), [0.9, 0.4, 0.1, 0.3])
    end
    @test best(source; capacity=2).score == 0.1

    capacity = 100
    seed = scores(capacity)
    values = scores(10_000, capacity)
    checked = frontier(capacity, Float64)
    drain!(checked, seed)
    @test @allocations(drain!(checked, values)) == 0

    if get(ENV, "MONSIEURPAPIN_BENCHMARK", "false") == "true"
        checkedtrial = @benchmark begin
            entries = frontier($capacity, Float64)
            drain!(entries, $seed)
            drain!(entries, $values)
        end evals = 1 seconds = 0.5

        alwaystrial = @benchmark begin
            heap = BinaryMinMaxHeap{Float64}()
            foreach(value -> push!(heap, value), $seed)
            maintainalways!(heap, $values, $capacity)
        end evals = 1 seconds = 0.5

        @test BenchmarkTools.median(checkedtrial).time < BenchmarkTools.median(alwaystrial).time
    end
end
