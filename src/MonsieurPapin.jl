module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates, JSON, StringViews
using DataStructures: BinaryHeap
using HTTP: URI
export URI
export WET, WETQueue, wetURIs, wets, Configuration, Embedding, embedding, distance, score, complete, translate, gettext, language, languages, isrelevant, relevant!, best!, best, research, harvest, semantic, append!, prompt, bootstrap, AC, simhash, Deduper, isduplicate


include("wetURIs.jl")
include("wets.jl")
include("RustWorker.jl")
using .RustWorker: AC
include("scoring.jl")
include("simhash.jl")
include("queue.jl")
include("gettext.jl")
include("core.jl")
include("llm.jl")

end
