using Test

@testset "core" begin
    research = Configuration()
    @test research.crawlpath == "https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
    @test research.path == "/api/v1/chat"
    @test research.outputpath == "research.md"
    @test Configuration(; maxpages=3, outputpath="notes.md").maxpages == 3
end
