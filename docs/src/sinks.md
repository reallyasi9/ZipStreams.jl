# Sinks: Write-only Streams of Data

```@meta
CurrentModule = ZipStreams
```

## Creating archives and writing files with `zipsink`

You can wrap any `IO` object that supports writing bytes (any type that implements
`unsafe_write(::T, ::Ptr{UInt8}, ::UInt)`) in a special ZIP archive writer with the
`zipsink` function. The function will return an object that allows creating and writing
files within the archive. You can then call `open(sink, filename)` using the returned
object to create a new file in the archive and begin writing to it with standard `IO`
functions.

This example creates a new ZIP archive file on disk, creates a new file within the archive,
writes data to the file, then closes the file and archive:

```julia
using ZipStreams

io = open("new-archive.zip", "w")
sink = zipsink(io)
f = open(sink, "hello.txt")
write(f, "Hello, Julia!")
close(f)
close(sink)
```

Convenience methods are included that create a new file on disk by passing a file name to
`zipsink` instead of an `IO` object and that run a unary function so that `zipsink` can be
used with a `do ... end` block. In addition, the `open(sink, filename)` method can
also be used with a `do ... end` block, as this example shows:

```julia
using ZipStreams

zipsink("new-archive.zip") do sink  # create a new archive on disk and truncate it
    open(sink, "hello.txt") do f  # create a new file in the archive
        write(f, "Hello, Julia!")
    end  # automatically write a Data Descriptor to the archive and close the file
end  # automatically write the Central Directory and close the archive
```

Note that the `IO` method does not automatically close the `IO` object after the `do` block
ends. The caller of that signature is responsible for the lifetime of the `IO` object. The
`IO` object can be closed before the end of the `do` block by calling `close` on the sink.
Additional writes to a closed sink will cause an `ArgumentError` to be thrown, but closing
a closed sink is a noop, as these examples show:

```julia
using ZipStreams

io = IOBuffer()
zipsink(io) do sink
    open(sink, "hello.txt") do f
        write(f, "Hello, Julia!")
    end
end
@assert isopen(io) == true

zipsink(io) do sink
    open(sink, "goodbye.txt") do f
        write(f, "Good bye, Julia!")
    end
    close(sink)
end
@assert isopen(io) == false
```

Because the data are streamed to the archive, you can only have one file open for writing
at a time in a given archive. If you try to open a new file before closing the previous
file, a warning will be printed to the console and the previous file will automatically be
closed. In addition, any file still open for writing when the archive is closed will
automatically be closed before the archive is finalized, as this example demonstrates:

```julia
using ZipStreams

zipsink("new-archive.zip") do sink
    f1 = open(sink, "hello.txt")
    write(f1, "Hello, Julia!")
    f2 = open(sink, "goodbye.txt")  # issues a warning and closes f1 before opening f2
    write(f2, "Good bye, Julia!")
end  # automatically closes f2 before closing the archive
```

## Writing files to an archive all at once with `write_file`

When you open a file for writing in a ZIP archive using `open(sink, filename)`, writing to
the file is done in a streaming fashion with a Data Descriptor written at the end of the
file data when it is closed. If you want to write an entire file to the archive at once,
you can use the `write_file(sink, filename, data)` method. This method will write file size
and checksum information to the archive in the Local File Header rather than using a Data
Descriptor. The advantage to this method is that files written this way are more efficiently
read back by a `zipsource`: when streamed for reading, the Local File Header will report the
correct file size. The disadvantages to using this method for writing data are that you need
to have all of the data you want to write available at one time and that both the raw data
and the compressed data need to fit in memory. Here are some examples using
this method for writing files:

```julia
using ZipStreams

zipsink("new-archive.zip") do sink
    open(sink, "hello.txt") do f1
        write(f1, "Hello, Julia!")  # writes using a Data Descriptor
    end
end


zipsource("new-archive.zip") do source
    f = next_file(source)  # works, but is slow to read because the stream has to be checked for a valid Data Descriptor with each read
    @assert read(f, String) == "Hello, Julia!"
end

zipsink("new-archive.zip") do sink
    text = "Hello, Julia!"
    write_file(sink, "hello.txt", text)  # writes without a Data Descriptor
end

zipsource("new-archive.zip") do source
    f = next_file(source)  # is more efficient to read because the file size is known a priori
    @assert read(f, String) == "Hello, Julia!"
end
```

## Creating directories in an archive

