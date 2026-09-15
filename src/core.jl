# --- Waterfall stages ---
# Each stage transforms an iterable of WET pages, dispatching on the strategy argument: the
# subject (pages) is inferred from the element type, the criterion from the strategy. Cheap
# stages feed slower ones, and every stage is a bounded priority queue, so memory stays fixed
# and only the strongest survivors reach the expensive stages.

# WET producers and every waterfall stage share this admission signal. `nothing` keeps the public
# stream APIs independent of the LLM monitor; research passes UsageMonitor so quota exhaustion
# stops new work all the way back at the live WET index.
pipelineactive(::Nothing) = true
pipelineactive(monitor) = admit(monitor)

"""
    unique(seen::SeenSet, source; batchsize, monitor) -> Channel

Windowed score-aware deduplication. Each bounded input window is retained in a `SimHashQueue`
and emitted best-first as soon as that window fills; this preserves the strongest duplicate within
the window without holding the entire live crawl behind an end-of-stream barrier. A later window
is a new deduplication horizon, which is the explicit tradeoff for live downstream flow.
"""
function emitwindow!(novel, candidates, monitor)
    for wet in candidates
        (pipelineactive(monitor) && isopen(novel)) || break
        put!(novel, wet)
    end
    nothing
end

function Base.unique(seen::SeenSet, source; batchsize=seen.capacity, monitor=nothing)
    T = eltype(source)
    windowcapacity = min(seen.capacity, batchsize)
    Channel{T}(windowcapacity; spawn=true) do novel
        candidates = SimHashQueue{T}(windowcapacity)
        scratch = Ref{T}()
        counts = Vector{Int32}(undef, 64)
        count = 0
        for wet in source
            (pipelineactive(monitor) && isopen(novel)) || break
            insert!(candidates, simhash(wet, scratch, counts), wet)
            count += 1
            if count == batchsize
                emitwindow!(novel, candidates, monitor)
                candidates = SimHashQueue{T}(windowcapacity)
                count = 0
            end
        end
        emitwindow!(novel, candidates, monitor)
    end
end

"""
    select(matcher::AC, source; capacity) -> BoundedPriorityQueue

Keyword selection. Scores each page by keyword match and keeps the top `capacity` that match
at least one keyword, evicting the weakest as stronger pages arrive.
"""
function select(matcher::AC, source; capacity, minmatches=1, monitor=nothing)
    shortlist = BoundedPriorityQueue{eltype(source)}(capacity, Reverse)
    Threads.@spawn begin
        # The whole stream flows through keyword scoring, so it must keep up with network intake
        # (single-threaded it falls below it and throttles the download). The AC automaton is
        # immutable, so workers share it and each keeps its own scratch box; only the bounded
        # shortlist is shared, and its put! is internally locked.
        try
            @sync for _ in 1:Threads.nthreads()
                Threads.@spawn begin
                    scratch = Ref{eltype(source)}()  # reused box: score each WET without allocating
                    for wet in source
                        (pipelineactive(monitor) && isopen(shortlist)) || break
                        value = score(matcher, wet, scratch)
                        # Require at least `minmatches` keyword hits: a page tripped by one incidental
                        # common word ("trend", "support") is dropped, so only keyword-dense pages flow
                        # downstream. This keeps the embedding stage from being flooded (it is the
                        # slowest streaming stage, ~10x slower than keyword scoring) and is also what
                        # keeps ingest from throttling to embedding's rate. Skip the lock for matches
                        # that can't make the shortlist anyway.
                        value >= minmatches && admits(shortlist, Float64(value)) && put!(shortlist, rescore(wet, Float64(value)))
                    end
                end
            end
        finally
            close(shortlist)
            close(matcher)
        end
    end
    shortlist
end

