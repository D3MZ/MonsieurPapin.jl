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
