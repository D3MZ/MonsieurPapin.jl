# DO ADD OR REMOVE COMMENTS FROM THIS FILE
using MonsieurPapin, BenchmarkTools, Statistics, Test
import MonsieurPapin: insert!, score, content, gettext, distance

# USE REAL DATASETS, NOT SIMULATED FOR BENCHMARKING.
urispath = joinpath(dirname(@__DIR__), "data", "wet.paths.gz")
wetspath = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
model_source = "minishlab/potion-multilingual-128M"

count(iterable) = sum(_ -> 1, iterable)
rate(iterable, seconds) = round(count(iterable) / seconds)

@testset "benchmarks" begin
    @testset "wetURIs" begin
        benchmark = @benchmark sum(_ -> 1, wetURIs($urispath)) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        @test benchmark.allocs <= 5 * 100_000 # less than 5 allocations per record (at 100K records)
        uris_per_second = rate(wetURIs(urispath), time)
        @info "Benchmarking wetURIs (paths)" uris = count(wetURIs(urispath)) uris_per_second = uris_per_second
    end

    @testset "wets" begin
        benchmark = @benchmark sum(_ -> 1, wets($wetspath)) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        @test benchmark.allocs <= 75_000 # less than 3 allocations per record (~24K pages)
        records_per_second = rate(wets(wetspath), time)
        @info "Benchmarking wets (records)" records = count(wets(wetspath)) records_per_second = records_per_second
        @test records_per_second >= 25_000
    end

    @testset "wets language filter" begin
        records = count(wets(wetspath))
        singlelanguage = ["eng"]
        manylanguages = Configuration().languages
        emittedsingle = count(wets(wetspath; languages=singlelanguage))
        emittedmany = count(wets(wetspath; languages=manylanguages))
        singlebenchmark = @benchmark sum(_ -> 1, wets($wetspath; languages=$singlelanguage)) samples=1 seconds=5
        manybenchmark = @benchmark sum(_ -> 1, wets($wetspath; languages=$manylanguages)) samples=1 seconds=5
        singletime = median(singlebenchmark).time / 1e9
        manytime = median(manybenchmark).time / 1e9
        singlerate = round(records / singletime)
        manyrate = round(records / manytime)
        display(singlebenchmark)
        display(manybenchmark)
        @info "Benchmarking wets language filter" records = records emittedsingle = emittedsingle emittedmany = emittedmany singlelanguage = first(singlelanguage) singlerate = singlerate languagecount = length(manylanguages) manyrate = manyrate
        @test singlerate > manyrate
        @test singlebenchmark.allocs <= manybenchmark.allocs
    end

    @testset "Keyword Matching (Aho-Corasick; Multilingual)" begin
        keywords = [
            "trading",
            "strategy",
            "finance",
            "market",
            "portfolio",
            "yield",
            "estrategia de trading",
            "mercado financiero",
            "strategie de trading",
            "marche financier",
            "handelsstrategie",
            "finanzmarkt",
            "strategia di trading",
            "mercato finanziario",
            "estrategia de negociacao",
            "mercado financeiro",
            "торговая стратегия",
            "финансовый рынок",
            "交易策略",
            "金融市场",
            "取引戦略",
            "金融市場",
            "거래 전략",
            "금융 시장",
            "استراتيجية التداول",
            "السوق المالية",
        ]
        benchmark = @benchmark sum(_ -> 1, (MonsieurPapin.RustWorker.score(ac, wet) for wet in wets($wetspath))) setup=(ac = AC($keywords)) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        records_per_second = rate(wets(wetspath), time)
        @info "Benchmarking AC (records)" records = count(wets(wetspath)) keywords = length(keywords) records_per_second = records_per_second
        @test records_per_second >= 20_000
    end

    @testset "Deduplication (SimHash; Single threaded)" begin
        benchmark = @benchmark sum(_ -> 1, (isduplicate(deduper, wet) for wet in wets($wetspath))) setup=(deduper = Deduper(100_000)) samples=1 evals=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        records_per_second = rate(wets(wetspath), time)
        @info "Benchmarking simhash (records)" records = count(wets(wetspath)) records_per_second = records_per_second
        @test records_per_second >= 3_000
    end

    @testset "Multilingual Distance between Query and WET" begin
        benchmark = @benchmark sum(_ -> 1, (score(source, wet) for wet in wets($wetspath))) setup=(source = embedding("cat dog"; vecpath=model_source)) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        records_per_second = rate(wets(wetspath), time)
        @info "Benchmarking relevant! (records)" records_per_second = records_per_second
        @test records_per_second >= 400
    end

    @testset "Queuing the top 1K" begin
        benchmark = @benchmark insert!(queue, wets($wetspath)) setup=(queue = WETQueue(1_000, typeof(first(wets($wetspath))))) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        queue = WETQueue(1_000, typeof(first(wets(wetspath))))
        insert!(queue, wets(wetspath))
        records_per_second = rate(wets(wetspath), time)
        @info "Benchmarking queue (records)" records = count(wets(wetspath)) capacity = 1_000 retained = length(queue) records_per_second = records_per_second payload_mib = round(Base.summarysize(queue.heap) / 2.0^20; digits=4)
        @test records_per_second >= 20_000
    end
end
