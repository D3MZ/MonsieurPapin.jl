using MonsieurPapin, ProgressMeter, Logging
using Base.Order: By, ReverseOrdering
using HTTP: URI

seedurls() = ["https://en.wikipedia.org/wiki/Relative_strength_index"]
crawlindex() = URI("https://data.commoncrawl.org/crawl-data/CC-MAIN-2025-13/wet.paths.gz")
outputpath() = "research.md"
filecount() = 100_000
shortlistsize() = 10
excerptsize() = 2_000

function shortlist(queue, candidate, ranking)
    isnothing(queue) ? WETQueue(shortlistsize(), typeof(candidate), ranking) : queue
end

function harvest(config, urls; limitseconds=Inf)
    started = time()
    seedtext = MonsieurPapin.seed(urls)
    matcher = AC(MonsieurPapin.weights(seedtext).weights)
    deduper = Deduper(config.dedupe_capacity)
    progress = Progress(filecount(); desc="WET files")
    queue = nothing
    processedfiles = 0

    try
        for path in wetURIs(config.crawlpath; capacity=1)
            time() - started < limitseconds || break
            processedfiles += 1

            try
                for wet in wets(String(path); capacity=1, wetroot=config.crawlroot, languages=config.languages)
                    isduplicate(deduper, wet) && continue
                    value = MonsieurPapin.RustWorker.score(matcher, wet)
                    value > 0 || continue
                    candidate = MonsieurPapin.update(value, wet)
                    queue = shortlist(queue, candidate, ReverseOrdering(By(MonsieurPapin.score)))
                    MonsieurPapin.insert!(queue, candidate)
                end
            catch error
                @warn "Failed to process WET file" path = String(path) error
            end

            next!(progress)
        end
    finally
        finish!(progress)
        close(matcher)
    end

    @info "Harvest complete" processedfiles candidates = isnothing(queue) ? 0 : length(queue)
    (seedtext = seedtext, queue = queue, processedfiles = processedfiles)
end

function semantic(config, seedtext, queue)
    isnothing(queue) && return nothing
    shortlist = MonsieurPapin.semantic(config, queue, seedtext; capacity=shortlistsize())
    @info "Semantic complete" entries = length(shortlist)
    shortlist
end

function report(config, queue)
    llm = deepcopy(config)
    llm.systemprompt = "Write a 1-2 sentence description of the strategy or indicator with the source URL, and write a small pseudo Julia code that describes it. If no strategy or indicator is present, output nothing."
    llm.input = "Review this page excerpt and follow the output rule."

    open(config.outputpath, "w") do file
        isnothing(queue) && return nothing
        while !isempty(queue)
            wet = best!(queue)
            @info "Analyzing live page" uri = MonsieurPapin.uri(wet) score = wet.score
            page = string(
                "SOURCE URL: ", MonsieurPapin.uri(wet),
                "\nLANGUAGE: ", MonsieurPapin.language(wet),
                "\nDISTANCE: ", wet.score,
                "\n\nPAGE EXCERPT:\n", MonsieurPapin.content(wet, excerptsize()),
            )
            MonsieurPapin.append!(file, complete(page, llm))
        end
    end

    nothing
end

function run(; limitseconds=Inf)
    config = Configuration(; capacity=1, crawlpath=crawlindex(), outputpath=outputpath())
    urls = seedurls()
    @info "Starting live March crawl" urls crawlpath = string(config.crawlpath) outputpath = config.outputpath limitseconds
    harvested = harvest(config, urls; limitseconds)
    queue = semantic(config, harvested.seedtext, harvested.queue)
    report(config, queue)
    @info "Live March crawl complete" processedfiles = harvested.processedfiles outputpath = config.outputpath entries = isnothing(queue) ? 0 : length(queue)
    nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    run()
end