"""
    select(query::Embedding, source; capacity, threshold, batchsize) -> BoundedPriorityQueue

Embedding selection. Batches pages through the embedding model and keeps the top `capacity`
nearest the query, spreading batches across all threads.
"""
function select(query::Embedding, source; capacity, threshold, batchsize=64, workers=max(1, Threads.nthreads() ÷ 2), monitor=nothing)
    shortlist = BoundedPriorityQueue{eltype(source)}(capacity)  # Forward: lower distance is better
    Threads.@spawn begin
        # Embedding is CPU-bound (Rust matmul) but only feeds the bounded shortlist that drains
        # into the much slower LLM, so it needs only a few workers. Spawning one per thread starves
        # the network-bound parse/decompress stages of cores and throttles ingest below line rate.
        tasks = map(_ -> Threads.@spawn(embed!(shortlist, query, source, batchsize, threshold, monitor)), 1:workers)
        foreach(wait, tasks)
        close(shortlist)
    end
    shortlist
end

function embed!(shortlist::BoundedPriorityQueue{T}, query::Embedding, source, batchsize, threshold, monitor) where {T}
    handle!(query) # load query.model once before spawning; each worker gets its own scratch below
    scratch = _M2V.Scratch(query.model) # one per worker task -- see score!'s explicit-scratch note
    batch, scores, pointers, lengths = T[], Float64[], UInt[], UInt[]
    flush!() = (score!(scores, pointers, lengths, query, batch, scratch);
                foreach(i -> isrelevant(scores[i]; threshold) && pipelineactive(monitor) && isopen(shortlist) && put!(shortlist, rescore(batch[i], scores[i])), eachindex(batch));
                empty!(batch))
    for wet in source
        (pipelineactive(monitor) && isopen(shortlist)) || break
        push!(batch, wet)
        length(batch) == batchsize && flush!()
    end
    isempty(batch) || flush!()
end

"""
    extract(source, settings, system, instruction, render) -> Nothing

LLM extraction. Drains `source` best-first, sends each page to the LLM, and appends non-empty
findings to the output file. `render` formats a page into prompt text.
"""
# An LLM told to "return nothing" often emits a blank-ish placeholder (whitespace, zero-width
# marks, code fences, "empty"/"none"/"NONE") instead of truly empty output. Treat those as no
# finding so they never pollute the report.
function informative(finding::AbstractString)
    s = strip(finding, [' ', '\n', '\t', '\r', '`', '"', '\'', '*', '(', ')', '.', '·', '-',
                        '​', '﻿', '　', '空'])
    !isempty(s) && lowercase(s) ∉ ("empty", "empty string", "none", "null", "n/a", "na", "nil",
                                   "no findings", "nothing", "no strategy", "no trading strategy")
end

function extract(source, client::LLMBackend, output::AbstractDict, system, instruction, render;
                 mode, workers, monitor)
    pages = Threads.Atomic{Int}(0)
    written = Threads.Atomic{Int}(0)
    t0 = time()
    filelock = ReentrantLock()
    open(output["path"], mode) do file
        @sync for _ in 1:workers
            Threads.@spawn for wet in source
                if !admit(monitor)
                    close(source)
                    break
                end
                ts = time()
                attempt!(monitor)
                response = request(client, system, string(instruction, "\n\n", render(wet)))
                record!(monitor, response)
                finding = message(response)
                p = Threads.atomic_add!(pages, 1) + 1
                ok = informative(finding)
                if ok
                    lock(filelock) do
                        write(file, strip(finding), "\n\n")
                        flush(file)
                    end
                    Threads.atomic_add!(written, 1)
                end
                w = written[]
                println(stderr, "[extract] pages=$p written=$w sec=$(round(time()-ts;digits=0)) " *
                                "informative=$ok rate=$(round(w/max(time()-t0,1)*3600;digits=0))/hr " *
                                "dist=$(round(wet.score;digits=3)) uri=$(first(uri(wet),70))")
                flush(stderr)
            end
        end
    end
    nothing
end

# --- Prompt rendering ---

