module MonsieurPapin

include("download_stage.jl")

export AbstractTransport
export DownloadProgress
export DownloadSettings
export DownloadStage
export DownloadStats
export HTTPTransport
export WARC
export fetch_wet_urls
export open_url_stream
export start_download_stage

end
