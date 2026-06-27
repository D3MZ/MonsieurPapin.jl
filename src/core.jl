loadsettings(path="settings.toml") = TOML.parsefile(path)

# --- Waterfall stages ---
# Each stage transforms an iterable of WET pages, dispatching on the strategy argument: the
# subject (pages) is inferred from the element type, the criterion from the strategy. Cheap
# stages feed slower ones, and every stage is a bounded priority queue, so memory stays fixed
# and only the strongest survivors reach the expensive stages.

"""
    unique(seen::SeenSet, source::Channel) -> Channel

Deduplication. Streams `source`, dropping near-duplicates that fall inside `seen`'s SimHash
window.
"""
function Base.unique(seen::SeenSet, source::Channel{T}) where {T}
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
function select(matcher::AC, source; capacity)
    shortlist = BoundedPriorityQueue{eltype(source)}(capacity, Reverse)
    Threads.@spawn begin
        scratch = Ref{eltype(source)}()      # reused box: score each WET without allocating
        try
            for wet in source
                value = score(matcher, wet, scratch)
                value > 0 && put!(shortlist, rescore(wet, Float64(value)))
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
function select(query::Embedding, source; capacity, batchsize=64)
    shortlist = BoundedPriorityQueue{eltype(source)}(capacity)  # Forward: lower distance is better
    Threads.@spawn begin
        workers = map(_ -> Threads.@spawn(embed!(shortlist, query, source, batchsize)), 1:Threads.nthreads())
        foreach(wait, workers)
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
function extract(source, settings, system, instruction, render; mode="a")
    open(settings["output"]["path"], mode) do file
        for wet in source
            finding = message(request(; model=settings["llm"]["model"], systemprompt=system,
                input=string(instruction, "\n\n", render(wet)),
                baseurl=settings["llm"]["baseurl"], path=settings["llm"]["path"],
                password=settings["llm"]["password"], timeout=settings["llm"]["timeout"]))
            isempty(finding) || (write(file, strip(finding), "\n"); flush(file))
        end
    end
    nothing
end

# --- Prompt rendering ---

prompt(wet::WET) = string("URI: ", uri(wet), "\nLANGUAGE: ", language(wet), "\nSCORE: ", wet.score, "\n\n", content(wet))
prompt(wet::WET, ::Val{:local}) = string("SOURCE URL: ", uri(wet), "\nLANGUAGE: ", language(wet), "\nDISTANCE: ", wet.score, "\n\nPAGE EXCERPT:\n", content(wet))

# --- Orchestration ---

wetstream(settings) = wets(settings["crawl"]["path"]; capacity=settings["pipeline"]["capacity"], wetroot=settings["crawl"]["root"], languages=settings["crawl"]["languages"])

# The shared pipeline: dedup -> keyword -> embedding, all bounded priority queues. With no
# keywords the keyword stage is skipped and pages flow straight into the embedding selection.
pipeline(source, ac, query, capacity) =
    select(query, isnothing(ac) ? source : select(ac, source; capacity); capacity)

function research(settings)
    keywords = settings["pipeline"]["keywords"]
    capacity = settings["pipeline"]["capacity"]
    novel = unique(SeenSet(settings["pipeline"]["dedupe_capacity"]), wetstream(settings))
    matcher = isempty(keywords) ? nothing : AC(keywords)
    query = embedding(join(keywords, " "); vecpath=settings["embedding"]["model"])
    best = pipeline(novel, matcher, query, capacity)
    Threads.@spawn begin
        extract(best, settings, settings["prompts"]["system"], settings["prompts"]["input"], prompt)
        @info "Research complete." outputpath=settings["output"]["path"]
    end
end

function research(settings, urls::Vector{<:AbstractString}, wetpath::AbstractString)
    Threads.@spawn begin
        article = seed(urls)
        capacity = settings["pipeline"]["capacity"]
        novel = unique(SeenSet(settings["pipeline"]["dedupe_capacity"]), wets(wetpath; capacity, languages=settings["crawl"]["languages"]))
        query = embedding(first(article, 2_000); vecpath=settings["embedding"]["model"])
        best = pipeline(novel, AC(weights(article)), query, capacity)
        extract(best, settings, settings["prompts"]["local_system"], settings["prompts"]["local_input"], wet -> prompt(wet, Val(:local)); mode="w")
        @info "Local research complete." outputpath=settings["output"]["path"]
    end
end
