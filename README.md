# ZipStreams

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://USER_NAME.github.io/PACKAGE_NAME.jl/stable)

A Julia package to burn through ZIP archives as fast as possible by ignoring
standards just a little bit.

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
that conform to the _de facto_ standard described in the [PKWARE APPNOTE file](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)
will ignore the files that are no longer listed.

This design choice means that standards-conformant readers like [`ZipFile.jl`](https://github.com/fhs/ZipFile.jl)
cannot know what files are stored in a ZIP archive until they read to the very end of
the file. While this is not typically a problem on modern SSD-based storage, where
random file access is fast, it is a major limitation on stream-based file transfer
systems like networks, where readers typically have no choice but to read an
entire file from beginning to end in order. This is not a problem for archives
with sizes on the order of megabytes, but standard ZIP archives can be as large as
4GB, which can easily overwhelm systems with limited memory or storage like
embedded systems or cloud-based micro-instances. To make matters worse, ZIP64
archives can be up to 16 EB (2^64 bytes) in size, which can easily overwhelm even
the largest of modern supercomputers.

However, the ZIP archive specification also requires a "Local File Header" to
precede the (possibly compressed) file data of every file in the archive. The
Local File Header contains enough information to allow a reader to extract the
file and perform simple error checking as long as three conditions are met:
1. The information in the Local File Header is correctly specified. The Central
Directory is the canonical source of information, so the Local File Header could
be lying.
2. The Central Directory is not encrypted. File sizes and checksum values are
masked from the Local File Header if the Central Directory is encrypted, so it is
impossible to know where the file ends and the next one begins.
3. The file is not stored with a "Data Descriptor" (general purpose flag 3). As
with encryption, files that are stored with a Data Descriptor have masked file
sizes and checksums in the Local File Header. This format is typically used only
when the archive is _written_ in a streaming fashion.

All this being said, most users will never see ZIP files that cannot be extracted
exclusively using Local File Header information.

## DO NOT BLINDLY TRUST ZIP ARCHIVES

By ignoring standards, this module makes no guarantees that what you get out of
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

## Installation and use

Install via the Julia package manager, `Pkg.add("ZipStreams")`.

## Terminology: Archives and Files, Sources and Sinks

To avoid ambiguity, this package tries to use the following terms consistently
throughout type names, function names, and documentation:

File
: A File is a named sequence of zero or more bytes that represents a distinct
collection of data within an Archive. According to the ZIP standard, a File is
always preceded by a Local File Header and may have a Data Descriptor following
the File's contents. The contents of the File may be compressed within the Archive.

Directory
: A Directory is a named structure within an Archive that exists for organizational
purposes only. A Directory meets the definition of File with the additional
conditions that it always has size zero, it never has a Data Descriptor following
it, and has a name that always ends in a forward slash character (`/`).

Entity
: An Entity is either a File or a Directory.

Archive
: An Archive is a sequence of bytes that represents zero or more separate Entities.
According to the ZIP standard, an Archive is a series of Entities followed by a
Central Directory which describes the Entities.

Source
: A Source is an object that can be read as a sequence of bytes from beginning to
end. A Source does not necessarily implement random access or seek operations, nor
does it necessarily support write operations.

Sink
: A Sink is an object to which a sequence of bytes can be written. A Sink does not
necessarily implement random access or seek operations, nor does it necessarily
support read operations.

## Notes and aspirations

This package was inspired by frustrations at using more standard ZIP archive
reader/writers like [`ZipFile.jl`](https://github.com/fhs/ZipFile.jl). That's
not to say ZipFile.jl is bad--on the contrary, it is _way_ more
standards-compliant than this package ever intends to be! As you can see from
the history of this repository, much of the work here started as a fork of
that package. Because of that, I am grateful to [Fazlul Shahriar](https://github.com/fhs)
for programming and making available `ZipFile.jl`.

### To do

* ~~Document `zipsink` and `open` writing functionality~~
* ~~Add Documenter.jl hooks~~
* (1.1) Add Travis.ci Documenter.jl publishing
* Add benchmarks
* Convert examples in documentation to tests
* ~~Mock read-only and write-only streams for testing~~
* ~~Add all-at-once file writing~~
* ~~Make the user responsible for closing files if `open() do x ... end` syntax is not used.~~
* ~~(1.1) Add readavailable method to ZipFileSource~~
* ~~(1.1) Add unzip_files and zip_files convenience methods~~
* (1.1) Add tests for unzip_files and zip_files convenience methods
* ~~(1.1) Use Artifacts to download reference ZIP files for tests~~
* (2.0) Add ability to read files that use Data Descriptors
