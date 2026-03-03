module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates, LinearAlgebra
using HTTP: URI

export WET, wetURIs, wets, datadir, Embedding, embedding, isrelevant

const capacity = 10
const wetroot = "https://data.commoncrawl.org/"
const datadir = joinpath(dirname(@__DIR__), "data")

include("wetURIs.jl")
include("wets.jl")
include("fasttext.jl")

end
