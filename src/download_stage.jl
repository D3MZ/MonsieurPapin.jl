using CodecZlib
using Dates
using HTTP
using ProgressMeter

Base.@kwdef struct DownloadSettings
    crawlpath::String = "CC-MAIN-2025-01"
    ram::Float32 = 0.8f0
end

struct WARC
    uri::String
    date::DateTime
    language::String
    length::Int
    content::String
end

struct DownloadProgress
    completed_urls::Int
    total_urls::Int
    failed_urls::Int
end

Base.@kwdef mutable struct DownloadStats
    total_urls::Int
    completed_urls::Int = 0
    failed_urls::Int = 0
end

struct DownloadStage
    weturls::Channel{String}
    wetstreams::Channel{IO}
    warcs::Channel{WARC}
    tasks::Vector{Task}
    stats::DownloadStats
end

abstract type AbstractTransport end

struct HTTPTransport <: AbstractTransport
end

const commonCrawlBaseUrl = "https://data.commoncrawl.org"
const oneMiB = 1024 * 1024
const wetstreamBudgetMiB = 64
const warcDateFormats = (
    dateformat"yyyy-mm-ddTHH:MM:SS.sZ",
    dateformat"yyyy-mm-ddTHH:MM:SSZ",
)

function crawl_wet_paths_url(crawlpath::String)::String
    return "$(commonCrawlBaseUrl)/crawl-data/$(crawlpath)/wet.paths.gz"
end

function normalize_wet_url(path_or_url::AbstractString)::String
    value = String(path_or_url)
    startswith(value, "http://") && return value
    startswith(value, "https://") && return value
    return "$(commonCrawlBaseUrl)/$(value)"
end

function open_url_stream(::HTTPTransport, url::String)::IO
    stream = IOBuffer()
    response = HTTP.get(url; response_stream = stream)
    if response.status < 200 || response.status >= 300
        error("HTTP request failed for $(url): status $(response.status)")
    end
    seekstart(stream)
    return stream
end

function parse_warc_date(raw_value::String)::DateTime
    value = strip(raw_value)
    isempty(value) && return DateTime(0)

    for format in warcDateFormats
        try
            return DateTime(value, format)
        catch
        end
    end

    return DateTime(0)
end

function readline_or_nothing(io::IO)::Union{Nothing, String}
    eof(io) && return nothing
    line = readline(io)
    endswith(line, '\r') && return line[1:(end - 1)]
    return line
end

function read_warc_headers(io::IO)::Dict{String, String}
    headers = Dict{String, String}()

    while true
        line = readline_or_nothing(io)
        line === nothing && break
        isempty(line) && break

        separator_position = findfirst(':', line)
        separator_position === nothing && continue

        key = strip(line[1:(separator_position - 1)])
        value = strip(line[(separator_position + 1):end])
        headers[key] = value
    end

    return headers
end

function read_exact_bytes(io::IO, count::Int)::Vector{UInt8}
    count < 0 && throw(ArgumentError("Content-Length cannot be negative: $(count)"))

    bytes = Vector{UInt8}(undef, count)
    bytes_read = readbytes!(io, bytes, count)

    bytes_read == count || throw(EOFError())
    return bytes
end

function read_next_warc(io::IO)::Union{Nothing, WARC}
    while true
        version_line = readline_or_nothing(io)
        version_line === nothing && return nothing
        isempty(version_line) && continue
        startswith(version_line, "WARC/") || continue

        headers = read_warc_headers(io)
        content_length_raw = get(headers, "Content-Length", nothing)
        content_length_raw === nothing && throw(ArgumentError("Missing Content-Length header"))
        content_length = parse(Int, content_length_raw)

        payload = read_exact_bytes(io, content_length)

        uri = get(headers, "WARC-Target-URI", "")
        date = parse_warc_date(get(headers, "WARC-Date", ""))
        language = get(headers, "WARC-Identified-Content-Language", "")
        content = String(payload)

        return WARC(uri, date, language, content_length, content)
    end
end

function parse_warc_stream!(warcs::Channel{WARC}, io::IO)
    while true
        record = read_next_warc(io)
        record === nothing && return nothing
        put!(warcs, record)
    end
end

function parse_wet_paths(io::IO)::Vector{String}
    urls = String[]

    for raw_line in eachline(io)
        line = strip(raw_line)
        isempty(line) && continue
        push!(urls, normalize_wet_url(line))
    end

    return urls
end

function fetch_wet_urls(crawlpath::String; transport::AbstractTransport = HTTPTransport())::Vector{String}
    wet_paths_url = crawl_wet_paths_url(crawlpath)
    compressed_stream = open_url_stream(transport, wet_paths_url)
    decompressed_stream = GzipDecompressorStream(compressed_stream)

    try
        return parse_wet_paths(decompressed_stream)
    finally
        close(decompressed_stream)
        close(compressed_stream)
    end
