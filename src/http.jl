function decodeentities(page::AbstractString)
    replace(page,
        "&nbsp;" => " ", "&amp;" => "&", "&lt;" => "<",
        "&gt;" => ">", "&quot;" => "\"", "&#39;" => "'")
end

collapse(page::AbstractString) = join(split(page), ' ')

function plaintext(page::AbstractString)
    page |>
        p -> replace(p, r"<!--.*?-->"s => " ") |>
        p -> replace(p, r"<script\b[^>]*>.*?</script>"is => " ") |>
        p -> replace(p, r"<style\b[^>]*>.*?</style>"is => " ") |>
        p -> replace(p, r"<[^>]+>" => " ") |>
        decodeentities |>
        collapse
end

plaintext(uri::URI) = plaintext(String(HTTP.get(string(uri)).body)) # COV_EXCL_LINE: live-network overload

fetchtext(url::AbstractString) = plaintext(String(HTTP.get(String(url); readtimeout=30).body))
fetchtext(url::AbstractString, retryconfig::AbstractDict) = plaintext(String(HTTP.get(String(url); body=UInt8[], readtimeout=30, retry=true,
    retries=retryconfig["retries"], retry_delays=Base.ExponentialBackOff(n=retryconfig["retries"], factor=retryconfig["factor"])).body))
