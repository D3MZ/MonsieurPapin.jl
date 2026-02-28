using MonsieurPapin
using Test

@testset "MonsieurPapin.jl" begin
    path = joinpath(@__DIR__, "data", "wet.paths.gz")
    channel = wetURIs(path)
    allocs = @allocations first(channel)
    @test allocs == 1
end