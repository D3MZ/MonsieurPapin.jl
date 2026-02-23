using MonsieurPapin
using Documenter

DocMeta.setdocmeta!(MonsieurPapin, :DocTestSetup, :(using MonsieurPapin); recursive=true)

makedocs(;
    modules=[MonsieurPapin],
    authors="Demetrius Michael <arrrwalktheplank@gmail.com>",
    sitename="MonsieurPapin.jl",
    format=Documenter.HTML(;
        canonical="https://D3MZ.github.io/MonsieurPapin.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/D3MZ/MonsieurPapin.jl",
    devbranch="main",
)
