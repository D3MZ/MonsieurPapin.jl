using MonsieurPapin, ProgressMeter, Logging
using Base.Order: By, ReverseOrdering
using HTTP: URI

seedurls() = ["https://en.wikipedia.org/wiki/Relative_strength_index"]
crawlindex() = URI("https://data.commoncrawl.org/crawl-data/CC-MAIN-2026-08/wet.paths.gz")
outputpath() = "research.md"
filecount() = 100_000
shortlistsize() = 10
excerptsize() = 12_000
languages() = ["eng"]
keywordgate() = 10.0
distancegate() = 0.45
wettype() = WET{4096, 12000, 64}

resulttype() = NamedTuple{(:wet, :text), Tuple{wettype(), String}}
elapsed(started) = round(time() - started; digits=2)

function harvest(config, urls; limitseconds=Inf, started=time())
    seedtext = MonsieurPapin.seed(urls)
    matcher = AC(MonsieurPapin.weights(seedtext).weights)
    progress = Progress(filecount(); desc="WET files")
    state = ReentrantLock()
    processedfiles = Ref(0)
    firstcandidate = Ref(true)
    candidates = Channel{wettype()}(config.capacity) do output
        try
            paths = wetURIs(config.crawlpath; capacity=Threads.nthreads())
            tasks = [
                Threads.@spawn begin
                    for path in paths
                        time() - started < limitseconds || break

                        lock(state) do
                            processedfiles[] += 1
                        end

                        try
                            for wet in wets(String(path); capacity=Threads.nthreads(), wetroot=config.crawlroot, languages=config.languages)
                                value = MonsieurPapin.RustWorker.score(matcher, wet)
                                value >= keywordgate() || continue
                                lock(state) do
                                    if firstcandidate[]
                                        firstcandidate[] = false
                                        @info "First AC candidate" seconds = elapsed(started) uri = MonsieurPapin.uri(wet) score = value
                                    end
                                end
                                put!(output, MonsieurPapin.update(value, wet))
                            end
                        catch error
                            @warn "Failed to process WET file" path = String(path) error
                        end

                        lock(state) do
                            next!(progress)
                        end
                    end
                end
                for _ in 1:Threads.nthreads()
            ]
            foreach(wait, tasks)
        finally
            finish!(progress)
            close(matcher)
        end
    end

    (seedtext = seedtext, candidates = candidates, processedfiles = processedfiles)
end

function semantic(config, seedtext, candidates)
    source = embedding(MonsieurPapin.query(seedtext); vecpath=config.vecpath)
    relevant!(source, candidates; capacity=Threads.nthreads(), threshold=1.0 - distancegate())
end

function page(wet)
    string(
        "SOURCE URL: ", MonsieurPapin.uri(wet),
        "\nLANGUAGE: ", MonsieurPapin.language(wet),
        "\nDISTANCE: ", wet.score,
        "\n\nPAGE EXCERPT:\n", MonsieurPapin.content(wet, excerptsize()),
    )
end

function consume!(requests, responses, config, started)
    llm = deepcopy(config)
    llm.systemprompt = "You extract only trading strategies and financial or technical indicators. If the page does not contain a trading strategy or financial or technical indicator, return an empty string and no explanation. If it does, write 1-2 sentences with the source URL and a small pseudo Julia code block."
    llm.input = "Review this page excerpt and follow the output rule."
    firstrequest = Ref(true)

    while true
        wet = take!(requests)
        wet === nothing && break
        try
            if firstrequest[]
                firstrequest[] = false
                @info "First LLM request" seconds = elapsed(started) uri = MonsieurPapin.uri(wet) score = wet.score
            end
            put!(responses, (wet = wet, text = complete(page(wet), llm)))
        catch error
            @info "llm request failed" error
            put!(responses, (wet = wet, text = ""))
        end
    end

    nothing
end

function shortlist(queue, wet)
    isnothing(queue) ? WETQueue(shortlistsize(), typeof(wet)) : queue
end

function dispatch!(queue, requests, submitted)
    while !isnothing(queue) && !isempty(queue) && submitted[] < shortlistsize() && !isfull(requests)
        put!(requests, best!(queue))
        submitted[] += 1
    end
    nothing
end

function write!(file, result)
    isempty(result.text) && return 0
    MonsieurPapin.append!(file, result.text)
    1
end

function collect!(responses, file, completed, written)
    while isready(responses)
        completed[] += 1
        written[] += write!(file, take!(responses))
    end
    nothing
end

function collect!(responses, file, completed, written, ::Val{:blocking})
    completed[] += 1
    written[] += write!(file, take!(responses))
    collect!(responses, file, completed, written)
    nothing
end

function drain!(queue, requests, responses, submitted, completed, written, file)
    while completed[] < submitted[] || (submitted[] < shortlistsize() && !isnothing(queue) && !isempty(queue))
        dispatch!(queue, requests, submitted)
        completed[] < submitted[] ? collect!(responses, file, completed, written, Val(:blocking)) : collect!(responses, file, completed, written)
    end
    nothing
end

function report(config, scored, started)
    requests = Channel{Union{Nothing, wettype()}}(Threads.nthreads())
    responses = Channel{resulttype()}(Threads.nthreads())
    submitted = Ref(0)
    completed = Ref(0)
    written = Ref(0)
    firstresult = Ref(true)
    consumer = Threads.@spawn consume!(requests, responses, config, started)
    queue = nothing

    open(config.outputpath, "w") do file
        try
            for wet in scored
                if firstresult[]
                    firstresult[] = false
                    @info "First semantic result" seconds = elapsed(started) uri = MonsieurPapin.uri(wet) score = wet.score
                end
                queue = shortlist(queue, wet)
                MonsieurPapin.insert!(queue, wet)
                dispatch!(queue, requests, submitted)
                collect!(responses, file, completed, written)
            end
            drain!(queue, requests, responses, submitted, completed, written, file)
        finally
            put!(requests, nothing)
            wait(consumer)
            collect!(responses, file, completed, written)
        end
    end

    (submitted = submitted[], completed = completed[], written = written[])
end

function run(; limitseconds=Inf)
    started = time()
    config = Configuration(; capacity=Threads.nthreads(), crawlpath=crawlindex(), outputpath=outputpath(), languages=languages())
    urls = seedurls()
    @info "Starting live March crawl" urls crawlpath = string(config.crawlpath) outputpath = config.outputpath languages = config.languages limitseconds keywordgate = keywordgate() distancegate = distancegate() threads = Threads.nthreads()
    harvested = harvest(config, urls; limitseconds, started)
    scored = semantic(config, harvested.seedtext, harvested.candidates)
    results = report(config, scored, started)
    @info "Live March crawl complete" processedfiles = harvested.processedfiles[] outputpath = config.outputpath submitted = results.submitted completed = results.completed written = results.written
    nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    run()
end
