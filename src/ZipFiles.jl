"""
A Julia package for read ZIP archive files from a stream (NO SEEKING!)

This package provides support for reading and writing ZIP archives in Julia.
Install it via the Julia package manager using ``Pkg.add("ZipFiles")``.

The ZIP file format is described in
http://www.pkware.com/documents/casestudies/APPNOTE.TXT

# Example
The example below writes a new ZIP file and then reads back the contents.
```
julia> using ZipFiles
```
"""
module ZipFiles

include("crc32.jl")
include("io.jl")
include("constants.jl")
include("utility_streams.jl")
include("file.jl")
include("input_stream.jl")
include("output_stream.jl")

end # module