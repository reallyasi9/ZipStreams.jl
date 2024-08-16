"""
A Julia package for read ZIP archive files from a stream (NO SEEKING!)

This package provides support for reading and writing ZIP archives in Julia.
Install it via the Julia package manager using ``Pkg.add("ZipStreams")``.

The ZIP file format is described in
http://www.pkware.com/documents/casestudies/APPNOTE.TXT

# Example
The example below creates a ZIP archive, writes a file to it, then opens
same archive back up and prints the contents of the file to console.
```julia
using ZipStreams

zipsink("archive.zip") do sink
    open(sink, "hello.txt") do f
        write(f, "Hello, Julia!")
    end
end

zipsource("archive.zip") do source
    for f in source
        println(file_info(f).name)
        read_data = read(String, f)
        println(read_data)
    end
end
```
"""
module ZipStreams

export print_info,
    file_info,
    next_file,
    unzip_file,
    unzip_files,
    validate,
    write_file,
    zipsink,
    zipsource,
    zip_file,
    zip_files

include("crc32_stream.jl")
include("io.jl")
include("constants.jl")
include("headers.jl")
include("input_stream.jl")
include("output_stream.jl")
include("print_info.jl")
include("convenience.jl")

end # module