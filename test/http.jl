using Test
using HTTP: URI

@testset "gettext" begin
    page = """
    <html>
      <head>
        <title>Example</title>
        <style>body { color: red; }</style>
        <script>console.log("ignore")</script>
      </head>
      <body>
        <h1>Hello &amp; Goodbye</h1>
        <p>Plain text.</p>
      </body>
    </html>
    """

    @test gettext(page) == "Example Hello & Goodbye Plain text."

    if get(ENV, "MONSIEURPAPIN_LIVE_TESTS", "false") == "1"
        page = gettext(URI("http://example.com"))
        @test occursin("Example Domain", page)
    end
end
