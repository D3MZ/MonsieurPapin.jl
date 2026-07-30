using Test
using HTTP
using HTTP: URI
using MonsieurPapin
using Sockets

@testset "plaintext" begin
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

    @test plaintext(page) == "Example Hello & Goodbye Plain text."

    server = HTTP.serve!(ip"127.0.0.1", 0; verbose=false) do req
        req.target == "/live" && return HTTP.Response(200, "<html><body>Example</body></html>")
        return HTTP.Response(404)
    end

    try
        host, port = getsockname(server.listener.server)
        @test plaintext(URI("http://$(host):$(Int(port))/live")) == "Example"
    finally
        close(server)
    end

    if get(ENV, "MONSIEURPAPIN_LIVE_TESTS", "false") == "1"
        page = plaintext(URI("http://example.com"))
        @test occursin("Example Domain", page)
    end
end
