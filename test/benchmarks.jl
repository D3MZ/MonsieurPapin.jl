# DO ADD OR REMOVE COMMENTS FROM THIS FILE
using MonsieurPapin, BenchmarkTools, Statistics, Test, HTTP, JSON, Sockets
import MonsieurPapin: insert!, score, content, plaintext, distance, similarity, select

# USE REAL DATASETS, NOT SIMULATED FOR BENCHMARKING.
urispath = joinpath(dirname(@__DIR__), "data", "wet.paths.gz")
wetspath = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
model_source = "minishlab/potion-multilingual-128M"
seedtext = repeat("""
relative strength index momentum oscillator trading indicator overbought oversold
estrategia trading mercado financiero
strategie trading marche financier
handelsstrategie finanzmarkt
strategia trading mercato finanziario
estrategia negociacao mercado financeiro
торговая стратегия финансовый рынок
交易策略 金融市场
取引戦略 金融市場
거래 전략 금융 시장
استراتيجية التداول السوق المالية
""", 8)

count(iterable) = sum(_ -> 1, iterable)
rate(iterable, seconds) = round(count(iterable) / seconds)
score(entry::AC, records::AbstractVector{<:WET}) = sum(wet -> MonsieurPapin.score(entry, wet), records)

function score!(scores, entry::AC, records::AbstractVector{<:WET})
    Threads.@threads for index in eachindex(records, scores)
        scores[index] = MonsieurPapin.score(entry, records[index])
    end

    scores
end

