# Julia IO allocations
# How do `eachline` allocations scale with line count for raw IO and gunzip IO?
#
# Results
# +----------------------+--------+-----------+-----------+------------+
# | metric               | 1K raw | 1K gunzip | 100K raw  | 100K gunzip|
# +----------------------+--------+-----------+-----------+------------+
# | allocs total         | 5002   | 6124      | 500002    | 619790     |
# | bytes total          | 435392 | 522800    | 44401904  | 46437360   |
# | allocs per line      | 5.002  | 6.124     | 5.00002   | 6.1979     |
# | bytes per line       | 435.392| 522.8     | 444.01904 | 464.3736   |
# | overhead allocs/line | 0.0    | 1.122     | 0.0       | 1.19788    |
# | overhead bytes/line  | 0.0    | 87.408    | 0.0       | 20.35456   |
# +----------------------+--------+-----------+-----------+------------+
# commoncrawl wet uri paths to compressed zips of streamed wet pages is 100K via `data/wet.paths.gz`.

using BenchmarkTools, CodecZlib, Logging, Random, Statistics

function urls(count)
    generator = MersenneTwister(1)
    ["https://example.com/$(index)/$(randstring(generator, rand(generator, 1:100)))" for index in 1:count]
end
sample(entries) = join(entries, "\n") * "\n"
stream(data) = IOBuffer(data)
compressed(entries) = transcode(GzipCompressor, codeunits(sample(entries)))
function consume(io)
    total = 0
    for line in eachline(io)
        total += ncodeunits(line)
    end
    total
end

measure(data) = @benchmark begin
    buffer = stream($data)
    consume(buffer)
end
measuregunzip(data) = @benchmark begin
    buffer = stream($data)
    gunzip = GzipDecompressorStream(buffer)
    consume(gunzip)
end

summarize(lines, raw, data, rawtrial, gunziptrial) = (
    lines=lines,
    rawbytes=ncodeunits(raw),
    compressedbytes=length(data),
    rawmedian=median(rawtrial.times),
    rawallocations=rawtrial.allocs,
    rawbytesused=rawtrial.memory,
    rawperline=rawtrial.allocs / lines,
    rawbytesperline=rawtrial.memory / lines,
    gunzipmedian=median(gunziptrial.times),
    gunzipallocations=gunziptrial.allocs,
    gunzipbytesused=gunziptrial.memory,
    gunzipperline=gunziptrial.allocs / lines,
    gunzipbytesperline=gunziptrial.memory / lines,
    overheadallocations=gunziptrial.allocs - rawtrial.allocs,
    overheadbytes=gunziptrial.memory - rawtrial.memory,
    overheadperline=(gunziptrial.allocs - rawtrial.allocs) / lines,
    overheadbytesperline=(gunziptrial.memory - rawtrial.memory) / lines,
)

function benchmark(lines)
    entries = urls(lines)
    raw = sample(entries)
    data = compressed(entries)
    rawtrial = measure(raw)
    gunziptrial = measuregunzip(data)

    @info "Benchmarking eachline" lines rawbytes=ncodeunits(raw) compressedbytes=length(data)
    display(rawtrial)
    display(gunziptrial)
    result = summarize(lines, raw, data, rawtrial, gunziptrial)
    @info "Raw stream allocations" lines=result.lines allocations=result.rawallocations bytes=result.rawbytesused perline=result.rawperline bytesperline=result.rawbytesperline
    @info "Gunzip stream allocations" lines=result.lines allocations=result.gunzipallocations bytes=result.gunzipbytesused perline=result.gunzipperline bytesperline=result.gunzipbytesperline
    @info "Gunzip overhead" lines=result.lines allocations=result.overheadperline bytes=result.overheadbytesperline
    result
end

function run(counts=(10^3, 10^5))
    results = map(benchmark, counts)
    @info "Scaling summary" counts=collect(counts)
    foreach(result -> @info(
        "Scale",
        lines=result.lines,
        rawallocations=result.rawallocations,
        rawbytes=result.rawbytesused,
        gunzipallocations=result.gunzipallocations,
        gunzipbytes=result.gunzipbytesused,
        overheadtotalbytes=result.overheadbytes,
        rawperline=result.rawperline,
        gunzipperline=result.gunzipperline,
        overheadallocations=result.overheadperline,
        overheadbytes=result.overheadbytesperline,
    ), results)
end

run()
