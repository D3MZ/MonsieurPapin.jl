#!/usr/bin/env julia
using MonsieurPapin

settings = loadsettings()

# End-to-end run: bootstrap multilingual trading keywords + a semantic query from the seed URLs
# (settings["pipeline"]["seeds"]) via the LLM, then stream the configured Common Crawl archive
# through the waterfall (keyword -> dedup -> embedding -> LLM) and write English findings to
# settings["output"]["path"] (overwritten each run). research() bootstraps synchronously, then
# returns a background task running the pipeline; wait for it to finish.
wait(research(settings))
