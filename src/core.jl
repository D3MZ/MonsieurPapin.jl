loadsettings(path="settings.toml") = TOML.parsefile(path)

seed(urls::Vector{<:AbstractString}) = join(filter(page -> !isempty(page), fetchtext.(urls)), "\n\n")
query(page::AbstractString; limit=2_000) = first(page, min(limit, length(page)))
normalize(page::AbstractString) = lowercase(Base.Unicode.normalize(page, :NFKC))
tokens(page::AbstractString) = [entry.match for entry in eachmatch(r"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]|[\p{L}\p{N}]+", normalize(page))]

function counts(page::AbstractString)
    counter = Dict{String,Int}()
    foreach(tokens(page)) do token
        counter[token] = get(counter, token, 0) + 1
    end
    counter
end

function weights(page::AbstractString; capacity=128)
    entries = collect(counts(page))
    k = min(capacity, length(entries))
    ranked = partialsort!(entries, 1:k; by=entry -> (-last(entry), first(entry)))
    Dict(first(entry) => 1 / sqrt(last(entry)) for entry in ranked[1:k])
end



# --- Pipeline Stages ---

"""
    harvest(keywords, settings, entries) -> Channel{WET}

Stage 1: High-speed deduplication and keyword matching.
Filters the raw stream down to candidates that contain target keywords.
"""
function harvest(keywords::Vector{String}, settings, entries::Channel{<:WET})
    out = Channel{eltype(entries)}(settings["pipeline"]["capacity"])
    deduper = Deduper(settings["pipeline"]["dedupe_capacity"])
    ac = isempty(keywords) ? nothing : AC(keywords)
    
    Threads.@spawn begin
        try
            for wet in entries
                isduplicate(deduper, wet) && continue
                
                if !isnothing(ac)
                    s = RustWorker.score(ac, wet)
                    s > 0 || continue
                    wet = update(Float64(s), wet)
                end
                
                put!(out, wet)
            end
        finally
            close(out)
            !isnothing(ac) && close(ac)
        end
    end
    out
end

function harvest(settings, entries::Channel{<:WET}, source::Dict{String,Float64}; capacity=10)
    shortlist = WETQueue(capacity, eltype(entries), ReverseOrdering(By(score)))
    isempty(source) && return shortlist
    deduper = Deduper(settings["pipeline"]["dedupe_capacity"])
    ac = AC(source)

    try
        for wet in entries
            isduplicate(deduper, wet) && continue
            value = RustWorker.score(ac, wet)
            value > 0 || continue
            insert!(shortlist, update(value, wet))
        end
    finally
        close(ac)
    end

    shortlist
end

function semantic(settings, entries::WETQueue, text::AbstractString; capacity=10)
    shortlist = WETQueue(capacity, eltype(entries))
    isempty(entries) && return shortlist
    source = embedding(query(text); vecpath=settings["embedding"]["model"])

    while !isempty(entries)
        insert!(shortlist, score(source, best!(entries)))
    end

    shortlist
end

# --- Final Orchestration ---

append!(file, output::AbstractString) = isempty(output) ? file : (write(file, strip(output), "\n"); flush(file); file)

prompt(wet::WET) = string("URI: ", uri(wet), "\nLANGUAGE: ", language(wet), "\nSCORE: ", wet.score, "\n\n", content(wet))
prompt(wet::WET, ::Val{:local}) = string("SOURCE URL: ", uri(wet), "\nLANGUAGE: ", language(wet), "\nDISTANCE: ", wet.score, "\n\nPAGE EXCERPT:\n", content(wet))

wetstream(settings) = wets(settings["crawl"]["path"]; capacity=settings["pipeline"]["capacity"], wetroot=settings["crawl"]["root"], languages=settings["crawl"]["languages"])

function research(settings)
    raw_wets = wetstream(settings)
    candidates = harvest(settings["pipeline"]["keywords"], settings, raw_wets)

    Threads.@spawn begin
        T = eltype(candidates)
        shortlist = WETQueue(settings["pipeline"]["capacity"], T)
        emb = embedding(join(settings["pipeline"]["keywords"], " "); vecpath=settings["embedding"]["model"])

        requests = Channel{Union{Nothing, T}}(Threads.nthreads())
        responses = Channel{NamedTuple{(:wet, :text), Tuple{T, String}}}(Threads.nthreads())
        submitted, completed = Threads.Atomic{Int}(0), Threads.Atomic{Int}(0)

        consumer = Threads.@spawn for wet in requests
            wet === nothing && break
            response = request(; model=settings["llm"]["model"], systemprompt=settings["prompts"]["system"],
                input=string(settings["prompts"]["input"], "\n\n", prompt(wet)),
                baseurl=settings["llm"]["baseurl"], path=settings["llm"]["path"],
                password=settings["llm"]["password"], timeout=settings["llm"]["timeout"])
            put!(responses, (wet=wet, text=get_message(response)))
        end

        open(settings["output"]["path"], "a") do file
            for wet in relevant!(emb, candidates; capacity=Threads.nthreads()*10, threshold=1.0-settings["pipeline"]["threshold"])
                insert!(shortlist, wet)
                while !isempty(shortlist) && !isfull(requests)
                    put!(requests, best!(shortlist)); submitted[] += 1
                end
                while isready(responses)
                    result = take!(responses); completed[] += 1; append!(file, result.text)
                end
            end
            @info "Crawl exhausted. Extracting top results..." remaining=length(shortlist)
            while !isempty(shortlist) && !isfull(requests)
                put!(requests, best!(shortlist)); submitted[] += 1
            end
            while completed[] < submitted[]
                result = take!(responses); completed[] += 1; append!(file, result.text)
            end
        end
        put!(requests, nothing); wait(consumer)
        @info "Research complete."
    end
end

function research(settings, urls::Vector{<:AbstractString}, wetpath::AbstractString)
    Threads.@spawn begin
        source = seed(urls)
        candidates = harvest(settings, wets(wetpath; capacity=settings["pipeline"]["capacity"], languages=settings["crawl"]["languages"]), weights(source))
        retained = length(candidates)
        shortlist = semantic(settings, candidates, source)
        entries = length(shortlist)

        open(settings["output"]["path"], "w") do file
            @info "Local research shortlist ready." candidates=retained entries=entries outputpath=settings["output"]["path"]
            while !isempty(shortlist)
                wet = best!(shortlist)
                @info "Analyzing local page" uri=uri(wet) score=wet.score
                response = request(;
                    model=settings["llm"]["model"],
                    systemprompt=settings["prompts"]["local_system"],
                    input=string(settings["prompts"]["local_input"], "\n\n", prompt(wet, Val(:local))),
                    baseurl=settings["llm"]["baseurl"],
                    path=settings["llm"]["path"],
                    password=settings["llm"]["password"],
                    timeout=settings["llm"]["timeout"],
                )
                append!(file, get_message(response))
            end
        end

        @info "Local research complete." outputpath=settings["output"]["path"] entries=entries
    end
end