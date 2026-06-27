using Base.Order: Reverse
using Dates
using MonsieurPapin
using Test
using MonsieurPapin: insert!

queued(value) = WET(
    MonsieurPapin.Snippet{1}((0x61,), 1),
    MonsieurPapin.Snippet{1}((0x61,), 1),
    MonsieurPapin.Snippet{3}((0x65, 0x6e, 0x67), 3),
    DateTime(2026, 3, 4),
    1,
    value,
)

source(values) = Channel{typeof(queued(0.0))}(length(values)) do channel
    foreach(value -> put!(channel, queued(value)), values)
end

@testset "queue" begin
    # Forward (default): keep the lowest scores, extract best (lowest) first.
    shortlist = BoundedPriorityQueue{typeof(queued(0.0))}(2)
    insert!(shortlist, source([0.9, 0.4, 0.1, 0.3]))
    @test length(shortlist) == 2
    @test pop!(shortlist).score == 0.1
    @test pop!(shortlist).score == 0.3
    @test isnothing(pop!(shortlist))

    # Eviction: a worse item is ignored, a better item displaces the worst.
    shortlist = BoundedPriorityQueue{typeof(queued(0.0))}(2)
    insert!(shortlist, source([0.9, 0.4]))
    @test length(shortlist) == 2
    insert!(shortlist, queued(1.1))
    @test length(shortlist) == 2
    insert!(shortlist, queued(0.1))
    @test length(shortlist) == 2
    @test pop!(shortlist).score == 0.1
    @test pop!(shortlist).score == 0.4
    @test isnothing(pop!(shortlist))

    # Reverse: keep the highest scores, extract best (highest) first.
    shortlist = BoundedPriorityQueue{typeof(queued(0.0))}(2, Reverse)
    insert!(shortlist, source([0.9, 0.4, 0.1, 0.3]))
    @test length(shortlist) == 2
    @test pop!(shortlist).score == 0.9
    @test pop!(shortlist).score == 0.4
    @test isnothing(pop!(shortlist))

    # Concurrent pipe: put!/take! drain best-first and stop cleanly once closed.
    shortlist = BoundedPriorityQueue{typeof(queued(0.0))}(3)
    foreach(value -> put!(shortlist, queued(value)), [0.5, 0.2, 0.8])
    close(shortlist)
    @test map(w -> w.score, collect(shortlist)) == [0.2, 0.5, 0.8]
end
