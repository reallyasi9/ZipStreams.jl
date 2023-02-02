# Making pathological files in ZIP archives

```@meta
CurrentModule = ZipStreams
```

A File that uses a Data Descriptor can easily trick this module if care is taken in the
construction of the data that goes into the File. First, write some data to a File sink:

```julia block1
sink = zipsink("pathological.zip")
zf = open(sink, "file.txt"; compression=:store)
data = "Hello, Julia!"

write(zf, data)
```

Second, write the Data Descriptor header to the File (in little-endian format):

```julia block1
write(zf, htol(ZipStreams.SIG_DATA_DESCRIPTOR))
```

Third, write the CSC-32 checksum of the original data to the File (again, in little-endian
format):

```julia block1
write(zf, htol(ZipStreams.crc32(data)))
```

Finally, write the _compressed_ and _uncompressed_ sizes of the data to the File (you
guessed it: in little-endian format). This is made easier by using the `compression=:store`
keyword argument when opening the File for writing. Because the default File format is
Zip64 (keyword argument `zip64=true`), you need to write these as `UInt64` integers (if you
set `zip64=false`, write these as `UInt32` instead):

```julia block1
write(zf, hotl(sizeof(data) % UInt64)) # compressed size
write(zf, hotl(sizeof(data) % UInt64)) # uncompressed size
```

Now write whatever you want after that:

```julia block1
write(zf, "Goodbye, Julia!")
close(zf)
close(sink)
```

When you read the Archive back, you'll find that the stream reader will read up to the fake
Data Descriptor that you wrote and ignore the additional data that you wrote afterward:

```jldoctest block1
zipsource("pathological.zip") do source
    for zf in source
        println(read(zf, String))
    end
end

# output

Hello, Julia!
```