module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates, LinearAlgebra
using HTTP: URI

export WET, wetURIs, wets, Configuration, Embedding, embedding, gettext, isrelevant, relevant!, research


include("wetURIs.jl")
include("wets.jl")
include("fasttext.jl")
include("gettext.jl")
include("core.jl")

end
