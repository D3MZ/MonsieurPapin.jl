using MonsieurPapin, BenchmarkTools, Libdl, Test

pathwets = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
pathvectors = joinpath(dirname(@__DIR__), "data", "wiki-news-300d-1M.vec")
modelname = "minishlab/potion-base-8M"
query = "cat dog"

count(iterable) = sum(_ -> 1, iterable)
rate(records, seconds) = round(records / seconds)
cargo() = joinpath(homedir(), ".cargo", "bin", "cargo")
worker() = joinpath(dirname(@__DIR__), "research", "model2vec_rs_worker")
binary() = joinpath(worker(), "target", "release", "model2vec_rs_worker")
libraryname() = Sys.isapple() ? "libmodel2vec_rs_worker.dylib" : Sys.iswindows() ? "model2vec_rs_worker.dll" : "libmodel2vec_rs_worker.so"
library() = joinpath(worker(), "target", "release", libraryname())
const loaded = Ref{Ptr{Nothing}}(C_NULL)

struct Pool
    workers::Vector{Base.Process}
    available::Channel{Base.Process}
end

mutable struct Bridge
    handle::Ptr{Cvoid}
end

struct BridgePool
    states::Vector{Bridge}
    available::Channel{Bridge}
end

function build()
    Base.run(Cmd(`$(cargo()) build --release`; dir=worker()))
end

function openlibrary()
    if loaded[] == C_NULL
        ENV["RAYON_NUM_THREADS"] = "1"
        ENV["TOKENIZERS_PARALLELISM"] = "false"
        loaded[] = Libdl.dlopen(library())
    end
    loaded[]
end

symbol(name) = Libdl.dlsym(openlibrary(), name)

function command(model, text)
    setenv(Cmd([binary()]), Dict(
        "MONSIEURPAPIN_MODEL" => model,
        "MONSIEURPAPIN_QUERY" => text,
        "RAYON_NUM_THREADS" => "1",
        "TOKENIZERS_PARALLELISM" => "false",
    ))
end

function openpool(model, text)
    workers = [open(command(model, text), "r+") for _ in 1:Threads.nthreads()]
    available = Channel{Base.Process}(length(workers))
    foreach(worker -> put!(available, worker), workers)
    Pool(workers, available)
end

