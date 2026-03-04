Base.@kwdef struct Configuration
    crawlpath = URI("https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz")
    crawlroot::String = "https://data.commoncrawl.org/"
    capacity::Int = 10
    threshold::Float64 = 0.6
    vecpath::String = "data/wiki-news-300d-1M.vec"
    previewseconds::Float64 = 8.0
    query::String = "It doesn’t really matter which component you find first, the price action signal or the level. What matters is if the two have come together to form a confluent price action trade. When you have an obvious price action signal, like a pin bar or a fakey signal, and that signal has formed at a key horizontal level of support or resistance in a market, you have a potentially very high-probability trade on your hands."
    baseurl::String = "http://localhost:1234"
    path::String = "/api/v1/chat"
    model::String = "qwen/qwen3.5-35b-a3b"
    password::String = ""
    systemprompt::String = "If a trading strategy exists then write a small description about it and the trading strategy as pseudo code wrapped in a code fence, otherwise do not output anything."
    input::String = "Evaluate this page excerpt for trading strategy relevance and follow the output rule."
    outputpath::String = "research.md"
    timeoutseconds::Int = 120
end

source(config::Configuration) = embedding(config.query; vecpath=config.vecpath)
weturis(config::Configuration) = wetURIs(config.crawlpath; capacity=config.capacity, wetroot=config.crawlroot)
wets(config::Configuration) = wets(weturis(config); capacity=config.capacity)

function coarsefilter(config::Configuration, entries::Wets)
    relevant!(source(config), entries; capacity=config.capacity, threshold=config.threshold)
end

coarsefilter(config::Configuration) = coarsefilter(config, wets(config))

function research(config::Configuration)
    entries = wets(config)
    coarsefilter(config, entries)
end
