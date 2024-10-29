# Sources: Read-only Streams of Data

```@meta
CurrentModule = ZipStreams
```

## Reading archives with `zipsource`

You can wrap any Julia readable `IO` object with the `zipsource` function. The returned
object can be iterated to read archived files in archive order. Information about
each file can be accessed throug the `info` method called on the object returned
from the iterator. The object returned from the iterator is readable like any standard
Julia `IO` object, but it is not writable.

Here are some examples:

## Iterating through files from an archive on disk

This is perhaps the most common way to work with ZIP archives: reading them from disk and
doing things with the contained files. Because `zipsource` reads from the beginning of the
file to the end, you can only iterate through files in archive order and cannot randomly
access files. Here is an example of how to work with this kind of file iteration:

```julia
using ZipStreams

# open an archive from an IO object
open("archive.zip") do io
    zs = zipsource(io)

    # iterate through files
    for f in zs
        
        # get information about each file from the info method
        println(info(f).name)

        # read from the file just like any other IO object
        println(readline(f))
        
        println(read(f, String))
    end
end
```

You can use the `next_file` method to access the next file in the archive without iterating
in a loop. The method returns `nothing` if it reaches the end of the archive.

```julia
using ZipStreams

open("archive.zip") do io
    zs = zipsource(io)
    f = next_file(zs) # the first file in the archive, or nothing if there are no files archived
    # ...
    f = next_file(zs) # the next file in the archive, or nothing if there was only one file
    # ...
end
```

Because reading ZIP files from an archive on disk is a common use case, a convenience
method taking a file name argument is provided:

```julia
using ZipStreams

zs = zipsource("archive.zip") # Note: the caller is responsible for closing this to free the file handle
# ... 
close(zs)
```

In addition, a method that takes as its first argument a unary function is
included so that users can manage the lifetime of any file handles opened by
`zipsource` in an `open() do x ... end` block:

```julia
using ZipStreams

zipsource("archive.zip") do zs
    # ...
end # file handle is automatically closed at the end of the block
```

The same method is defined for `IO` arguments, but it works slightly differently:
the object passed is _not_ closed when the block ends. It assumes that the
caller is responsible for the `IO` object's lifetime. However, manually calling `close`
on the source will always close the wrapped `IO` object. Here is an example:

```julia
using ZipStreams

io = open("archive.zip")
zipsource(io) do zs
    # ...
end
@assert isopen(io) == true

seekstart(io)
zipsource(io) do zs
    # ...
    close(zs) # called manually
end
@assert isopen(io) == false
```

## Verifying the content of ZIP archives

A ZIP archive stores file sizes and checksums in two of three locations: one of 
either immediately before the archived file data (in the "Local File Header")
or immediately after the archived file data (in the "Data Descriptor"), and always
at the end of the file (in the "Central Directory"). Because the Central Directory
is considered the ground truth, the Local File Header and Data Descriptor may report
inaccurate values. To verify that the content of the file matches the values in the
Local File Header, use the `validate` method on the archived file. To verify that
all file content in the archive matches the values in the Central Directory, use
the `validate` method on the archive itself. These methods will throw an error if
they detect any inconsistencies.

For example, to validate the data in a single file stored in the archive:

```julia
using ZipStreams

zipsource("archive.zip") do zs
    f = next_file(zs)
    validate(f) # throws if there is an inconsistency in the file's checksums
end
```

To validate the data in all of the _remaining_ files in the archive:

```julia
using ZipStreams

io = open("archive.zip")
zipsource(io) do zs
    validate(zs) # validate all local checksums and the central directory
end

seekstart(io)
zipsource(io) do zs
    f = next_file(zs) # read the first file
    validate(zs) # validate all remaining local checksums and the central directory
end

close(io)
```

The `validate` methods consume the remaining data in the source. When called on an archived
file, it reads the remainder of the data in the file that has not yet been read from the
source (if any) and discards it. When called on the archive itself, will invalidate any
currently referenced file, meaning reading from an open file within the archive after
running validate on the archive will result in undefined behavior.

!!! warning "Reading from two places in an archive at once"

    Do not attempt to read from two places in an open archive at once, or jump between one
    open file and another, as this will result in undefined behavior!

```julia
using ZipStreams

zs = zipsource("archive.zip")
f1 = next_file(zs)
validate(f1) # reads all data in f1 and discards it
@assert eof(f1) == true
@assert isempty(read(f1)) == true
close(zs)

zs = zipsource("archive.zip")
f2 = next_file(zs)
readline(f2) # reads a line off the file first
validate(zs) # reads everything, including the remainder of the first file

# DO NOT READ FROM f2 HERE AFTER CALLING validate ON THE ARCHIVE!
# THIS RESULTS IN UNDEFINED BEHAVIOR!
# @assert eof(f2) == false  # THIS IS A LIE!
# read(f2)  # THIS MAY CRASH YOUR COMPUTER!

close(zs)
```

Note that these methods consume the data in the file or archive, as demonstrated in this
example:

```julia
using ZipStreams

zs = zipsource("archive.zip")
validate(zs)
@assert eof(zs) == true
```

## API
```@docs
ZipArchiveSource
zipsource
next_file
validate
info(::ZipFileSource)
```