end

function wetstreams_capacity(settings::DownloadSettings, total_memory_bytes::Int)::Int
    total_memory_bytes > 0 || throw(ArgumentError("total_memory_bytes must be positive"))

    clamped_ram = clamp(settings.ram, 0f0, 1f0)
    wetstream_budget_bytes = floor(Int, clamped_ram * total_memory_bytes)
    bytes_per_stream = wetstreamBudgetMiB * oneMiB
    return max(1, wetstream_budget_bytes ÷ bytes_per_stream)
end

function default_progress_callback(total_urls::Int; output::IO = stderr, dt::Float64 = 0.1)
    progress = Progress(total_urls; desc = "Download Stage", dt = dt, output = output)
    return function (download_progress::DownloadProgress)
        update!(
            progress,
            download_progress.completed_urls;
            showvalues = [(:failed, download_progress.failed_urls), (:total, download_progress.total_urls)],
        )

        if download_progress.completed_urls >= download_progress.total_urls
            finish!(progress)
        end

        return nothing
    end
end

function mark_url_finished!(
    stats::DownloadStats,
    lock_object::ReentrantLock,
    notify_progress::Function;
    failed::Bool = false,
)
    lock(lock_object) do
        stats.completed_urls += 1
        failed && (stats.failed_urls += 1)
        progress = DownloadProgress(stats.completed_urls, stats.total_urls, stats.failed_urls)
        notify_progress(progress)
    end

    return nothing
end

function parser_worker_loop!(
    wetstreams::Channel{IO},
    warcs::Channel{WARC},
    stats::DownloadStats,
    lock_object::ReentrantLock,
    notify_progress::Function,
)
    for compressed_stream in wetstreams
        failed = false

        try
            decompressed_stream = GzipDecompressorStream(compressed_stream)
            try
                parse_warc_stream!(warcs, decompressed_stream)
            finally
                close(decompressed_stream)
            end
        catch
            failed = true
        finally
            close(compressed_stream)
        end

        mark_url_finished!(stats, lock_object, notify_progress; failed = failed)
    end

    return nothing
end

function downloader_worker_loop!(
    weturls::Channel{String},
    wetstreams::Channel{IO},
    stats::DownloadStats,
    lock_object::ReentrantLock,
    notify_progress::Function,
    transport::AbstractTransport,
)
    for wet_url in weturls
        try
            stream = open_url_stream(transport, wet_url)
            put!(wetstreams, stream)
        catch
            mark_url_finished!(stats, lock_object, notify_progress; failed = true)
        end
    end

    return nothing
end

function Base.wait(stage::DownloadStage)
    for task in stage.tasks
        wait(task)
    end

    return stage
end

function start_download_stage(
    settings::DownloadSettings;
    embedding_batchsize::Int,
    progress_callback = nothing,
    transport::AbstractTransport = HTTPTransport(),
    total_memory_bytes::Int = Sys.total_memory(),
)::DownloadStage
    embedding_batchsize > 0 || throw(ArgumentError("embedding_batchsize must be positive"))

    wet_url_list = fetch_wet_urls(settings.crawlpath; transport = transport)
    total_urls = length(wet_url_list)

    weturls = Channel{String}(total_urls)
    wetstreams = Channel{IO}(wetstreams_capacity(settings, total_memory_bytes))
    warcs = Channel{WARC}(2 * embedding_batchsize)

    stats = DownloadStats(total_urls = total_urls)
    stats_lock = ReentrantLock()
    progress_handler = progress_callback === nothing ? default_progress_callback(total_urls) : progress_callback

    producer_task = @async begin
        for wet_url in wet_url_list
            put!(weturls, wet_url)
        end
        close(weturls)
    end

    download_worker_count = max(1, wetstreams.sz_max)
    downloader_tasks = [
        @async downloader_worker_loop!(
            weturls,
            wetstreams,
            stats,
            stats_lock,
            progress_handler,
            transport,
        ) for worker_index in 1:download_worker_count
    ]

    close_wetstreams_task = @async begin
        try
            for task in downloader_tasks
                wait(task)
            end
        finally
            close(wetstreams)
        end

        return nothing
    end

    parser_worker_count = max(1, Threads.nthreads())
    parser_tasks = [
        @async parser_worker_loop!(wetstreams, warcs, stats, stats_lock, progress_handler) for
            worker_index in 1:parser_worker_count
    ]

    close_warcs_task = @async begin
        try
            for task in parser_tasks
                wait(task)
            end
        finally
            close(warcs)
        end

        return nothing
    end

    tasks = Task[producer_task]
    append!(tasks, downloader_tasks)
    push!(tasks, close_wetstreams_task)
    append!(tasks, parser_tasks)
    push!(tasks, close_warcs_task)

    return DownloadStage(weturls, wetstreams, warcs, tasks, stats)
end
