module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates, JSON, StringViews
using DataStructures: BinaryHeap
using HTTP: URI

export WET, WETQueue, wetURIs, wets, Configuration, Embedding, embedding, distance, complete, gettext, isrelevant, relevant!, best!, best, research


include("wetURIs.jl")
include("wets.jl")
include("Model2VecJlrs.jl")
include("scoring.jl")
include("queue.jl")
include("gettext.jl")
include("core.jl")
include("llm.jl")

end