function openbridge(model, text)
    handle = GC.@preserve model text begin
        ccall(
            symbol(:model2vec_open),
            Ptr{Cvoid},
            (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
            pointer(codeunits(model)),
            ncodeunits(model),
            pointer(codeunits(text)),
            ncodeunits(text),
        )
    end
    handle == C_NULL && throw(ErrorException("unable to open model2vec bridge"))
    state = Bridge(handle)
    finalizer(close, state)
    state
end

function openbridges(model, text)
    states = [openbridge(model, text) for _ in 1:Threads.nthreads()]
    available = Channel{Bridge}(length(states))
    foreach(state -> put!(available, state), states)
    BridgePool(states, available)
end

function Base.close(pool::Pool)
    foreach(close, pool.workers)
    pool
end

function Base.close(state::Bridge)
    state.handle == C_NULL && return state
    ccall(symbol(:model2vec_close), Cvoid, (Ptr{Cvoid},), state.handle)
    state.handle = C_NULL
    state
end

function Base.close(pool::BridgePool)
    foreach(close, pool.states)
    pool
end

contentoffset(::Type{T}) where {T<:WET} = fieldoffset(T, 2) + fieldoffset(fieldtype(T, 2), 1)

function writecontent(worker, wet::T) where {T<:WET}
    write(worker, string(wet.content.length, "\n"))
    reference = Ref(wet)
    GC.@preserve reference Base.unsafe_write(worker, Ptr{UInt8}(Base.unsafe_convert(Ptr{T}, reference)) + contentoffset(T), wet.content.length)
    worker
end

function distance(worker, wet::WET)
    write(worker, "1\n")
    writecontent(worker, wet)
    flush(worker)
    parse(Float64, chomp(readline(worker)))
end

acquire(pool::Pool) = take!(pool.available)
release!(pool::Pool, worker) = put!(pool.available, worker)
acquire(pool::BridgePool) = take!(pool.available)
release!(pool::BridgePool, state) = put!(pool.available, state)

function score(pool::Pool, wet::WET)
    worker = acquire(pool)
    try
        MonsieurPapin.scored(wet, distance(worker, wet))
    finally
        release!(pool, worker)
    end
end

function relevant!(pool::Pool, pages::Channel{T}; capacity=Threads.nthreads() * 10, threshold=0.0) where {T<:WET}
    Channel{T}(capacity) do filtered
        Threads.foreach(pages) do wet
            candidate = score(pool, wet)
            candidate.score <= 1.0 - threshold && put!(filtered, candidate)
        end
    end
end

function score!(scores, pointers, lengths, state::Bridge, batch)
    resize!(scores, length(batch))
    resize!(pointers, length(batch))
    resize!(lengths, length(batch))

    status = GC.@preserve batch pointers lengths scores begin
        foreach(eachindex(batch)) do i
            pointers[i] = Ptr{UInt8}(pointer(batch, i)) + contentoffset(eltype(batch))
            lengths[i] = batch[i].content.length
        end

        ccall(
            symbol(:model2vec_score_batch),
            Cint,
            (Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Ptr{Csize_t}, Csize_t, Ptr{Float64}),
            state.handle,
            pointer(pointers),
            pointer(lengths),
            length(batch),
            pointer(scores),
        )
    end
    status == 0 || throw(ErrorException("model2vec batch failed"))
    scores
end

function publish!(filtered, batch, scores, threshold)
    foreach(eachindex(batch, scores)) do i
        candidate = MonsieurPapin.scored(batch[i], scores[i])
        candidate.score <= 1.0 - threshold && put!(filtered, candidate)
    end
    empty!(batch)
    filtered
end

function publish!(filtered, batch, scores, pointers, lengths, state::Bridge, threshold)
    score!(scores, pointers, lengths, state, batch)
    publish!(filtered, batch, scores, threshold)
    filtered
end

function relevant!(pool::BridgePool, pages::Channel{T}; capacity=Threads.nthreads() * 10, threshold=0.0, batchsize=64) where {T<:WET}
    Channel{T}(capacity) do filtered
        tasks = [
            Threads.@spawn begin
                state = acquire(pool)
                batch = T[]
                scores = Float64[]
                pointers = Ptr{UInt8}[]
                lengths = Csize_t[]

                try
                    for wet in pages
                        push!(batch, wet)
                        length(batch) == batchsize || continue
                        publish!(filtered, batch, scores, pointers, lengths, state, threshold)
                    end

                    isempty(batch) || publish!(filtered, batch, scores, pointers, lengths, state, threshold)
                finally
                    release!(pool, state)
                end
            end
            for _ in 1:Threads.nthreads()
        ]
        foreach(wait, tasks)
    end
end

function summarize(entries)
    total = 0.0
    sumsq = 0.0
    low = Inf
    high = -Inf
    records = 0

    for wet in entries
        total += wet.score
        sumsq += wet.score * wet.score
        low = min(low, wet.score)
        high = max(high, wet.score)
        records += 1
    end

    mean = total / records
    (
        count=records,
        mean=mean,
        std=sqrt(max(sumsq / records - mean * mean, 0.0)),
        low=low,
        high=high,
    )
end

function run(path=pathwets, vecpath=pathvectors, model=modelname, text=query)
    isfile(binary()) && isfile(library()) || build()

    records = count(wets(path))
    source = embedding(text; vecpath)
    pool = openpool(model, text)
    bridgepool = openbridges(model, text)

    try
        fasttextstats = summarize(MonsieurPapin.relevant!(source, wets(path); threshold=-Inf))
        subprocessstats = summarize(relevant!(pool, wets(path); threshold=-Inf))
        sharedstats = summarize(relevant!(bridgepool, wets(path); threshold=-Inf))

        @test fasttextstats.count == subprocessstats.count == sharedstats.count
        @test isapprox(subprocessstats.mean, sharedstats.mean; atol=1e-12)
        @test isapprox(subprocessstats.std, sharedstats.std; atol=1e-12)
        @test isapprox(subprocessstats.low, sharedstats.low; atol=1e-12)
        @test isapprox(subprocessstats.high, sharedstats.high; atol=1e-12)

        @info "Julia fasttext scores" fasttextstats...
        @info "Rust model2vec subprocess scores" subprocessstats... model = model
        @info "Rust model2vec inprocess scores" sharedstats... model = model

        trialfasttext = @benchmark sum(_ -> 1, MonsieurPapin.relevant!($source, wets($path); threshold=0.0))
        timefasttext = BenchmarkTools.median(trialfasttext).time / 1e9
        display(trialfasttext)
        @info "Julia fasttext" processed_records = records passed_records = count(MonsieurPapin.relevant!(source, wets(path); threshold=0.0)) records_per_second = rate(records, timefasttext)

        trialsubprocess = @benchmark sum(_ -> 1, relevant!($pool, wets($path); threshold=0.0))
        timesubprocess = BenchmarkTools.median(trialsubprocess).time / 1e9
        display(trialsubprocess)
        @info "Rust model2vec subprocess" processed_records = records passed_records = count(relevant!(pool, wets(path); threshold=0.0)) records_per_second = rate(records, timesubprocess) model = model

        trialshared = @benchmark sum(_ -> 1, relevant!($bridgepool, wets($path); threshold=0.0))
        timeshared = BenchmarkTools.median(trialshared).time / 1e9
        display(trialshared)
        @info "Rust model2vec inprocess" processed_records = records passed_records = count(relevant!(bridgepool, wets(path); threshold=0.0)) records_per_second = rate(records, timeshared) model = model
    finally
        close(pool)
        close(bridgepool)
    end
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && run()
