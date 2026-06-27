#!/usr/bin/env julia
using MonsieurPapin

settings = loadsettings()

# Stream the configured Common Crawl archive through the waterfall (dedup -> keyword -> embedding
# -> LLM) and append findings to settings["output"]["path"]. research() returns immediately and
# runs the pipeline on a background task; wait for it to finish.
wait(research(settings))
