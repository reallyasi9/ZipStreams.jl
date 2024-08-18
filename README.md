# ZipStreams

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://reallyasi9.github.io/ZipStreams.jl/stable)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://reallyasi9.github.io/ZipStreams.jl/dev)

A Julia package to read and write ZIP archives from read-only or write-only streams by
ignoring standards just a little bit.

## Synopsis

```julia
using ZipStreams

zipsink("archive.zip") do sink     # context management of sinks with "do" syntax
    open(sink, "hello.txt") do f   # context management of files with "do" syntax
        write(f, "Hello, Julia!")  # write just like you write to any IO object
    end
end

zipsource("archive.zip") do source   # context management of sources with "do" syntax
    for f in source                  # iterate through files in an archive
        println(info(f).name)        # "hello.txt"
        read_data = read(String, f)  # read just like you read from any IO object
        println(read_data)           # "Hello, Julia!"
    end
end
```

## Overview
> "There are three ways to do things: the right way, the wrong way, and the Max Power way."
>
> -Homer from The Simpsons, season 10, episode 13: "Homer to the Max"

ZIP archives are optimized for _appending_ and _deleting_ operations. This is
because the canonical source of information for what is stored in a ZIP archive,
the "Central Directory", is written at the very end of the archive. Users
who want to append a file to the archive can overwrite the Central Directory with
new file data, then append an updated Central Directory afterward, and nothing
else in the file has to be touched. Likewise, users who want to delete files in
the archive only have to change the entries in the Central Directory: readers
that conform to the standard described in the [PKWARE APPNOTE file](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)
will ignore the files that are no longer listed.

This design choice means that standards-conformant readers like [`ZipFile.jl`](https://github.com/fhs/ZipFile.jl)
cannot know what files are stored in a ZIP archive until they read to the very end of
the archive. While this is not typically a problem on modern SSD-based storage, where
random file access is fast, it is a major limitation on stream-based file transfer
systems like networks, where readers typically have no choice but to read an
entire file from beginning to end in order. And again, this is not a problem for archives
with sizes on the order of megabytes, but standard ZIP archives can be as large as
4GB, which can easily overwhelm systems with limited memory or storage like
embedded systems or cloud-based micro-instances. To make matters worse, ZIP64
archives can be up to 16 EB (2^64 bytes) in size, which can easily overwhelm even
the largest of modern supercomputers.

However, the ZIP archive specification also requires a "Local File Header" to
precede the (possibly compressed) file data of every file in the archive. The
Local File Header contains enough information to allow a reader to extract the
file and perform simple error checking as long as three conditions are met:
1. The information in the Local File Header is correctly specified. The Central Directory is the canonical source of information, so the Local File Header could be lying.
2. The Central Directory is not encrypted. File sizes and checksum values are masked from the Local File Header if the Central Directory is encrypted, so it is impossible to know where the file ends and the next one begins.
3. The file is not stored with a "Data Descriptor" (general purpose flag 3). As with encryption, files that are stored with a Data Descriptor have masked file sizes and checksums in the Local File Header. This format is typically used only when the archive is _written_ in a streaming fashion.

All this being said, most users will never see ZIP files that cannot be extracted
exclusively using Local File Header information.

### About files written with Data Descriptors

When a file is streamed to an archive, the final size of the file may not be knowable until
the last byte is written--this is especially true if the file is being compressed while it
is being streamed. Files streamed in this way use a Data Descriptor, appended immediately
after the file data, to record the CRC-32 checksum and compressed and uncompressed sizes.
Files _written_ in this way can be _read_ in a streaming way as well, but only if the data
being read is buffered, and only if the file was written with the optional Data Descriptor
signature as described in section 4.3.9.3 of the [PKWARE APPNOTE file](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT).

When reading a file that signals in the Local File Header that it uses a Data Descriptor,
this package will check for a valid Data Descriptor on _every read_ from the stream. This is
the only way the package can determine if a file written with a Data Descriptor has been
completely consumed from the archive source. This makes reading files using Data Descriptors
much less efficient than reading files that use Local File Headers to specify lengths, where
the package only has to count bytes to know if it has completely consumed the file from the
archive source.

## DO NOT BLINDLY TRUST ZIP ARCHIVES

By ignoring the Central Directory, this module makes no guarantees that what you get out of
the ZIP archive matches what you or anyone else put into it. The code is tested
against ZIP archives generated by various writers, but there are corner cases,
ambiguities in the standard, and even pathological ZIP files in the wild that may
silently break this package.

> _Bart:_ "Isn't that the wrong way?"
>
> _Homer:_ "Yeah, but faster!"
>
> -The Simpsons, season 10, episode 13: "Homer to the Max"

You have been warned!

## Installation

Install via the Julia package manager, `Pkg.add("ZipStreams")`.

## Notes

This package was inspired by frustrations with using standards-compliant ZIP archive
reader/writers like [`ZipFile.jl`](https://github.com/fhs/ZipFile.jl) on streams of data
from a network source. That's not to say ZipFile.jl is bad--on the contrary, it is _way_
more standards-compliant than this package ever intends to be! As you can see from
the history of this repository, much of the work here started as a fork of
that package. Because of that, I am grateful to [Fazlul Shahriar](https://github.com/fhs)
for programming and making available `ZipFile.jl`.