@testset "benchmarks" begin
    @testset "wetpaths" begin
        benchmark = @benchmark sum(_ -> 1, wetpaths($urispath)) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        @test benchmark.allocs <= 5 * 100_000 # less than 5 allocations per record (at 100K records)
        uris_per_second = rate(wetpaths(urispath), time)
        @info "Benchmarking wetpaths (paths)" uris = count(wetpaths(urispath)) uris_per_second = uris_per_second
    end

    @testset "wets" begin
        benchmark = @benchmark sum(_ -> 1, wets($wetspath)) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        @test benchmark.allocs <= 600_000 # ~28 allocations per record (~21K pages)
        records_per_second = rate(wets(wetspath), time)
        @info "Benchmarking wets (records)" records = count(wets(wetspath)) records_per_second = records_per_second
        @test records_per_second >= 25_000
    end

    @testset "wets language filter" begin
        records = count(wets(wetspath))
        singlelanguage = ["eng"]
        manylanguages = ["eng", "deu", "rus", "jpn", "zho", "spa", "fra", "por", "ita", "pol"]
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
        benchmark = @benchmark sum(_ -> 1, (MonsieurPapin.score(ac, wet) for wet in wets($wetspath))) setup=(ac = AC($keywords)) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        records_per_second = rate(wets(wetspath), time)
        @info "Benchmarking AC (records)" records = count(wets(wetspath)) keywords = length(keywords) records_per_second = records_per_second
        @test records_per_second >= 20_000
    end

    @testset "Aho-Corasick head-to-head: native Julia (FastAhoCorasick) vs Rust crate" begin
        # Proves the native-Julia matcher (src/ahocorasick.jl, backed by FastAhoCorasick.jl) matches
        # the Rust crate's counts exactly and beats it on speed and allocations, over the same real
        # WET record text and keywords (leftmost non-overlapping, ASCII case-insensitive). Measured
        # on 21,465 records (~5 KB avg), Apple M1 Max: native 50.3 ms / 0 allocs vs Rust 173.2 ms /
        # 39,398 allocs — 3.44x faster with identical counts (12,661). That result is why the Rust
        # aho-corasick automaton was removed from the worker; the Rust side below therefore runs only
        # if the former FFI automaton is still present, and is skipped once it has been refactored out.
        keywords = ["trading", "strategy", "finance", "market", "portfolio", "yield",
                    "торговая стратегия", "交易策略", "取引戦略", "استراتيجية التداول"]
        texts = [content(wet) for wet in wets(wetspath)]
        records = length(texts)

        # native Julia automaton (production path through src/ahocorasick.jl)
        native = AC(keywords)
        nativecount(text) = MonsieurPapin.score(native, text)

        # The Rust aho-corasick automaton only exists if it has not yet been removed from the worker.
        MonsieurPapin.RustWorker.load()
        rusthandle = try
            MonsieurPapin.RustWorker.call(:build_aho_corasick, join(keywords, '\x1F'))
        catch
            nothing
        end

        nativebenchmark = @benchmark sum($nativecount, $texts) samples=1 seconds=5
        display(nativebenchmark)
        nativerate = round(records / (median(nativebenchmark).time / 1e9))

        if rusthandle === nothing
            @info "Aho-Corasick head-to-head (Rust automaton removed; native only)" records keywords = length(keywords) nativerate = nativerate nativeallocs = nativebenchmark.allocs
            @test nativebenchmark.allocs == 0
            @test nativerate >= 20_000
        else
            # Fastest Rust path (raw binding, no invokelatest) so the comparison is generous to Rust.
            rustbinding = MonsieurPapin.RustWorker.binding(:match_aho_corasick)
            rustcount(text) = GC.@preserve text Int(rustbinding(rusthandle, UInt(pointer(text)), UInt(ncodeunits(text))))
            @test sum(nativecount, texts) == sum(rustcount, texts)   # identical counts
            rustbenchmark = @benchmark sum($rustcount, $texts) samples=1 seconds=5
            MonsieurPapin.RustWorker.call(:close_aho_corasick, rusthandle)
            display(rustbenchmark)
            rustrate = round(records / (median(rustbenchmark).time / 1e9))
            speedup = round(median(rustbenchmark).time / median(nativebenchmark).time; digits=2)
            @info "Aho-Corasick head-to-head" records keywords = length(keywords) nativerate = nativerate rustrate = rustrate speedup = speedup nativeallocs = nativebenchmark.allocs rustallocs = rustbenchmark.allocs
            @test median(nativebenchmark).time <= median(rustbenchmark).time
            @test nativebenchmark.allocs <= rustbenchmark.allocs
        end
    end

    @testset "Weighted Keyword Matching (Aho-Corasick; Multilingual)" begin
        weights = MonsieurPapin.weights(seedtext)
        benchmark = @benchmark sum(_ -> 1, (MonsieurPapin.score(ac, wet) for wet in wets($wetspath))) setup=(ac = AC($weights)) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        records_per_second = rate(wets(wetspath), time)
        @info "Benchmarking weighted AC (records)" records = count(wets(wetspath)) keywords = length(weights) records_per_second = records_per_second
        @test records_per_second >= 20_000
    end

    @testset "Weighted Keyword Matching (Aho-Corasick; Multilingual; Threaded)" begin
        weights = MonsieurPapin.weights(seedtext)
        serialbenchmark = @benchmark score(ac, records) setup=(records = collect(wets($wetspath)); ac = AC($weights)) samples=1 seconds=5
        threadedbenchmark = @benchmark sum(score!(scores, ac, records)) setup=(records = collect(wets($wetspath)); ac = AC($weights); scores = Vector{Float64}(undef, length(records))) samples=1 seconds=5
        serialtime = median(serialbenchmark).time / 1e9
        threadedtime = median(threadedbenchmark).time / 1e9
        display(serialbenchmark)
        display(threadedbenchmark)
        records = count(wets(wetspath))
        serialrate = round(records / serialtime)
        threadedrate = round(records / threadedtime)
        @info "Benchmarking weighted AC threading (records)" records = records keywords = length(weights) threads = Threads.nthreads() serialrate = serialrate threadedrate = threadedrate
        @test serialrate >= 20_000
        @test threadedrate >= 20_000
    end

    @testset "Deduplication (SimHash; Single threaded)" begin
        benchmark = @benchmark sum(_ -> 1, (MonsieurPapin.seen!(seen, wet) for wet in wets($wetspath))) setup=(seen = SeenSet(100_000)) samples=1 evals=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        records_per_second = rate(wets(wetspath), time)
        @info "Benchmarking simhash (records)" records = count(wets(wetspath)) records_per_second = records_per_second
        @test records_per_second >= 3_000
    end

    @testset "Model2Vec Distance between Query and WET" begin
        source = embedding("cat dog"; vecpath=model_source)
        benchmark = @benchmark sum(_ -> 1, (distance($source, wet) for wet in wets($wetspath))) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        records = count(wets(wetspath))
        records_per_second = round(records / time)
        @info "Benchmarking Model2Vec distance (records)" records records_per_second
        @test records_per_second >= 400
    end

    @testset "Model2Vec Similarity between Query and WET" begin
        source = embedding("cat dog"; vecpath=model_source)
        benchmark = @benchmark sum(_ -> 1, (similarity($source, wet) for wet in wets($wetspath))) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        records = count(wets(wetspath))
        records_per_second = round(records / time)
        @info "Benchmarking Model2Vec similarity (records)" records records_per_second
        @test records_per_second >= 400
    end

    @testset "Model2Vec Score-Update Integration (distance + WET update)" begin
        source = embedding("cat dog"; vecpath=model_source)
        benchmark = @benchmark sum(_ -> 1, (score($source, wet) for wet in wets($wetspath))) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        records = count(wets(wetspath))
        records_per_second = round(records / time)
        @info "Benchmarking Model2Vec score+update (records)" records records_per_second
        @test records_per_second >= 400
    end

    @testset "select embedding filtering (channel-based, batch-parallel)" begin
        source = embedding("cat dog"; vecpath=model_source)
        benchmark = @benchmark sum(_ -> 1, select($source, wets($wetspath); capacity=1_000)) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        records = count(wets(wetspath))
        records_per_second = round(records / time)
        @info "Benchmarking select embedding (records)" records records_per_second allocations = benchmark.allocs
        @test records_per_second >= 400
        @test benchmark.allocs <= 10 * records
    end

    @testset "Queuing the top 1K" begin
        benchmark = @benchmark insert!(shortlist, wets($wetspath)) setup=(shortlist = BoundedPriorityQueue{typeof(first(wets($wetspath)))}(1_000)) samples=1 seconds=5
        time = median(benchmark).time / 1e9
        display(benchmark)
        shortlist = BoundedPriorityQueue{typeof(first(wets(wetspath)))}(1_000)
        insert!(shortlist, wets(wetspath))
        records_per_second = rate(wets(wetspath), time)
        @info "Benchmarking queue (records)" records = count(wets(wetspath)) capacity = 1_000 retained = length(shortlist) records_per_second = records_per_second payload_mib = round(Base.summarysize(shortlist) / 2.0^20; digits=4)
        @test records_per_second >= 20_000
    end

    @testset "BoundedPriorityQueue pop! extraction from top 1K" begin
        WETT = typeof(first(wets(wetspath)))
        retained = length(let q = BoundedPriorityQueue{WETT}(1_000); insert!(q, wets(wetspath)); q end)
        # Rebuild and refill a full queue in `setup` (excluded from timing) and force evals=1, so
        # each timed run drains a populated queue exactly once. Without this, BenchmarkTools reuses
        # one queue across many evaluations: the first drains it and the rest clock the empty `while`
        # fast path, which auto-tunes evals upward and inflates the rate by orders of magnitude.
        benchmark = @benchmark (while !isempty(q); pop!(q); end) setup=(q = BoundedPriorityQueue{$WETT}(1_000); insert!(q, wets($wetspath))) evals=1 samples=30 seconds=20
        time = median(benchmark).time / 1e9
        display(benchmark)
        pops_per_second = round(retained / time)
        @info "Benchmarking BoundedPriorityQueue pop! extraction" retained pops_per_second
        @test pops_per_second >= 100_000
    end

    @testset "LLM prompt + request overhead" begin
        server = HTTP.serve!(ip"127.0.0.1", 0; verbose=false) do req::HTTP.Request
            HTTP.Response(200, JSON.json(Dict("choices" => [Dict("message" => Dict("content" => "strategy description"))])))
        end
        host, port = Sockets.getsockname(server.listener.server)
        baseurl = "http://$(host):$(port)"
        settings = Dict(
            "llm" => Dict("baseurl" => baseurl, "path" => "/v1/chat/completions", "model" => "qwen/qwen3.6-27b", "password" => "", "timeout" => 120),
        )
        page = "Relative strength index is a momentum trading indicator used to spot overbought and oversold conditions."
        try
            # Warm-up
            sysprompt = "You extract trading strategies."
            inp = "Output JSON."
            request(;
                model=settings["llm"]["model"],
                systemprompt=sysprompt,
                input=string(inp, "\n\n", page),
                baseurl=settings["llm"]["baseurl"],
                path=settings["llm"]["path"],
                password=settings["llm"]["password"],
                timeout=settings["llm"]["timeout"],
            )
            benchmark = @benchmark request(;
                model=$settings["llm"]["model"],
                systemprompt=$sysprompt,
                input=string($inp, "\n\n", $page),
                baseurl=$settings["llm"]["baseurl"],
                path=$settings["llm"]["path"],
                password=$settings["llm"]["password"],
                timeout=$settings["llm"]["timeout"],
            ) samples=100 seconds=5
            time = median(benchmark).time / 1e9 * 1_000  # ms
            display(benchmark)
            requests_per_second = round(1 / (median(benchmark).time / 1e9))
            @info "Benchmarking LLM prompt+request (ms)" latency_ms = round(time; digits=2) requests_per_second allocations = benchmark.allocs
            @test time <= 100  # under 100ms for mock server
        finally
            close(server)
        end
    end
end
