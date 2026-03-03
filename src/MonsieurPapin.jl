module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates, LinearAlgebra
using HTTP: URI

export WET, wetURIs, wets, Configuration, Embedding, embedding, gettext, isrelevant, relevant!


include("core.jl")
include("wetURIs.jl")
include("wets.jl")
include("fasttext.jl")
include("gettext.jl")

end
