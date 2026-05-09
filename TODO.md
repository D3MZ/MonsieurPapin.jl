# TODO

## Completed

- [x] Zero-allocation WET parsing
- [x] Aho-Corasick matching through Rust FFI
- [x] SimHash near-duplicate primitives
- [x] Model2Vec embedding scoring through Rust
- [x] Fixed-capacity `WETQueue`
- [x] Language-aware WET filtering
- [x] Multilingual embedding model support
- [x] Realtime waterfall dispatch in runnable scripts
- [x] LLM bootstrap prototype
- [x] OpenAI-compatible LLM integration

## Architecture
- [ ] Convert keyword harvest from a streaming threshold filter to a competing `WETQueue`.
- [ ] Convert deduplication from a hard filter to a soft SimHash-ranked queue.
- [ ] Add deduplication to `scripts/live_march.jl`.
- [ ] Wire semantic scoring to pull from the keyword queue with `best!()`.
- [ ] Refactor `semantic()` into a streaming primitive.
- [ ] Add batch popping for `WETQueue`, such as `bestn!(queue, n)`.
- [ ] Generate multilingual keyword sets during bootstrap.

## Robustness

- [ ] Make bootstrap JSON extraction resilient to code fences and extra text.
- [ ] Merge bootstrap keywords with seed-page term weights in `scripts/live_march.jl`.
- [ ] Support multiple LLM consumers.
- [ ] Retry seed page fetches with exponential backoff.

## Testing and Packaging

- [ ] Add small self-contained WARC fixtures for CI.
- [ ] Continue optimizing Model2Vec scoring on raw bytes.


## Ignore - Notes
Add the following functions in llm.jl 
1. keywords(text; limitinput=characters) = gets keywords from text sent to llm #limit will be `first(text, limitinput)` that's sent to llm's input
2. summary(text, limit=140) = gets summary from llm #this tells the LLM to create a summary of 140 characters as default.

then you can write simple composable processes

seedpages = [fetch(url) for url in seedurls]
keywords = [keywords(page) for page in seedpages] |> flatten |> unique
summaries = [summary(page) for page in seedpages] |> flatten |> unique

instead of below:
```julia
seeds_text = join([MonsieurPapin.fetchseed(url) for url in seed_urls], "\n\n")
response = MonsieurPapin.request(;
    model=settings["llm"]["model"],
    systemprompt=settings["prompts"]["bootstrap_system"],
    input="""Task: Find trading strategies that can be expressed as pseudo-code with clear entry/exit rules

Seed Content:
$(first(seeds_text, 2000))""",
    baseurl=settings["llm"]["baseurl"],
    path=settings["llm"]["path"],
    password=settings["llm"]["password"],
    timeout=settings["llm"]["timeout"],
)
data = JSON.parse(MonsieurPapin.get_message(response))
settings["pipeline"]["keywords"] = data["keywords"]
settings["pipeline"]["query"] = data["query"]
@info "Bootstrap complete." query=settings["pipeline"]["query"] keywords_count=length(settings["pipeline"]["keywords"])
```

this will call the LLM twice per URL, but it'll focus the LLM to do 1 job at a time and not a large cost given the entire runtime.


----

move this from core.jl to gettext.jl fetchtext(url)
```julia
function fetchseed(url::AbstractString)
    try
        response = HTTP.get(String(url); timeout=30)
        return gettext(String(response.body))
    catch e
        @warn "Failed to fetch $url: $e"
        return ""
    end
end
```

rename gettext.jl to http as that's all this is doing. Http and helpers.