module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates, JSON, StringViews
using DataStructures: BinaryHeap
using HTTP: URI

export WET, WETQueue, wetURIs, wets, Configuration, Embedding, embedding, distance, score, complete, gettext, isrelevant, relevant!, best!, best, research, AC, DAAC, simhash, Deduper, isduplicate


include("wetURIs.jl")
include("wets.jl")
include("RustWorker.jl")
using .RustWorker: AC, DAAC, ismatch
include("scoring.jl")
include("dedupe.jl")
include("queue.jl")
include("gettext.jl")
include("core.jl")
include("llm.jl")

end
