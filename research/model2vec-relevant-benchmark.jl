using MonsieurPapin, BenchmarkTools, JSON, Test

pathwets = joinpath(dirname(@__DIR__), "data", "warc.wet.gz")
modelname = "minishlab/potion-multilingual-128M"
query = "cat dog"

count(iterable) = sum(_ -> 1, iterable)
rate(records, seconds) = round(records / seconds)
cargo() = something(Sys.which("cargo"), joinpath(homedir(), ".cargo", "bin", "cargo"))
worker() = joinpath(dirname(@__DIR__), "deps", "model2vec_rs_worker")
diagnosticbinary() = joinpath(worker(), "target", "release", "diagnose_parallelism")
libraryname() = Sys.isapple() ? "libmodel2vec_rs_worker.dylib" : Sys.iswindows() ? "model2vec_rs_worker.dll" : "libmodel2vec_rs_worker.so"
library() = joinpath(worker(), "target", "release", libraryname())

needsbuild() = !isfile(diagnosticbinary()) || !isfile(library())

function build()
    Base.run(setenv(Cmd(`$(cargo()) build --release`; dir=worker()), merge(copy(ENV), Dict(
        "JULIA_PROJECT" => dirname(@__DIR__),
        "JLRS_JULIA_DIR" => dirname(Sys.BINDIR),
        "CC" => something(Sys.which("cc"), Sys.which("clang")),
    ))))
    worker()
end

needsbuild() && build()

contentoffset(::Type{T}) where {T<:WET} = fieldoffset(T, 2) + fieldoffset(fieldtype(T, 2), 1)

function writecontent(io, wet::T) where {T<:WET}
    write(io, string(wet.content.length, "\n"))
    reference = Ref(wet)
    GC.@preserve reference Base.unsafe_write(io, Ptr{UInt8}(Base.unsafe_convert(Ptr{T}, reference)) + contentoffset(T), wet.content.length)
    io
end

function collectwets(path; limit=64)
    batch = WET[]

    for wet in wets(path)
        push!(batch, wet)
        length(batch) == limit && return batch
    end

    batch
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

function diagnosticcommand(model; rayon="8", parallelism="true")
    setenv(Cmd([diagnosticbinary()]), merge(copy(ENV), Dict(
        "MONSIEURPAPIN_MODEL" => model,
        "RAYON_NUM_THREADS" => rayon,
        "TOKENIZERS_PARALLELISM" => parallelism,
    )))
end

function inspectparallelism(model, path; limit=64, rayon="8", parallelism="true")
    entry = open(diagnosticcommand(model; rayon, parallelism), "r+")
    try
        batch = collectwets(path; limit)
        write(entry, string(length(batch), "\n"))
        foreach(wet -> writecontent(entry, wet), batch)
        flush(entry)
        close(entry.in)
        pairs = JSON.parse(chomp(read(entry, String)))
        (; (Symbol(key) => value for (key, value) in pairs)...)
    finally
        close(entry)
    end
end

function run(path=pathwets, model=modelname, text=query)
    records = count(wets(path))
    source = embedding(text; vecpath=model)
    diagnostic = inspectparallelism(model, path)
    scores = summarize(MonsieurPapin.relevant!(source, wets(path); threshold=-Inf))

    @test scores.count == records

    @info "Model2Vec diagnostic" diagnostic... model = model
    @info "Model2Vec scores" scores... model = model

    trial = @benchmark sum(_ -> 1, MonsieurPapin.relevant!($source, wets($path); threshold=0.0))
    seconds = BenchmarkTools.median(trial).time / 1e9
    display(trial)
    @info "Model2Vec relevant!" processed_records = records passed_records = count(MonsieurPapin.relevant!(source, wets(path); threshold=0.0)) records_per_second = rate(records, seconds) model = model
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && run()
