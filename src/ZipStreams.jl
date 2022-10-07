"""
A Julia package for read ZIP archive files from a stream (NO SEEKING!)

This package provides support for reading and writing ZIP archives in Julia.
Install it via the Julia package manager using ``Pkg.add("ZipStreams")``.

The ZIP file format is described in
http://www.pkware.com/documents/casestudies/APPNOTE.TXT

# Example
The example below opens a ZIP archive and reads back the contents to console.
```julia
using ZipFiles

ZipStreams.open("archive.zip") do z
    for file in z
        print(read(file, String))
    end
end
```
"""
module ZipStreams

export nextfile, validate, write_file, zipsink, zipsource

include("crc32.jl")
include("io.jl")
include("constants.jl")
include("headers.jl")
include("truncated_input_stream.jl")
include("input_stream.jl")
include("output_stream.jl")

end # module