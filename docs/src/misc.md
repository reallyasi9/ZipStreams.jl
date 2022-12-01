# Convenience functions for reading and writing archives from disk

```@meta
CurrentModule = ZipStreams
```

If you want to simply read an archive from disk and extract some files back to disk, you can use the convenience method `unzip_files` or `unzip_file`. Note that you can only read files that can be opened with [`open(::ZipArchiveSource, ::AbstractString)`](@ref) (i.e., files not written with Data Descriptors):

```julia
using ZipStreams

# write an archive to disk
archive_name = tempname()
zipsink(archive_name) do sink
    write_file(sink, "hello.txt", "Hello, Julia!")
    write_file(sink, "subdir/goodbye.txt", "Goodbye, Julia!"; make_path=true)
    write_file(sink, "test.txt", "This is a test.")
end

# extract the contents here (".")
unzip_files(archive_name)
@assert read("hello.txt", String) == "Hello, Julia!"
@assert read("subdir/goodbye.txt", String) == "Goodbye, Julia!"
@assert read("test.txt", String) == "This is a test."

# extract files somewhere else
outdir = tempdir()
unzip_files(archive_name; output_path=outdir)
@assert read(joinpath(output_path, "hello.txt"), String) == "Hello, Julia!"
@assert read(joinpath(output_path, "subdir/goodbye.txt"), String) == "Goodbye, Julia!"
@assert read(joinpath(output_path, "test.txt"), String) == "This is a test."

# extract specific files here, making subdirectories as needed
unzip_files(archive_name, ["hello.txt", "subdir/goodbye.txt"])
@assert read(joinpath(output_path, "hello.txt"), String) == "Hello, Julia!"
@assert read(joinpath(output_path, "subdir/goodbye.txt"), String) == "Goodbye, Julia!"

# extract specific files somewhere else, making the root directory if needed
unzip_files(archive_name, "test.txt"; output_path="other/location", make_path=true)
@assert read("other/location/test.txt", String) == "This is a test."
```

If you want to store files from disk to a new archive, you can use the `zip_files` or `zip_file` method:

```julia
using ZipStreams

# make some fake files to compress
dir = mktempdir()
path1 = tempname(dir)
write(path1, "Hello, Julia!")
path2 = tempname(dir)
write(path2, "Goodbye, Julia!")

# Archive the files
archive_name = tempname(dir)
zip_files(archive_name, [path1, path2])
```

These files are written with data descriptors, so they cannot be read using the streaming methods of this package.

## API
```@docs
unzip_files
zip_files
```