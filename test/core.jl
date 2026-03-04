using Test
using HTTP: URI

@testset "core" begin
    config = Configuration()
    remote = Configuration(; crawlpath=URI("https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"))
    localconfig = Configuration(; crawlpath="data/wet.paths.gz")
    @test string(config.crawlpath) == "https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
    @test remote.crawlpath == URI("https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz")
    @test localconfig.crawlpath == "data/wet.paths.gz"
    @test config.capacity == 10
    @test config.threshold == 0.6
    @test config.vecpath == "data/wiki-news-300d-1M.vec"
    @test config.path == "/api/v1/chat"
    @test config.outputpath == "research.md"
    @test Configuration(; outputpath="notes.md", capacity=3).capacity == 3
end
