drop(page::AbstractString, pattern) = replace(page, pattern => " ")

function entities(page::AbstractString)
    replace(page,
        "&nbsp;" => " ", "&amp;" => "&", "&lt;" => "<",
        "&gt;" => ">", "&quot;" => "\"", "&#39;" => "'")
end

collapse(page::AbstractString) = join(split(page), ' ')

function gettext(page::AbstractString)
    page |>
        p -> drop(p, r"<!--.*?-->"s) |>
        p -> drop(p, r"<script\b[^>]*>.*?</script>"is) |>
        p -> drop(p, r"<style\b[^>]*>.*?</style>"is) |>
        p -> drop(p, r"<[^>]+>") |>
        entities |>
        collapse
end

gettext(uri::URI) = gettext(String(HTTP.get(string(uri)).body))

fetchtext(url::AbstractString) = gettext(String(HTTP.get(String(url); timeout=30).body))
