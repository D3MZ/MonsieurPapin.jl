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

plaintext(uri::URI) = plaintext(String(HTTP.get(string(uri)).body))

fetchtext(url::AbstractString) = plaintext(String(HTTP.get(String(url); timeout=30).body))