# Cap page content sent to the LLM: a trading strategy is identifiable from the first few KB, and
# prefilling the full 12 KB on a local model is the dominant per-page cost (and a timeout risk).
const promptcontent = 6000
prompt(wet::WET) = string("URI: ", uri(wet), "\nLANGUAGE: ", language(wet), "\nSCORE: ", wet.score, "\n\n", content(wet, promptcontent))
prompt(wet::WET, ::Val{:local}) = string("SOURCE URL: ", uri(wet), "\nLANGUAGE: ", language(wet), "\nDISTANCE: ", wet.score, "\n\nPAGE EXCERPT:\n", content(wet, promptcontent))

# --- Orchestration ---

# A `*.paths.gz` index lists many WET files for a whole crawl; stream them concurrently across
# workers (`wets(::Channel)`). A direct WET file or URL is parsed as records on its own.
function wetstream(crawl::AbstractDict, pipelineconfig::AbstractDict; monitor=nothing)
    path = crawl["path"]
    capacity = pipelineconfig["capacity"]
    root = crawl["root"]
    languages = crawl["languages"]
    endswith(path, "paths.gz") ?
        wets(wetpaths(path, crawl["retry"]; monitor), crawl["retry"]; capacity, wetroot=root, languages, monitor) :
        wets(path, crawl["retry"]; capacity, wetroot=root, languages, monitor)
end

pipeline(source, seen, ::Nothing, query, capacity; minmatches, threshold, monitor, dedupe_batchsize) =
    select(query, unique(seen, source; batchsize=dedupe_batchsize, monitor); capacity, threshold, monitor)
pipeline(source, seen, matcher::AC, query, capacity; minmatches, threshold, monitor, dedupe_batchsize) =
    select(query, unique(seen, select(matcher, source; capacity, minmatches, monitor); batchsize=dedupe_batchsize, monitor); capacity, threshold, monitor)

seedtext(urls, retryconfig::AbstractDict) = join(fetchtext.(urls, Ref(retryconfig)), "\n\n")

function cleankeywords(raw)
    out = String[]
    for item in raw
        for piece in split(string(item), r"[,/|;、，]+")
            term = strip(piece)
            2 <= length(term) <= 60 && push!(out, String(term))
        end
    end
    unique(out)
end

function languagekeywords(crawl::AbstractDict, pipelineconfig::AbstractDict,
                          client::LLMBackend, prompts::AbstractDict, llmconfig::AbstractDict, article, monitor)
    langs = crawl["languages"]
    manual = crawl["manual_keywords"]
    cachepath = pipelineconfig["keyword_cache"]
    cache = isfile(cachepath) ? JSON.parse(read(cachepath, String)) : Dict{String,Any}()
    result = Dict{String,Vector{String}}()
    for (language, terms) in manual
        result[language] = String.(terms)
    end
    for (language, terms) in cache
        result[language] = String.(terms)
    end
    todo = setdiff(langs, collect(keys(result)))
    if !isempty(todo)
        jobs = Channel{String}(length(todo))
        foreach(language -> put!(jobs, language), todo)
        close(jobs)
        guard = ReentrantLock()
        @sync for _ in 1:llmconfig["parallel"]
            Threads.@spawn for language in jobs
                terms = cleankeywords(extractkeywords(client, prompts, article;
                    limitinput=llmconfig["keyword_input_limit"], timeout=llmconfig["timeout"], langs=[language], monitor=monitor))
                lock(guard) do
                    result[language] = terms
                end
            end
        end
        merged = merge(cache, Dict{String,Any}(language => result[language] for language in todo))
        open(io -> write(io, JSON.json(merged)), cachepath, "w")
    end
    keywords = cleankeywords(reduce(vcat, (result[language] for language in langs); init=String[]))
    @info "Keyword language sweep complete." languages=length(langs) populated=length(result) keywords=length(keywords)
    keywords
end

