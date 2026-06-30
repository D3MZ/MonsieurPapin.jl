loadsettings(path="settings.toml") = TOML.parsefile(path)

# --- Waterfall stages ---
# Each stage transforms an iterable of WET pages, dispatching on the strategy argument: the
# subject (pages) is inferred from the element type, the criterion from the strategy. Cheap
# stages feed slower ones, and every stage is a bounded priority queue, so memory stays fixed
# and only the strongest survivors reach the expensive stages.

"""
    unique(seen::SeenSet, source) -> Channel

Deduplication. Streams `source` (a `Channel` or any iterable stage, e.g. the keyword
shortlist), dropping near-duplicates that fall inside `seen`'s SimHash window.
"""
function Base.unique(seen::SeenSet, source)
    T = eltype(source)
    Channel{T}(Threads.nthreads() * 10; spawn=true) do novel
        # SimHash (CPU-bound) runs in parallel across workers; only the cheap seen-set check is
        # serialized under a lock. Each worker owns its scratch/accumulator. Which of two
        # near-duplicates survives is nondeterministic, but downstream is order-independent.
        guard = ReentrantLock()
        @sync for _ in 1:Threads.nthreads()
            Threads.@spawn begin
                scratch = Ref{T}()
                counts = Vector{Int32}(undef, 64)
                for wet in source
                    hash = simhash(wet, scratch, counts)
                    duplicate = lock(() -> seen!(seen, hash), guard)
                    duplicate || put!(novel, wet)
                end
            end
        end
    end
end

"""
    select(matcher::AC, source; capacity) -> BoundedPriorityQueue

Keyword selection. Scores each page by keyword match and keeps the top `capacity` that match
at least one keyword, evicting the weakest as stronger pages arrive.
"""
function select(matcher::AC, source; capacity, minmatches=1)
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
    select(query::Embedding, source; capacity, batchsize) -> BoundedPriorityQueue

