using Dates
using Test
using HTTP: URI

entry(text, language, score=0.0) = WET(
    MonsieurPapin.Snippet("https://example.com", Val(32)),
    MonsieurPapin.Snippet(text, Val(32)),
    MonsieurPapin.Snippet(language, Val(32)),
    DateTime(2026, 3, 3),
    ncodeunits(text),
    score,
)

@testset "core" begin
    config = Configuration()
    remote = Configuration(; crawlpath=URI("https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"))
    localconfig = Configuration(; crawlpath="data/wet.paths.gz")
    @test string(config.crawlpath) == "https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
    @test remote.crawlpath == URI("https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz")
    @test localconfig.crawlpath == "data/wet.paths.gz"
    @test config.threshold == 0.6
    @test config.vecpath == "minishlab/potion-multilingual-128M"
    @test config.path == "/api/v1/chat"
    @test config.outputpath == "research.md"
    @test isempty(config.languages)
    @test Configuration(; outputpath="notes.md", capacity=3).capacity == 3

    source = Channel{typeof(entry("alpha", "eng"))}(3) do channel
        put!(channel, entry("alpha", "eng"))
        put!(channel, entry("beta", "zho"))
        put!(channel, entry("gamma", "zho,eng"))
    end
    filtered = collect(MonsieurPapin.harvest(Configuration(; capacity=3, languages=["eng"]), source))
    @test map(MonsieurPapin.language, filtered) == ["eng", "zho,eng"]
end
