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

export info, next_file, unzip_file, unzip_files, validate, write_file, zipsink, zipsource, zip_file, zip_files

include("crc32.jl")
include("io.jl")
include("constants.jl")
include("codecs.jl")
include("headers.jl")
include("input_stream.jl")
include("output_stream.jl")
include("info.jl")
include("convenience.jl")

end # module