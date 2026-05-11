#!/usr/bin/env julia
using MonsieurPapin

settings = loadsettings()

# ── bootstrap: seed URLs → keywords ───────────────────────────────
keywords = seed_keywords(settings, [
    "https://www.investopedia.com/articles/active-trading/",
    "https://en.wikipedia.org/wiki/Technical_analysis",
])

# ── queues between stages ─────────────────────────────────────────
DefaultWET = WET{urilimit, contentlimit, languagelimit}
ac_q       = WETQueue(settings["keyword"]["capacity"],    DefaultWET)
embed_q    = WETQueue(settings["embedding"]["capacity"],  DefaultWET)

# ── pipeline: each stage runs independently ───────────────────────
t1 = @spawn keyword_score(
    simhash_filter(stream_wets(settings), settings),
    keywords, ac_q, settings)

t2 = @spawn embedding_score(
    ac_q, join(keywords, " "), embed_q, settings)

t3 = @spawn extract_findings(
    embed_q, settings)

wait.([t1, t2, t3])
