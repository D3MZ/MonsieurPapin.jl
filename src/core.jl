Base.@kwdef struct Configuration
    crawlpath = URI("https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz")
    crawlroot::String = "https://data.commoncrawl.org/"
    capacity::Int = Threads.nthreads() * 10
    threshold::Float64 = 0.6
    vecpath::String = "data/wiki-news-300d-1M.vec"
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

weturis(config::Configuration) = wetURIs(config.crawlpath; capacity=config.capacity, wetroot=config.crawlroot)
wets(config::Configuration) = wets(weturis(config); capacity=config.capacity)

function coarsefilter(config::Configuration, entries::Channel{T}) where {T<:WET}
    relevant!(embedding(config.query; vecpath=config.vecpath), entries; capacity=config.capacity, threshold=config.threshold)
end

append!(file, output::AbstractString) = isempty(output) ? file : (write(file, output, "\n"); flush(file); file)

prompt(wet::WET, config::Configuration) = string("URI: ", uri(wet), "\nSCORE: ", wet.score, "\n\n", content(wet))

active(channel::Channel{T}, shortlist::Frontier{T}, generation) where {T<:WET} =
    isopen(channel) || isready(channel) || !isempty(shortlist) || !isnothing(generation)

function ingest!(shortlist::Frontier{T}, channel::Channel{T}) where {T<:WET}
    while isready(channel)
        insert!(shortlist, take!(channel))
    end
    shortlist
end

summarize(config::Configuration, client, wet::WET) = Threads.@spawn complete(prompt(wet, config), client)

persist(generation::Nothing, file) = nothing
persist(generation::Task, file) = istaskdone(generation) ? (append!(file, fetch(generation)); nothing) : generation

launch(generation::Task, config::Configuration, client, shortlist::Frontier{T}) where {T<:WET} = generation
launch(generation::Nothing, config::Configuration, client, shortlist::Frontier{T}) where {T<:WET} =
    isempty(shortlist) ? nothing : summarize(config, client, best!(shortlist))

function idle(channel::Channel{T}, shortlist::Frontier{T}, ::Nothing) where {T<:WET}
    isempty(shortlist) && isopen(channel) && !isready(channel) && wait(channel)
    yield()
end

function idle(channel::Channel{T}, shortlist::Frontier{T}, generation::Task) where {T<:WET}
    isempty(shortlist) && !isopen(channel) && wait(generation)
    yield()
end

function run!(file, entries::Channel{T}, config::Configuration, client, shortlist::Frontier{T}) where {T<:WET}
    generation = nothing
    while active(entries, shortlist, generation)
        generation = persist(generation, file)
        ingest!(shortlist, entries)
        generation = launch(generation, config, client, shortlist)
        idle(entries, shortlist, generation)
    end
    file
end

function report(config::Configuration, entries::Channel{T}, client) where {T<:WET}
    shortlist = frontier(config.capacity, eltype(entries))
    open(config.outputpath, "a") do file
        run!(file, entries, config, client, shortlist)
        config.outputpath
    end
end

report(config::Configuration, entries::Channel{T}) where {T<:WET} = report(config, entries, config)
queue(config::Configuration, entries::Channel{T}) where {T<:WET} = Threads.@spawn report(config, entries)

function research(config::Configuration)
    entries = wets(config)
    filtered = coarsefilter(config, entries)
    queue(config, filtered)
end
