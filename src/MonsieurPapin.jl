module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates, LinearAlgebra, DataStructures, JSON
using HTTP: URI

export WET, wetURIs, wets, Configuration, Embedding, embedding, LLM, complete, gettext, isrelevant, relevant!, frontier, drain!, best!, best, research


include("wetURIs.jl")
include("wets.jl")
include("fasttext.jl")
include("queue.jl")
include("llm.jl")
include("gettext.jl")
include("core.jl")

end
