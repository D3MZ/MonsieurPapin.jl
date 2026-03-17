module RustWorker

using JlrsCore
using JlrsCore.Wrap

const loaded = Ref(false)

root() = dirname(@__DIR__)
cargo() = something(Sys.which("cargo"), joinpath(homedir(), ".cargo", "bin", "cargo"))
worker() = joinpath(root(), "deps", "model2vec_rs_worker")
libraryname() = Sys.isapple() ? "libmodel2vec_rs_worker.dylib" : Sys.iswindows() ? "model2vec_rs_worker.dll" : "libmodel2vec_rs_worker.so"
library() = joinpath(worker(), "target", "release", libraryname())

function build()
    isfile(library()) && return library()
    Base.run(setenv(Cmd(`$(cargo()) build --release`; dir=worker()), merge(copy(ENV), Dict(
        "JULIA_PROJECT" => root(),
        "JLRS_JULIA_DIR" => dirname(Sys.BINDIR),
        "CC" => something(Sys.which("cc"), Sys.which("clang")),
    ))))
    library()
end

function load()
    loaded[] && return nothing
    Base.invokelatest(JlrsCore.Wrap.wrapmodule, build(), :model2vec_rs_worker_init_fn, @__MODULE__, @__FILE__, nothing)
    Base.invokelatest(JlrsCore.Wrap.initialize_julia_module, @__MODULE__)
    loaded[] = true
    nothing
end

function __init__() end

binding(name::Symbol) = Base.invokelatest(getproperty, @__MODULE__, name)
call(name::Symbol, args...) = Base.invokelatest(binding(name), args...)

mutable struct Model
    handle::UInt
end

mutable struct AC{T}
    handle::UInt
end

function AC(patterns::Vector{<:AbstractString})
    load()
    joined = join(patterns, '\x1F')
    entry = AC{UInt32}(call(:build_aho_corasick, joined))
    finalizer(close, entry)
    entry
end

function AC(weights::AbstractDict{<:AbstractString,<:Real})
    load()
    patterns = collect(keys(weights))
    values = Float64[weights[pattern] for pattern in patterns]
    entry = AC{Float64}(call(:build_weighted_aho_corasick, join(patterns, '\x1F'), values))
    finalizer(close, entry)
    entry
end

function Base.close(entry::AC)
    entry.handle == 0 && return entry
    call(:close_aho_corasick, entry.handle)
    entry.handle = 0
    entry
end

function score(entry::AC{UInt32}, pointer::Ptr{UInt8}, length::Integer)::UInt32
    call(:match_aho_corasick, entry.handle, UInt(pointer), UInt(length))
end

function score(entry::AC{Float64}, pointer::Ptr{UInt8}, length::Integer)::Float64
    call(:match_weighted_aho_corasick, entry.handle, UInt(pointer), UInt(length))
end

function score(entry::AC, text::AbstractString)
    score(entry, pointer(text), ncodeunits(text))
end

function open(model::AbstractString, query::AbstractString)
    load()
    entry = Model(call(:openstate, String(model), String(query)))
    finalizer(close, entry)
    entry
end

function Base.close(entry::Model)
    entry.handle == 0 && return entry
    call(:closestate, entry.handle)
    entry.handle = 0
    entry
end

function score!(scores, pointers, lengths, entry::Model)
    load()
    call(Symbol("scorebatch!"), entry.handle, pointers, lengths, scores)
    scores
end

function score(text::AbstractString, entry::Model)
    load()
    scores = Vector{Float64}(undef, 1)
    pointers = UInt[]
    lengths = UInt[]
    value = String(text)

    GC.@preserve value pointers lengths scores begin
        resize!(pointers, 1)
        resize!(lengths, 1)
        pointers[firstindex(pointers)] = UInt(pointer(codeunits(value)))
        lengths[firstindex(lengths)] = ncodeunits(value)
        score!(scores, pointers, lengths, entry)
    end

    first(scores)
end

end
