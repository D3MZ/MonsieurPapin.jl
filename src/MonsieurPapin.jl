module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates, DataStructures, JSON, StringViews
using HTTP: URI

export WET, wetURIs, wets, Configuration, Embedding, embedding, distance, complete, gettext, isrelevant, relevant!, frontier, drain!, best!, best, research


include("wetURIs.jl")
include("wets.jl")
include("Model2VecJlrs.jl")
include("scoring.jl")
include("queue.jl")
include("gettext.jl")
include("core.jl")
include("llm.jl")

end
