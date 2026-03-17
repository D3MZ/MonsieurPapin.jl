using BenchmarkTools
using Base.Order: By, ReverseOrdering
using Dates
using MonsieurPapin
using Test
import MonsieurPapin: insert!

queued(value) = WET(
    MonsieurPapin.Snippet{1}((0x61,), 1),
    MonsieurPapin.Snippet{1}((0x61,), 1),
    MonsieurPapin.Snippet{3}((0x65, 0x6e, 0x67), 3),
    DateTime(2026, 3, 4),
    1,
    value,
)

@testset "queue" begin
    queue = WETQueue(2, typeof(queued(0.0)))
    source = Channel{typeof(queued(0.0))}(4) do channel
        foreach([0.9, 0.4, 0.1, 0.3]) do value
            put!(channel, queued(value))
        end
    end
    insert!(queue, source)
    @test length(queue) == 2
    @test best!(queue).score == 0.1
    @test best!(queue).score == 0.3
    @test isnothing(best!(queue))

    source = Channel{typeof(queued(0.0))}(4) do channel
        foreach([0.9, 0.4, 0.1, 0.3]) do value
            put!(channel, queued(value))
        end
    end
    @test best(source; capacity=2).score == 0.1

    queue = WETQueue(2, typeof(queued(0.0)))
    source = Channel{typeof(queued(0.0))}(2) do channel
        foreach([0.9, 0.4]) do value
            put!(channel, queued(value))
        end
    end
    insert!(queue, source)
    @test first(queue.heap).score == 0.9
    @test @allocations(insert!(queue, queued(1.1))) == 0
    @test length(queue) == 2
    @test first(queue.heap).score == 0.9

    @test @allocations(insert!(queue, queued(0.1))) == 0
    @test length(queue) == 2
    @test best!(queue).score == 0.1
    @test best!(queue).score == 0.4
    @test isnothing(best!(queue))

    queue = WETQueue(2, typeof(queued(0.0)), ReverseOrdering(By(MonsieurPapin.score)))
    source = Channel{typeof(queued(0.0))}(4) do channel
        foreach([0.9, 0.4, 0.1, 0.3]) do value
            put!(channel, queued(value))
        end
    end
    insert!(queue, source)
    @test length(queue) == 2
    @test best!(queue).score == 0.9
    @test best!(queue).score == 0.4
    @test isnothing(best!(queue))
end
