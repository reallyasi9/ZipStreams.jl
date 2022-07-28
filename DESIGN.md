# Design Goals
[ZIP archives]() are ubiquitous. You can hardly do anything on a computer or on the Internet without downloading data packed in a ZIP archive. Zip archives also back many other standard file formats, like office documents and Java archives.

Most of the time, using ZIP archives is not an issue: you can use modern operating system tools to inspect the contents of ZIP archives and extract individual files stored in the archive to some local file system without much friction. But say you want to build an automated system that uses ZIP archives for either data input or output: manual handling of ZIP archives is inefficient, and using external tools for simple tasks like reading and writing stored files in inelegant. This is especially true if you want to stream the data and keep as much compressed and out of working memory as possible--a requirement for disk-constrained or memory-constrained systems.

This package is designed to meet two basic needs for Julia programmers who work with ZIP archives:

1. To provide a _correct_, _simple_, and _fast_ way to extract files from a _standards-compliant_ ZIP archive to a local file system and to store files from a local file system to a ZIP archive.
2. To provide a _correct_, _simple_, and _fast_ way to stream file data to and from a _standards-compliant_ ZIP archive while minimizing local file system usage.

Both of these design goals use some terminology that must be precisely defined to make the goals achievable:

## Correct

A package that does not interpret the [ZIP archive format](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) correctly is useless to developers and users. If a user does not know if the package will be able to correctly read a ZIP archive in the wild, the user is more likely to turn to a more standards-compliant tool to get the job done and not risk corrupted data or errors when reading and writing files.

That being said, many of the components of the ZIP archive standard are optional, so two tools that are both technically "standards-compliant" may read or write different things from and to a ZIP archive. The goal of this package is not to perfectly reproduce the behavior of one particular tool; however, at the very least this package must be able to read files from ZIP archives created by other standards-compliant tools and must be able to create and write files to a ZIP archive that can be read by other standards-compliant tools.

To that end, the current design principle is to **implement a reader and writer interface that reads or creates a ZIP archive that follows all the required elements (those elements described as "MUST/MUST NOT" or "SHALL/SHALL NOT") in the specification**. Other design principles will be considered when implementing or not implementing features that are recommended ("SHOULD/SHOULD NOT") or optional ("MAY") in the specification. In particular, the package will strive to read and produce ZIP archives that are compliant with the [ISO/IEC 21320-1 standard](https://www.iso.org/standard/60101.html), which is a more strict subset of the PKWARE standard version 4.5. The package will be tested against ZIP archives created by other tools to guarantee compatability. The package will also be tested against intentionally corrupted ZIP archives to insure conformance with the specification.

## Simple
A simple solution is favored over a complicated one, even if the complicated one is technically more "correct". This goes for both the internal design of the package and the externally-facing API. For example, observe the API of the most complete implementation of ZIP file handling for Julia at the time of writing this design document is [ZipFile](https://github.com/fhs/ZipFile.jl). To read a particular file from an archive, you need to do something this:

```julia
r = ZipFile.Reader("path/to/archive.zip")
for f in r.files
    if f.name == "path/in/archive/to/file.txt"
        data = read(f, String)
    end
end
close(r)
```

Why should one have to search through all the files in the archive to check if the name matches what one is looking for? Compare this to how you read a file from the file system using Julia's IO API:

```julia
open("path/to/file.txt") do f
    data = read(f, String)
end # f automatically closed at the end of the block
```

One possible way to make the handling of ZIP archives simpler for the user is to make an API that more conforms to Julia's IO API, treating ZIP archives like little file systems. Here is one such possibility:

```julia
ZipFiles.open_zip("path/to/archive.zip") do zf
    open(zf, "path/in/archive/to/file.txt") do f
        data = read(f, String)
    end # f's resources automatically freed at the end of the block
end # zf automatically closed at the end of the block
```

Or if only one file needs to be read from the ZIP archive:

```julia
ZipFiles.open_zip("path/to/archive.zip", "path/in/archive/to/file.txt") do f
    data = read(f, String)
end # f automatically closed at the end of the block
```

To that end, the current design principle for simplicity in the API is to **conform as closely as possible to Julia's IO API**, using principles of multiple dispatch wherever we can and changing method names where necesasry to avoid argument list collisions.

## Fast

When automating processes on a digital computer, it is almost always preferable to use a faster solution than a slower one.

To that end, the current design principle for speed is to perform within the same order of magnitude of time and memory usage as this package's predecesor, ZipFile. To this end, benchmarks will be designed for this package and for the ZipFile package to test the various comparable functions of both, and regressions in execution time and memory usage will be scrutinized. Benchmark results will be published when possible to demonstrate adherence to this design principle.

### A quick rant about file formats
The ZIP Archive file format appears to be optimized for _appending_, not for _reading_. This observation is supported by the placement of the Central Directory, the part of the file that tells the reader where files are located within the archive, is placed at the _end_ of the archive. Thus to append a new file to the archive, one only has to write the data with the appropriate header information at the end of the file and write a new Central Directory at the end with the newly archived file information added.

As a side-note, data within the archive that is not liseted in the Central Directory as part of a stored file is ignored by ZIP archive readers. This means that ZIP archives can contain garbage data, abandoned ("deleted") files, and even abandoned Central Directories in spaces not referenced by the last Central Directory in the archive!

In terms of performance, this means reading a ZIP archive from the beginning is not always an optimal way of knowing what files are available for extraction. Imagine reading through gigabytes of a ZIP archive, making note of all the file headers seen along the way and where they are located in the file, only to read the Central Directory at the end and having to discard many of those found files. Scanning like this from the beginning of the file can be especially error-prone because ZIP archives can store uncompressed data, and that uncompressed data can include another ZIP archive!
