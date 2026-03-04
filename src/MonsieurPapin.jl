module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates, LinearAlgebra, DataStructures
using HTTP: URI

export WET, wetURIs, wets, Configuration, Embedding, embedding, gettext, isrelevant, relevant!, frontier, drain!, best!, best, research


include("wetURIs.jl")
include("wets.jl")
include("fasttext.jl")
include("queue.jl")
include("gettext.jl")
include("core.jl")

end
