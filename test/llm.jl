using BenchmarkTools
using Dates
using MonsieurPapin
using Test

struct StubLLM
    output::String
end

MonsieurPapin.complete(::AbstractString, llm::StubLLM) = llm.output

page(text, score=0.0) = WET(
    MonsieurPapin.snippet("https://example.com", Val(32)),
    MonsieurPapin.snippet(text, Val(32)),
    DateTime(2026, 3, 3),
    ncodeunits(text),
    score,
)

sample() = Channel{typeof(page("kitten dog"))}(2) do channel
    put!(channel, page("kitten dog", 0.1))
    put!(channel, page("banana", 0.9))
end

@testset "llm" begin
    stub = StubLLM("```text\nstrategy\n```\n")
    @test complete("anything", stub) == stub.output

    outputpath = tempname()
    config = Configuration(; outputpath, capacity=2)
    @test MonsieurPapin.report(config, sample(), stub) == outputpath
    @test occursin("strategy", read(outputpath, String))

    if get(ENV, "MONSIEURPAPIN_BENCHMARK", "false") == "true"
        path = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
        documents = wets(path)
        source = embedding("trading strategy"; vecpath="test/data/fasttext.vec")
        filtered = relevant!(source, documents; threshold=0.0)
        config = Configuration(; outputpath=tempname(), capacity=10)
        display(@benchmark MonsieurPapin.report($config, $filtered, $stub) samples=1 evals=1 seconds=60)
    end
end
