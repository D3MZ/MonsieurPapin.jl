module MonsieurPapin

using HTTP, CodecZlib, BufferedStreams, Dates
using HTTP: URI

export WET, wetURIs, wets

const capacity = 10
const wetroot = "https://data.commoncrawl.org/"

include("wetURIs.jl")
include("wets.jl")

end