Embedding selection. Batches pages through the embedding model and keeps the top `capacity`
nearest the query, spreading batches across all threads.
"""
function select(query::Embedding, source; capacity, batchsize=64, workers=max(1, Threads.nthreads() ÷ 2))
    shortlist = BoundedPriorityQueue{eltype(source)}(capacity)  # Forward: lower distance is better
    Threads.@spawn begin
        # Embedding is CPU-bound (Rust matmul) but only feeds the bounded shortlist that drains
        # into the much slower LLM, so it needs only a few workers. Spawning one per thread starves
        # the network-bound parse/decompress stages of cores and throttles ingest below line rate.
        tasks = map(_ -> Threads.@spawn(embed!(shortlist, query, source, batchsize)), 1:workers)
        foreach(wait, tasks)
        close(shortlist)
    end
    shortlist
end

function embed!(shortlist::BoundedPriorityQueue{T}, query::Embedding, source, batchsize) where {T}
    batch, scores, pointers, lengths = T[], Float64[], UInt[], UInt[]
    flush!() = (score!(scores, pointers, lengths, query, batch);
                foreach(i -> put!(shortlist, rescore(batch[i], scores[i])), eachindex(batch));
                empty!(batch))
    for wet in source
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

function extract(source, settings, system, instruction, render; mode="a",
                 workers=get(settings["llm"], "parallel", 4))
    pages = Threads.Atomic{Int}(0); written = Threads.Atomic{Int}(0); t0 = time()
    filelock = ReentrantLock()
    open(settings["output"]["path"], mode) do file
        # Drain the shortlist with `workers` concurrent LLM calls (the LLM is the finding-rate
        # bottleneck; the local server batches several in parallel). take! is thread-safe, so each
        # worker pulls a distinct best-available page; the file write is serialized under a lock.
        @sync for _ in 1:workers
            Threads.@spawn for wet in source
              try   # no single page may abort an 80-hour extraction
                ts = time()
                finding = try   # one slow/timed-out page must not abort extraction
                    message(request(; model=settings["llm"]["model"], systemprompt=system,
                        input=string(instruction, "\n\n", render(wet)),
                        baseurl=settings["llm"]["baseurl"], path=settings["llm"]["path"],
                        password=settings["llm"]["password"], timeout=settings["llm"]["timeout"],
                        thinking=get(settings["llm"], "thinking", false)))
                catch err
                    # Log only the error type, never the response body: a 500 echoes the (possibly
                    # malformed) request back, and rendering invalid bytes in the log is a crash risk.
                    @warn "extract LLM call failed; skipping page" error=string(typeof(err))
                    ""
                end
                p = Threads.atomic_add!(pages, 1) + 1
                ok = informative(finding)
                if ok
                    lock(filelock) do
                        write(file, strip(finding), "\n\n"); flush(file)
                    end
                    Threads.atomic_add!(written, 1)
                end
                w = written[]
                println(stderr, "[extract] pages=$p written=$w sec=$(round(time()-ts;digits=0)) " *
                                "informative=$ok rate=$(round(w/max(time()-t0,1)*3600;digits=0))/hr " *
                                "dist=$(round(wet.score;digits=3)) uri=$(first(uri(wet),70))")
                flush(stderr)
              catch err
                @warn "extract: skipping page after unexpected error" error=string(typeof(err))
              end
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
function wetstream(settings)
    path = settings["crawl"]["path"]
    capacity = settings["pipeline"]["capacity"]
    root = settings["crawl"]["root"]
    languages = settings["crawl"]["languages"]
    endswith(path, "paths.gz") ?
        wets(wetpaths(path); capacity, wetroot=root, languages) :
        wets(path; capacity, wetroot=root, languages)
end

# The shared pipeline: keyword -> dedup -> embedding, all bounded priority queues. Keyword
# scoring (the cheapest filter) runs first to shrink the stream, then near-duplicates are
# dropped, then survivors are ranked by embedding similarity. With no keywords the keyword
# stage is skipped and the full stream is deduplicated before the embedding selection.
pipeline(source, seen, ac, query, capacity; minmatches=1) =
    select(query, unique(seen, isnothing(ac) ? source : select(ac, source; capacity, minmatches)); capacity)

# Fetch the seed pages tolerantly: a dead/blocked URL is logged and skipped rather than aborting
# the whole run (`fetchtext` has no retry and throws on failure).
function seedtext(urls)
    pages = String[]
    for url in urls
        try
            push!(pages, fetchtext(url))
        catch err
            @warn "Seed fetch failed; skipping." url exception=(err, catch_backtrace())
        end
    end
    join(filter(!isempty, pages), "\n\n")
end

# Normalize the LLM's keyword list into atomic AC patterns. The model is inconsistent: sometimes it
# packs all language variants of one concept into a single comma/slash-joined string (which would
# become one pattern that never matches), so split on separators, trim, drop junk, and dedupe.
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

# Bootstrap the keyword matcher and the semantic query from the seed URLs, asking the LLM for
# multilingual trading keywords (README flow). Guards make a silent degrade impossible: an empty
# seed list, all-empty fetches, or zero keywords each raise instead of quietly skipping a stage.
# A non-empty `pipeline.keywords` in settings overrides the LLM and is used verbatim.
function bootstrap(settings)
    seeds = settings["pipeline"]["seeds"]
    isempty(seeds) && error("pipeline.seeds is empty: seed URLs are required to bootstrap keywords + query.")
    article = seedtext(seeds)
    isempty(strip(article)) && error("all seed fetches returned empty; cannot bootstrap (seeds=$seeds).")
    manual = settings["pipeline"]["keywords"]
    # Generate idiomatic keywords for every target language in batches of 6: one big call collapses to
    # a single language / starves later ones, so small batches guarantee full per-language coverage
    # (validated: 6 languages -> ~25 concepts x 6 = ~150 multilingual terms per call). Each call is a
    # one-time ~6 KB-seed prefill; the grammar's maxItems bounds each call's output. Aho-Corasick scan
    # cost is independent of keyword count, so the large multilingual set is free at scan time.
    # Batches run concurrently (one task per `llm.parallel` slot) so bootstrap uses the server's full
    # concurrency instead of draining 27+ batches one at a time through an otherwise-idle slot pool.
    if isempty(manual)
        batches = collect(Iterators.partition(settings["crawl"]["languages"], 6))
        workers = get(settings["llm"], "parallel", 4)
        tasks = asyncmap(batches; ntasks=workers) do batch
            extractkeywords(settings, article; limitinput=6_000, timeout=900, langs=collect(batch))
        end
        raw = reduce(vcat, tasks; init=String[])
    else
        raw = manual
    end
    keywords = cleankeywords(raw)
    length(keywords) < 10 && error("only $(length(keywords)) keywords after bootstrap; check keywords_system prompt or the LLM server.")
    # The semantic query is the clean multilingual keyword vocabulary itself, NOT the raw seed
    # article: article text is polluted with page chrome (nav/boilerplate) and fails to rank trading
    # pages above unrelated ones. Keyword-joined query separates trading (~0.6-0.8) from junk (~1.0).
    query = embedding(join(keywords, " "); vecpath=settings["embedding"]["model"])
    @info "Bootstrap complete." seeds=length(seeds) articlechars=length(article) nkeywords=length(keywords) keywords
    (AC(keywords), query)
end

function research(settings)
    capacity = settings["pipeline"]["capacity"]
    seen = SeenSet(settings["pipeline"]["dedupe_capacity"])
    matcher, query = bootstrap(settings)
    minmatches = get(settings["pipeline"], "min_keywords", 1)
    best = pipeline(wetstream(settings), seen, matcher, query, capacity; minmatches)
    Threads.@spawn begin
        extract(best, settings, settings["prompts"]["system"], settings["prompts"]["input"], prompt; mode="w")
        @info "Research complete." outputpath=settings["output"]["path"]
    end
end

function research(settings, urls::Vector{<:AbstractString}, wetpath::AbstractString)
    Threads.@spawn begin
        article = seed(urls)
        capacity = settings["pipeline"]["capacity"]
        seen = SeenSet(settings["pipeline"]["dedupe_capacity"])
        source = wets(wetpath; capacity, languages=settings["crawl"]["languages"])
        query = embedding(first(article, 2_000); vecpath=settings["embedding"]["model"])
        best = pipeline(source, seen, AC(weights(article)), query, capacity)
        extract(best, settings, settings["prompts"]["local_system"], settings["prompts"]["local_input"], wet -> prompt(wet, Val(:local)); mode="w")
        @info "Local research complete." outputpath=settings["output"]["path"]
    end
end
