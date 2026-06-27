module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates, JSON, StringViews, TOML
using DataStructures: BinaryHeap
import DataStructures: heapify!
using HTTP: URI
export URI
export WET, BoundedPriorityQueue, SeenSet, AC, Embedding
export wets, wetpaths, loadsettings, research, select, extract
export embedding, distance, similarity, isrelevant, score, simhash
export request, message, extractkeywords, summarize, fetchtext, plaintext, language, languages, prompt


include("wetpaths.jl")
include("wets.jl")
include("RustWorker.jl")
include("ahocorasick.jl")
include("scoring.jl")
include("http.jl")
include("simhash.jl")
include("queue.jl")
include("text.jl")
include("core.jl")
include("llm.jl")

end