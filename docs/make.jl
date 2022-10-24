using Documenter
using ZipStreams

DocMeta.setdocmeta!(ZipStreams, :DocTestSetup, :(using ZipStreams); recursive=true)
makedocs(
    sitename = "ZipStreams",
    format = Documenter.HTML(),
    # modules = [ZipStreams],
    pages = [
        "Overview" => "index.md",
        "Reading from Sources" => "sources.md",
        "Writing to Sinks" => "sinks.md",
        "Printing Information" => "info.md",
        "Other Operations" => "misc.md",
    ]
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
#=deploydocs(
    repo = "<repository url>"
)=#