function bootstrap(crawl::AbstractDict, pipelineconfig::AbstractDict, embeddingconfig::AbstractDict,
                   client::LLMBackend, llmconfig::AbstractDict, prompts::AbstractDict, monitor)
    seeds = pipelineconfig["seeds"]
    article = seedtext(seeds, crawl["retry"])
    manual = pipelineconfig["keywords"]
    keywords = isempty(manual) ? languagekeywords(crawl, pipelineconfig, client, prompts, llmconfig, article, monitor) : cleankeywords(manual)
    query = embedding(join(keywords, " "); vecpath=embeddingconfig["model"])
    @info "Bootstrap complete." seeds=length(seeds) languages=length(crawl["languages"]) articlechars=length(article) nkeywords=length(keywords) keywords
    (AC(keywords), query)
end

function research(settings::AbstractDict)
    research(settings["crawl"], settings["pipeline"], settings["embedding"], settings["llm"],
             settings["output"], settings["prompts"])
end

function research(crawl::AbstractDict, pipelineconfig::AbstractDict, embeddingconfig::AbstractDict,
                  llmconfig::AbstractDict, output::AbstractDict, prompts::AbstractDict)
    client = llm(llmconfig)
    transferred = false
    try
        usage_monitor = monitor(llmconfig)
        try
            capacity = pipelineconfig["capacity"]
            seen = SeenSet(pipelineconfig["dedupe_capacity"])
            matcher, query = bootstrap(crawl, pipelineconfig, embeddingconfig, client, llmconfig, prompts, usage_monitor)
            source = wetstream(crawl, pipelineconfig; monitor=usage_monitor)
            best = pipeline(source, seen, matcher, query, capacity;
                            minmatches=pipelineconfig["min_keywords"], threshold=pipelineconfig["threshold"],
                            monitor=usage_monitor, dedupe_batchsize=pipelineconfig["dedupe_batchsize"])
            task = Threads.@spawn begin
                try
                    extract(best, client, output, prompts["system"], prompts["input"], prompt;
                            mode="w", workers=llmconfig["parallel"], monitor=usage_monitor)
                    @info "Research complete." outputpath=output["path"]
                finally
                    try
                        close(usage_monitor)
                    finally
                        close(client)
                    end
                end
            end
            transferred = true
            task
        finally
            transferred || close(usage_monitor)
        end
    finally
        transferred || close(client)
    end
end

function research(settings::AbstractDict, urls::Vector{<:AbstractString}, wetpath::AbstractString)
    research(settings["crawl"], settings["pipeline"], settings["embedding"], settings["llm"],
             settings["output"], settings["prompts"], urls, wetpath)
end

function research(crawl::AbstractDict, pipelineconfig::AbstractDict, embeddingconfig::AbstractDict,
                  llmconfig::AbstractDict, output::AbstractDict, prompts::AbstractDict,
                  urls::Vector{<:AbstractString}, wetpath::AbstractString)
    client = llm(llmconfig)
    transferred = false
    try
        usage_monitor = monitor(llmconfig)
        try
            capacity = pipelineconfig["capacity"]
            seen = SeenSet(pipelineconfig["dedupe_capacity"])
            task = Threads.@spawn begin
                try
                    article = seed(urls, crawl["retry"])
                    source = wets(wetpath, crawl["retry"]; capacity, languages=crawl["languages"], monitor=usage_monitor)
                    query = embedding(first(article, 2_000); vecpath=embeddingconfig["model"])
                    best = pipeline(source, seen, AC(weights(article)), query, capacity;
                                    minmatches=pipelineconfig["min_keywords"], threshold=pipelineconfig["threshold"],
                                    monitor=usage_monitor, dedupe_batchsize=pipelineconfig["dedupe_batchsize"])
                    extract(best, client, output, prompts["local_system"], prompts["local_input"], wet -> prompt(wet, Val(:local));
                            mode="w", workers=llmconfig["parallel"], monitor=usage_monitor)
                    @info "Local research complete." outputpath=output["path"]
                finally
                    try
                        close(usage_monitor)
                    finally
                        close(client)
                    end
                end
            end
            transferred = true
            task
        finally
            transferred || close(usage_monitor)
        end
    finally
        transferred || close(client)
    end
end
