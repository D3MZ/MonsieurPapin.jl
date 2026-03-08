Base.@kwdef struct Configuration
    crawlpath = URI("https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz")
    crawlroot::String = "https://data.commoncrawl.org/"
    capacity::Int = 10
    threshold::Float64 = 0.6
    vecpath::String = "data/wiki-news-300d-1M.vec"
    previewseconds::Float64 = 8.0
    previewlength::Int = 12000
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

append!(file, output::AbstractString) = isempty(output) ? file : (write(file, output, "\n"); flush(file); file)

function prompt(pages::Wets, wet::WET, config::Configuration)
    bytes = content(pages, wet)
    stop = min(lastindex(bytes), config.previewlength)
    text = String(@view bytes[firstindex(bytes):stop])
    string("URI: ", String(uri(pages, wet)), "\nSCORE: ", wet.score, "\n\n", text)
end

active(channel::Channel{WET}, shortlist::Frontier{WET}, generation) =
    isopen(channel) || isready(channel) || !isempty(shortlist) || !isnothing(generation)

function ingest!(shortlist::Frontier{WET}, channel::Channel{WET})
    while isready(channel)
        insert!(shortlist, take!(channel))
    end
    shortlist
end

summarize(pages::Wets, config::Configuration, client, wet::WET) =
    Threads.@spawn complete(prompt(pages, wet, config), client)

persist(generation::Nothing, file) = nothing
persist(generation::Task, file) = istaskdone(generation) ? (append!(file, fetch(generation)); nothing) : generation

launch(generation::Task, pages::Wets, config::Configuration, client, shortlist::Frontier{WET}) = generation
launch(generation::Nothing, pages::Wets, config::Configuration, client, shortlist::Frontier{WET}) =
    isempty(shortlist) ? nothing : summarize(pages, config, client, best!(shortlist))

function idle(channel::Channel{WET}, shortlist::Frontier{WET}, ::Nothing)
    isempty(shortlist) && isopen(channel) && !isready(channel) && wait(channel)
    yield()
end

function idle(channel::Channel{WET}, shortlist::Frontier{WET}, generation::Task)
    isempty(shortlist) && !isopen(channel) && wait(generation)
    yield()
end

function run!(file, pages::Wets, config::Configuration, client, shortlist::Frontier{WET})
    generation = nothing
    while active(pages.entries, shortlist, generation)
        generation = persist(generation, file)
        ingest!(shortlist, pages.entries)
        generation = launch(generation, pages, config, client, shortlist)
        idle(pages.entries, shortlist, generation)
    end
    file
end

function report(config::Configuration, pages::Wets, client)
    shortlist = frontier(config.capacity, WET)
    open(config.outputpath, "a") do file
        run!(file, pages, config, client, shortlist)
        config.outputpath
    end
end

report(config::Configuration, pages::Wets) = report(config, pages, config)
queue(config::Configuration, entries::Wets) = Threads.@spawn report(config, entries)

function research(config::Configuration)
    entries = wets(config)
    filtered = coarsefilter(config, entries)
    queue(config, filtered)
end
