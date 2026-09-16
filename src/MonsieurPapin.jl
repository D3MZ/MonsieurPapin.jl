module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates, JSON, StringViews
using HTTP: URI
export URI
export WET, BoundedPriorityQueue, SeenSet, AC, Embedding
export wets, wetpaths, research, select, extract
export embedding, distance, similarity, isrelevant, score, simhash
export LLMBackend, OpenAIEndpoint, PiRPC, CodexAppServer, UsageMonitor, NoUsage, llm, usage, request, message, extractkeywords
export fetchtext, plaintext, language, languages, prompt


include("wetpaths.jl")
include("wets.jl")
include("ahocorasick.jl")
include("scoring.jl")
include("http.jl")
include("simhash.jl")
include("queue.jl")
include("text.jl")
include("llm.jl")
include("core.jl")

end