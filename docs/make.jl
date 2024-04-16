using Documenter
using JSON
using ZipStreams

function should_push_preview(event_path = get(ENV, "GITHUB_EVENT_PATH", nothing))
    event_path === nothing && return false
    event = JSON.parsefile(event_path)
    "pull_request" in keys(event) || return false
    labels = [x["name"] for x in event["pull_request"]["labels"]]
    return "push_preview" in labels
end

DocMeta.setdocmeta!(ZipStreams, :DocTestSetup, :(using ZipStreams); recursive=true)
makedocs(
    sitename = "ZipStreams",
    format = Documenter.HTML(edit_link = "main"),
    modules = [ZipStreams],
    pages = [
        "Overview" => "index.md",
        "Reading from Sources" => "sources.md",
        "Writing to Sinks" => "sinks.md",
        "Printing Information" => "info.md",
        "Other Operations" => "misc.md",
        "Pathological Files" => "pathological.md",
    ]
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
deploydocs(
    repo = "github.com/reallyasi9/ZipStreams.jl.git",
    push_preview = should_push_preview(),
    devbranch = "main",
)
