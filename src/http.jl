drop(page::AbstractString, pattern) = replace(page, pattern => " ")

function entities(page::AbstractString)
    page |>
    text -> replace(text, "&nbsp;" => " ") |>
    text -> replace(text, "&amp;" => "&") |>
    text -> replace(text, "&lt;" => "<") |>
    text -> replace(text, "&gt;" => ">") |>
    text -> replace(text, "&quot;" => "\"") |>
    text -> replace(text, "&#39;" => "'")
end

collapse(page::AbstractString) = join(split(page), ' ')

function gettext(page::AbstractString)
    collapse(
        entities(
            drop(
                drop(
                    drop(
                        drop(page, r"<!--.*?-->"s),
                        r"<script\b[^>]*>.*?</script>"is,
                    ),
                    r"<style\b[^>]*>.*?</style>"is,
                ),
                r"<[^>]+>",
            ),
        ),
    )
end

gettext(uri::URI) = gettext(String(HTTP.get(string(uri)).body))

function fetchtext(url::AbstractString)
    response = HTTP.get(String(url); timeout=30)
    return gettext(String(response.body))
end
