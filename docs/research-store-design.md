# Research Store Design — atomic findings, merge-on-write, corroboration

Status: **proposal** (not yet implemented). Replaces the append-only `research.md` output with a
maintained knowledge base, while still rendering a `research.md` digest for easy review.

## 1. Why

The current output (`extract` → append to `research.md`) is an **append-only log**: every LLM
extraction is dumped in. Observed consequences on a real run (138 findings):

- **Duplication** — the same strategy extracted from many pages piles up as N copies (one SMA
  system recurred ~5×).
- **No corroboration signal** — a strategy seen on 50 reputable sites looks identical to one seen
  once on a content farm.
- **Poor navigability** — an 11k-line flat file that only grows over a multi-day crawl.

The fix is to treat findings as **memory**: atomic records, deduped/merged on write, scored by how
many independent sources corroborate them. This is the academically-grounded pattern (A-MEM atomic
notes; Mem0 ADD/UPDATE/DELETE; Zep/Graphiti dedup-before-insert + invalidate-don't-delete).

## 2. Architecture — three layers

1. **Episodic (raw, lossless):** every extraction event as-is — `{finding_text, source_url,
   crawl_timestamp, page_snippet}`. Append-only JSONL, never mutated. The audit trail.
2. **Semantic (distilled, deduped):** one **atomic record per distinct finding**, merged across
   sources. This is the canonical store and the thing we query. (Section 4.)
3. **Rendered digest:** `research.md` regenerated from the semantic layer, sorted by confidence —
   the human/phone-readable view. Derived, disposable.

Short-term agent context (the LLM's per-call window) is separate and out of scope here.

## 3. Directory layout

```
store/
  episodic.jsonl                # raw extraction events (append-only)
  findings/                     # atomic semantic records, sharded by id prefix
    a1/a1b2c3….md
    a1/a1d4e5….md
  index.md                      # one-line pointer per finding (navigable index)
  embeddings.bin                # finding-description vectors (for blocking); or in the DB
research.md                     # rendered digest (generated)
```

Sharding by the first 2 hex chars of the id keeps any one directory small across millions of files.

## 4. Atomic record schema (YAML frontmatter + body)

```markdown
---
id: f3a9c1e2…            # stable hash of the canonical_statement
canonical_statement: "Bollinger-band mean reversion: long when close < lower band(20,2) and RSI(14)<30; exit at middle band"
tags: [mean-reversion, bollinger, rsi, equities]
entities:
  indicators: [bollinger_bands, rsi, atr]
  instruments: []
  timeframe: "1h"
sources:                  # one entry per corroborating page
  - url: https://…
    domain: example.com
    crawl_ts: 2026-06-29T14:53:00Z
    snippet: "…"
corroboration_count: 5
distinct_domains: 4
confidence: 0.82          # derived (Section 6)
first_seen: 2026-06-29T14:53:00Z
last_updated: 2026-06-30T02:10:00Z
valid_from: 2026-06-29T14:53:00Z
valid_to: null            # set when superseded/contradicted (invalidate, don't delete)
superseded_by: null       # id of the record that replaced it
status: active            # active | archived | contradicted
---

- Entry rule(s): …
- Exit rule(s): …
- Parameters: …
- Pseudo-code: …
```

The body is the best (most complete) extraction seen; `sources[]` accumulates the rest.

## 5. Merge-on-write (the core loop)

Runs once per extracted finding, replacing the current `append to research.md` step.

```
function record!(store, finding, source):           # finding = LLM-extracted struct
    v = embedding(finding.canonical_statement)        # reuse in-process Model2Vec
    # 1. BLOCK: cheap candidate generation, never compare against everything
    cands = topk_ann(store, v; k=20) ∪ bm25(store, finding.canonical_statement; k=20)
    cands = filter(cands, same_tags_or_entities)      # metadata pre-filter
    # 2. MATCH: only on the shortlist
    best = argmax(cands, c -> cosine(v, c.embedding))
    if best !== nothing && cosine(v, best.embedding) ≥ τ_high
        same = llm_match(finding, best)               # "are these the same finding?" (cheap)
        if same == :same
            merge_source!(best, source); recompute_confidence!(best); return best
        elseif same == :contradicts                   # same entity, opposite claim
            invalidate!(best, superseded_by=new_id); # don't delete
            return create_record!(store, finding, source, v)
        end
    end
    # 3. NEW
    rec = create_record!(store, finding, source, v)
    autolink!(store, rec, cands)                       # A-MEM style soft links
    append_index_line!(store, rec)
    return rec
```

- **Blocking** keeps it O(shortlist), not O(all records).
- **LLM match** runs only on the ≥τ_high shortlist → cheap (findings are the thin end of the funnel).
- **Conflict → invalidate, not delete** (Zep bi-temporal): keep both with provenance.
- Thresholds `τ_high` (auto-merge candidate) tuned on a sample; everything below is treated as new.

## 6. Corroboration & confidence

Confidence is the domain analog of Generative Agents' "importance":

```
confidence = w1·saturate(distinct_domains)      # diversity matters more than repeats of one site
           + w2·mean(domain_authority(sources))  # e.g., CC web-graph harmonic-centrality rank
           + w3·recency(last_updated)
```

`distinct_domains` (not raw `corroboration_count`) is the primary term — 5 copies on one content
farm should not outrank 2 independent reputable sources. Domain authority can reuse Common Crawl's
own web-graph ranking (see the broader pipeline-quality note).

## 7. Retrieval

Hybrid, with a reranker on the shortlist:

1. Metadata pre-filter (tags/entities/status=active/date).
2. BM25 (exact tokens — tickers, indicator names) **+** dense vector (paraphrase), fused with
   Reciprocal Rank Fusion.
3. Cross-encoder rerank top-50 → top-k.
4. Rank boost by `confidence` and recency.

## 8. Consolidation (background "sleep-time" pass)

Periodically (or at run end): re-cluster near-duplicates that slipped past τ_high, merge them,
summarize large clusters into higher-level findings, and **demote** stale/uncorroborated records to
`status: archived` (archive, never delete). Keeps the hot index clean over a multi-day crawl.

## 9. Rendering `research.md`

Pure function of the semantic layer: select `status==active`, sort by `confidence` desc, group by
top-level `tags`, emit each record's body + a "corroborated by N sources across M domains" line.
Regenerated on demand — the digest is never the source of truth.

## 10. Backend: build vs borrow

- **Phase 1 (no new infra, fits the file-oriented codebase):** atomic markdown files + append-only
  JSONL; **blocking via the existing in-process Model2Vec embeddings**; lexical via SQLite **FTS5**;
  **LLM match/merge via the existing `request()`** to the configured server. Everything stays in the
  current Julia + Rust-worker stack, zero external services. Ships the dedup/corroboration win first.
- **Phase 2 (scale/quality):** move the index to **Postgres + pgvector** (vector + BM25-ish lexical +
  relational provenance/metadata in one store, lowest ops) and add a managed **reranker** (Voyage/
  Cohere). Optionally evaluate **Graphiti** (temporal KG) if entity-resolution/invalidation wants a
  purpose-built engine — at the cost of a Neo4j dependency.
- **Build custom regardless:** the atomic-record format, the merge-on-write policy, and the
  corroboration scoring — no framework does these for "trading-strategy findings."
- **Don't** adopt MemGPT/Letta or LangChain conversational memory for this — they target an *agent's*
  own working memory, a different problem.

## 11. Integration into the current pipeline

- `core.jl::extract` currently drains the queue and appends to the output file. Replace the append
  with `record!(store, finding, source)`; render `research.md` from the store on completion (and
  periodically, so a live tail is still useful).
- Embeddings for blocking reuse `RustWorker`/Model2Vec already loaded for the embedding stage.
- `settings.toml`: add `[store]` (path, `τ_high`, confidence weights, render interval).
- Generality: the schema/`canonical_statement`/tags are topic-agnostic — for a non-trading topic only
  the extraction prompt and tag vocabulary change.

## 12. Rollout

1. Episodic JSONL + atomic-file writer + `index.md` + `research.md` renderer (no merge yet) — proves
   the format, identical findings to today.
2. Merge-on-write with Model2Vec blocking + LLM match + `sources[]`/corroboration. **This is the
   quality win.**
3. Confidence scoring + domain authority (CC web-graph) + consolidation pass.
4. Phase-2 backend (pgvector + reranker) if scale/precision demands.

## 13. Open questions / risks

- `τ_high` calibration: too low merges distinct strategies; too high lets dups through. Tune on a
  labeled sample; log near-threshold decisions.
- LLM-match cost at high finding volume — bounded by blocking, but watch it.
- Contradiction detection ("same entity, opposite claim") is the fuzziest step; may start as
  "flag for review" rather than auto-invalidate.
- Vendor memory benchmarks (Mem0 vs Zep LOCOMO/LongMemEval) are mutually disputed — don't pick a
  backend on headline scores; pilot on our own corpus.

## 14. References

- A-MEM (atomic notes + evolution): https://arxiv.org/abs/2502.12110
- Mem0 (ADD/UPDATE/DELETE): https://mem0.ai · ECAI 2025
- Zep/Graphiti (temporal KG, dedup-before-insert, invalidate-don't-delete): https://arxiv.org/abs/2501.13956 · https://github.com/getzep/graphiti
- Generative Agents (recency+importance+relevance, reflection): https://arxiv.org/abs/2304.03442
- MemGPT/Letta (self-editing core memory — for the *agent's* memory, not this store): https://arxiv.org/abs/2310.08560
- Entity resolution w/ LLMs: https://arxiv.org/pdf/2405.16884
- Hybrid retrieval + reranking: https://www.digitalapplied.com/blog/hybrid-search-bm25-vector-reranking-reference-2026
- Memory survey: https://arxiv.org/pdf/2505.00675
- Hermes Agent (pluggable memory providers): https://github.com/NousResearch/hermes-agent
