module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates, JSON, StringViews, TOML
using DataStructures: BinaryHeap
using HTTP: URI
export URI
export WET, WETQueue, wetURIs, wets, loadsettings, Embedding, embedding, distance, score, request, fetchtext, gettext, language, languages, isrelevant, relevant!, best!, best, research, harvest, semantic, append!, prompt, AC, simhash, Deduper, isduplicate
export get_message, keywords, summary


include("wetURIs.jl")
include("wets.jl")
include("RustWorker.jl")
using .RustWorker: AC
include("scoring.jl")
include("http.jl")
include("simhash.jl")
include("queue.jl")
include("core.jl")
include("llm.jl")

end