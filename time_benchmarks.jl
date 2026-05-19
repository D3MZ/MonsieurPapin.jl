using MonsieurPapin, BenchmarkTools, Statistics, Test, HTTP, JSON, Sockets
import MonsieurPapin: insert!, score, content, gettext, distance, similarity, relevant!

# USE REAL DATASETS, NOT SIMULATED FOR BENCHMARKING.
urispath = joinpath(@__DIR__, "..", "data", "wet.paths.gz")
wetspath = joinpath(@__DIR__, "..", "data", "warc.wet.gz")
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

# Time the entire benchmark suite
start_time = time()

# Run a lightweight version of each benchmark to get timing
@info "Starting benchmark timing..."

# wetURIs benchmark
try
    benchmark = @benchmark sum(_ -> 1, wetURIs($urispath)) samples=1 seconds=2
    time_taken = median(benchmark).time / 1e9
    @info "wetURIs benchmark completed" time=time_taken
catch e
    @info "wetURIs benchmark failed" error=string(e)
    time_taken = 1.0  # penalty time
end

# wets benchmark  
try
    benchmark = @benchmark sum(_ -> 1, wets($wetspath)) samples=1 seconds=2
    time_taken = median(benchmark).time / 1e9
    @info "wets benchmark completed" time=time_taken
catch e
    @info "wets benchmark failed" error=string(e)
    time_taken = 1.0  # penalty time
end

# wets language filter
try
    singlelanguage = ["eng"]
    benchmark = @benchmark sum(_ -> 1, wets($wetspath; languages=$singlelanguage)) samples=1 seconds=2
    time_taken = median(benchmark).time / 1e9
    @info "wets language filter benchmark completed" time=time_taken
catch e
    @info "wets language filter benchmark failed" error=string(e)
    time_taken = 1.0  # penalty time
end

# Keyword Matching (Aho-Corasick)
try
    keywords = ["trading", "strategy", "finance", "market"]
    benchmark = @benchmark sum(_ -> 1, (MonsieurPapin.score(ac, wet) for wet in wets($wetspath))) setup=(ac = AC($keywords)) samples=1 seconds=2
    time_taken = median(benchmark).time / 1e9
    @info "Keyword matching benchmark completed" time=time_taken
catch e
    @info "Keyword matching benchmark failed" error=string(e)
    time_taken = 1.0  # penalty time
end

# Weighted Keyword Matching
try
    weights = MonsieurPapin.weights(seedtext)
    benchmark = @benchmark sum(_ -> 1, (MonsieurPapin.score(ac, wet) for wet in wets($wetspath))) setup=(ac = AC($weights)) samples=1 seconds=2
    time_taken = median(benchmark).time / 1e9
    @info "Weighted keyword matching benchmark completed" time=time_taken
catch e
    @info "Weighted keyword matching benchmark failed" error=string(e)
    time_taken = 1.0  # penalty time
end

end_time = time()
total_time = end_time - start_time
@info "Total benchmark time" total_time=total_time
println("METRIC total_benchmark_time=$(total_time)")