Directories within a ZIP archive are nothing more than files with zero length and a name
that ends in a forward slash (`/`). If you try to make a file using `open` or `write_file`
that has a name ending in `/`, the method will throw an error. You can, however, make a
directory by calling the `mkdir` and `mkpath` functions. They work similar to how
`Base.mkdir` and `Base.mkpath` work: the former will throw an error if all of the parent
directories do not exist, while the latter will create the parent directories as needed.
Here are examples of these two functions:

```julia
using ZipStreams

zipsink("new-archive.zip") do sink
    try
        f = open(sink, "file/")  # fails because files cannot end in '/'
    catch e
        @error "exception caught" exception=e
    end

    mkdir(sink, "dir1/")  # creates a directory called "dir1/" in the root of the archive
    mkdir(sink, "dir1/dir2/")  # creates "dir2/" as a subdirectory of "dir1/"

    try
        mkdir(sink, "dir3/dir4/")  # fails because mkdir won't create parent directories
    catch e
        @error "exception caught" exception=e
    end
    
    mkpath(sink, "dir3/dir4/")  # creates both "dir3/" and "dir3/dir4/"

    mkdir(sink, "dir5")  # The ending slash will be appended to directory names automatically
end
```

NOTE: Even on Windows computers, directory names in ZIP files always use forward slash (`/`)
as a directory separator. Backslash characters (`\`) are treated as literal backslashes
in the directory or filename, so `mkdir(sink, "dir\\file")` will create a single file named
`dir\file` and _not_ a directory.

The `mkdir` and `mkpath` methods return the number of bytes written to the archive, 
including the Local File Header required to define the directory, but _excluding_ the
Central Directory Header data (that will be written when the sink is closed).

The sink keeps track of which directories have been defined and skips creating directories
that already exist, as this example demonstrates:

```julia
using ZipStreams

zipsink("new-archive.zip") do sink
    a = mkdir(sink, "dir1/")  # returns the number of bytes written to the archive
    @assert a > 0
    b = mkdir(sink, "dir1/")
    @assert b == 0  # dir1 already exists, so nothing is written
    c = mkpath(sink, "dir1/dir2")  # dir1 already exists, so do not recreate it
    d = mkpath(sink, "dir3/dir4")  # dir3 has to be created along with dir4
    @assert d > c  # the second call creates two directories, so more bytes are written
end
```

Opening a new file in the sink that contains a non-trivial path will throw an error if the
parent path does not exist. The keyword argument `make_path=true` will cause the method to
create the parent path as if `mkpath` were called first:

```julia
using ZipStreams

zipsink("new-archive.zip") do sink
    try
        f = open(sink, "dir1/file")  # fails because directory "dir1/" does not exist
    catch e
        @error "exception caught" exception=e
    end
    f = open(sink, "dir1/file"; make_path=true)  # creates "dir1/" first
    # ...
    close(f)
end
```

Relative directory names `.` or `..` are interpreted as directories literally named `.` or `..` and
_not_ as relative paths. The root directory of the archive is unnamed, so attempts to
create a directory named `/` will be ignored. Attempting to create an unnamed subdirectory
will result in the unnamed subdirectory being ignored (e.g., `mkpath(sink, "dir1//dir2")` 
will do the same thing as `mkpath(sink, "dir1/dir2")`). By rule, attempting to make a
directory that appears to begin with a Windows drive specifier, even on a non-Windows OS,
will throw an error (per 4.4.17 of the APPNOTE document).

```julia
using ZipStreams

zipsink("new-archive.zip") do sink
    @assert mkpath(sink, "/") == 0  # '/' at the beginning is ignored
    mkpath(sink, "/dir1")
    @assert mkpath(sink, "dir1") == 0  # already created with "/dir1"
    
    mkpath(sink, "dir1/////dir2")
    @assert mkpath(sink, "dir1/dir2") == 0  # already created with "dir1/////dir2"

    try
        mkpath(sink, "c:\\dir1")  # fails because directory appears to start with a drive specifier
    catch e
        @error "exception caught" exception=e
    end
    try
        mkpath(sink, "q:dir1")  # fails for the same reason: the slash at the end doesn't matter
    catch e
        @error "exception caught" exception=e
    end
    try
        mkpath(sink, "\\\\networkshare\\dir1")  # fails because Windows network drives count as drive specifiers
    catch e
        @error "exception caught" exception=e
    end
end
```

## API
```@docs
ZipArchiveSink
zipsink
Base.mkdir(::ZipArchiveSink, ::AbstractString)
Base.mkpath(::ZipArchiveSink, ::AbstractString)
Base.open(::ZipArchiveSink, ::AbstractString)
write_file
```