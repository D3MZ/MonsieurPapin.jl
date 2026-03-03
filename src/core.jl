Base.@kwdef struct Configuration
    crawlpath::String = "https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz"
    crawlroot::String = "https://data.commoncrawl.org/"
    previewseconds::Float64 = 8.0
    query::String = "It doesn’t really matter which component you find first, the price action signal or the level. What matters is if the two have come together to form a confluent price action trade. When you have an obvious price action signal, like a pin bar or a fakey signal, and that signal has formed at a key horizontal level of support or resistance in a market, you have a potentially very high-probability trade on your hands."
    baseurl::String = "http://localhost:1234"
    path::String = "/api/v1/chat"
    model::String = "qwen/qwen3.5-35b-a3b"
    password::String = ""
    systemprompt::String = "If a trading strategy exists then write a small description about it and the trading strategy as pseudo code wrapped in a code fence, otherwise do not output anything."
    input::String = "Evaluate this page excerpt for trading strategy relevance and follow the output rule."
    outputpath::String = "research.md"
    maxpages::Int = 1
    timeoutseconds::Int = 120
end

function research(config::Configuration)

end