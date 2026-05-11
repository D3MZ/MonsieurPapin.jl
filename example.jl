#!/usr/bin/env julia
using MonsieurPapin

settings = loadsettings()

# ── bootstrap ─────────────────────────────────────────────────────
keywords = seed_keywords(settings, [
    "https://www.investopedia.com/articles/active-trading/",
    "https://en.wikipedia.org/wiki/Technical_analysis",
])
query = join(keywords, " ")

# ── queues between stages ─────────────────────────────────────────
matches   = WETQueue(settings["keyword"]["capacity"],
                     WET{urilimit, contentlimit, languagelimit})
shortlist = WETQueue(settings["embedding"]["capacity"],
                     WET{urilimit, contentlimit, languagelimit})

# ── pipeline ──────────────────────────────────────────────────────
@sync begin
    @spawn keyword_score(
        simhash_filter(stream_wets(settings), settings),
        keywords, matches, settings)

    @spawn embedding_score(
        matches, query, shortlist, settings)

    @spawn extract_findings(
        shortlist, settings)
end
