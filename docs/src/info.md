# Printing info about ZIP archives

```@meta
CurrentModule = ZipStreams
```

You can print information about a ZIP archive or a file within a ZIP archive to the terminal
(or any `IO` object) with the `info` method. The format of the information displayed for
each file is similar to the short format produced by [`ZipInfo`](https://linux.die.net/man/1/zipinfo).
In general, the output has the following format:

```
TTTT UUUUUUUU ZZZ LLL CCCCCCCC XXXX dd-mmm-yy hh:mm:ss 0xSSSSSSSS NAME
```

The definitions of these fields are, in order:
- `TTTT`: Either the string `"file"` or `"dir "`, signifying what kind of entry it is;
- `UUUUUUUU`: The uncompressed size of the file in bytes;
- `ZZZ`: Either the string `"z64"` or `"---"`, signifying that the Local File Header uses the Zip64 format;
- `LLL`: Either the string `"lhx"` or `"---"`, signifying that a Data Descriptor is used;
- `CCCCCCCC`: The compressed size of the file in bytes;
- `XXXX`: The compression method used to compress the data;
- `dd-mmm-yy hh:mm:ss`: The creation date and time of the file;
- `0xSSSSSSSS`: The CRC-32 checksum of the compressed data as a hexadecimal number;
- `NAME`: The name of the entry in the Local File Header.

If called on an archive source, info about all of the archived entities read from the source
so far is printed in archive order, along with status information about how much has been
read from the archive so far, whether or not the EOF has been reached, and statistics about
the number and size of the entries.

The first call to `info` in this example reports nothing has been read yet:

```@meta
DocTestFilters = [r"\d{2}-[A-Z][a-z]{2}-\d{2} \d{2}:\d{2}:\d{2}"]
```

```jldoctest info1
using ZipStreams

zipsink("archive.zip") do sink
    write_file(sink, "hello.txt", "Hello, Julia!")
    write_file(sink, "subdir/goodbye.txt", "Goodbye, Julia!"; compression=:store, make_path=true)
end

source = zipsource("archive.zip")
info(source)

# output

ZIP archive source stream data after reading 0 B, number of entries: 0
```

After reading all of the data in the archive using `vialidate`, a call to `info` reports
information about the entities read:

```jldoctest info1
validate(source)
info(source)

# output

ZIP archive source stream data after reading 54 B, number of entries: 1
file       13 --- ---       15 defl 26-Oct-22 17:57:54 0x6a9d1e48 hello.txt
dir         0 --- ---        0 stor 26-Oct-22 17:57:54 0x00000000 subdir/
file       15 --- ---       15 stor 26-Oct-22 17:57:54 0x12345678 subdir/goodbye.txt
1 file, 13 B uncompressed, 15 B compressed: 1418980313362273280.0%
```

```@meta
DocTestFilters = nothing
```

## API
```@docs
info
```