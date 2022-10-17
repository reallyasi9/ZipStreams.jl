import Base: open, close, mkdir, mkpath, write, unsafe_write, flush, isopen, iswritable, isreadable, position

using Dates
using TranscodingStreams

"""
    ZipFileOutputStream{S,R}([arguments])

A struct representing an open streamable file in a `ZipArchiveOutputStream`.

This struct is an `IO` object, so it inherits `write()` and `unsafe_write()`
methods from `IO`. You cannot read from this type, nor can you seek, skip, or
read the file's position. It functions in this way to allow writing to write-only
streams (like HTTP output).

The types `S` and `R` represent the `TranscodingStream` types associated with the
(potentially compressed) stream that writes the file information and the raw
`ZipArchiveOutputStream` where this object writes associated file metadata.

You can only have one `ZipFileOutputStream` open per `ZipArchiveOutputStream`.
Attempts to open a second file in the same archive will issue a warning and
automatically close the previous file before opening the new file.

You should not call the struct constructor directly: instead, use
`open(archive, filename)`.
"""
mutable struct ZipFileOutputStream{S<:IO,R<:IO} <: IO
    sink::S
    info::ZipFileInformation
    comment::String
    offset::UInt64

    _raw_sink::R
    _crc32::UInt32
    # don't close twice
    _closed::Bool
end

function Base.show(io::IO, zf::ZipFileOutputStream)
    fname = zf.info.name
    compression = compression_string(zf.info.compression_method)
    csize = bytes_written(zf)
    if zf.info.compression_method == compression_code(:store) || usize == 0
        size_string = human_readable_bytes(csize)
    else
        usize = uncompressed_bytes_written(zf)
        size_string = @sprintf("%s, %s compressed (%0.2f%%)", human_readable_bytes(usize), human_readable_bytes(csize), csize/usize)
    end
    eof_string = zf._closed ? ", closed" : ""
    print(io, "ZipFileSink(<$fname> $compression $size_string written$eof_string)")
    return
end

"""
    close(zipoutfile)

Closes a `ZipFileOutputStream`. This method must be called before closing the
enclosing `ZipArchiveOutputStream` or before opening a new `ZipFileOutputStream`
in the same archive so that the appropriate Data Descriptor information can be
written to disk and the file can be added to the archive.

It is automatically called by `close(zipoutarchive)` and the finalizer routine of
`ZipFileOutputStream` objects, but it is best practice to close the file manually
when you have finished writing to it.

# Examples
```julia
```
"""
function Base.close(zipfile::ZipFileOutputStream; _uncompressed_size::Union{UInt64,Nothing}=nothing)
    if zipfile._closed
        @debug "File already closed"
        return
    end
    crc = zipfile._crc32
    @debug "Flushing writes to file" bytes=zipfile._bytes_written
    write(zipfile.sink, TranscodingStreams.TOKEN_END)
    flush(zipfile.sink)
    compressed_size = bytes_written(zipfile)
    if isnothing(_uncompressed_size)
        uc_size = uncompressed_bytes_written(zipfile)
    else
        uc_size = _uncompressed_size
    end
    # FIXME: Not atomic!
    # NOTE: not standard per se, but more common than not to use a signature here.
    if zipfile.info.descriptor_follows
        writele(zipfile._raw_sink, SIG_DATA_DESCRIPTOR)
        writele(zipfile._raw_sink, crc)
        # Force Zip64 no matter the actual sizes
        writele(zipfile._raw_sink, compressed_size)
        writele(zipfile._raw_sink, uc_size)
    else
        if crc != zipfile.info.crc32 || compressed_size != zipfile.info.compressed_size || uc_size != zipfile.info.uncompressed_size
            @error "File data written to archive does not match local header data" crc32_header=zipfile.info.crc32 crc32_file=crc csize_header=zipfile.info.compressed_size csize_file=compressed_size usize_header=zipfile.info.uncompressed_size usize_file=uc_size
            error("file data written to archive does not match local header data")
        end
    end

    # Only force Zip64 in the Central Directory if necessary
    zip64 = zipfile.offset >= typemax(UInt32) || compressed_size >= typemax(UInt32) || uc_size >= typemax(UInt32)
    directory_info = ZipFileInformation(
        zipfile.info.compression_method,
        uc_size,
        compressed_size,
        now(),
        crc,
        zipfile.info.name,
        true,
        zipfile.info.utf8,
        zip64,
    )
    push!(
        zipfile._raw_sink.directory,
        CentralDirectoryHeader(
            directory_info,
            zipfile.offset,
            zipfile.comment,
            false,
        ),
    )

    zipfile._closed = true

    # clear the referenced open file (not atomic!)
    zipfile._raw_sink._open_file = Ref{ZipFileOutputStream}()

    return
end

function Base.write(zipfile::ZipFileOutputStream, value::UInt8)
    if zipfile._closed
        throw(EOFError())
    end
    zipfile._crc32 = crc32(value, zipfile._crc32)
    return write(zipfile.sink, value)
end

function Base.unsafe_write(zf::ZipFileOutputStream, p::Ptr{UInt8}, n::UInt)
    if zf._closed
        throw(EOFError())
    end
    zf._crc32 = crc32(p, n, zf._crc32)
    return unsafe_write(zf.sink, p, n)
end

Base.flush(zf::ZipFileOutputStream) = flush(zf.sink)
Base.isopen(zf::ZipFileOutputStream) = isopen(zf.sink)
Base.isreadable(zf::ZipFileOutputStream) = false
Base.iswritable(zf::ZipFileOutputStream) = !zf._closed && iswritable(zf.sink)

"""
    bytes_written(zf::ZipFileOutputStream) -> UInt64

Return the number of possibly compressed bytes written to the file so far.

This function avoids the ambiguity of "position" when called on an output stream
which has no well-defined starting point.

Note: in order to get an accurate count, flush any buffered but unwritten data
with `flush(zf)` before calling this method.
"""
function bytes_written(zf::ZipFileOutputStream)
    stat = TranscodingStreams.stats(zf.sink)
    offset = stat.out % UInt64
    return offset
end

"""
    uncompressed_bytes_written(zf::ZipFileOutputStream) -> UInt64

Return the number of uncompressed bytes written to the file so far.

This function avoids the ambiguity of "position" when called on an output stream
which has no well-defined starting point.

Note: in order to get an accurate count, flush any buffered but unwritten data
with `flush(zf)` before calling this method.
"""
function uncompressed_bytes_written(zf::ZipFileOutputStream)
    stat = TranscodingStreams.stats(zf.sink)
    offset = stat.in % UInt64
    return offset
end

"""
    ZipArchiveOutputStream

A struct for appending to Zip archives.

Zip archives are optimized for appending to the end of the archive. This struct
is used in tandem with library functions to keep track of what is appended to a
Zip archive so that a proper Central Directory can be written at the end.

Users should not call the `ZipArchiveOutputStream` constructor: instead, use the
[`zipsink`](@ref) method to create a new streaming archive.

# Examples
```julia
```
"""
mutable struct ZipArchiveOutputStream{S<:IO} <: IO
    sink::S
    directory::Vector{CentralDirectoryHeader}

    utf8::Bool
    comment::String

    _folders_created::Set{String}
    _open_file::Ref{ZipFileOutputStream}
    _is_closed::Bool
end

function Base.show(io::IO, za::ZipArchiveOutputStream)
    nbytes = bytes_written(za)
    entries = length(za.directory)
    byte_string = "byte" * (nbytes == 1 ? "" : "s")
    entries_string = "entr" * (nbytes == 1 ? "y" : "ies")
    eof_string = isopen(za) ? "" : ", closed"
    print(io, "ZipArchiveSink(<$nbytes $byte_string, $entries $entries_string written$eof_string>)")
    return
end

"""
    zipsink(fname; [keyword arguments]) -> ZipArchiveOutputStream
    zipsink(io; [keyword arguments]) -> ZipArchiveOutputStream
    zipsink(f, args...)

Open an `IO` stream of a Zip archive for writing data.

# Positional arguments
- `fname::AbstractString`: The name of a Zip archive file to open for writing.
Will be created if the file does not exist. If the file does exist, it will be
truncated before writing.
- `io::IO`: An `IO` object that can be written to. The object will be closed when
you call `close` on the returned object.
- `f<:Function`: A unary function to which the opened stream will be passed. This
method signature allows for `do` block usage. When called with the signature, the
return value of `f` will be returned to the user.

# Keyword arguments
- `utf8::Bool=true`: Encode file names and comments with UTF-8 encoding. If
`false`, follows the Zip standard of treating text as encoded in IBM437 encoding.
- `comment::AbstractString=""`: A comment to store with the Zip archive. This
information is stored in plain text at the end of the archive and does not affect
the Zip archive in any other way. The comment is always stored using IBM437
encoding.

!!! note "Using `IO` argument"

    Passing an `IO` object as the first argument will use the object as-is,
    overwriting from the current position of the stream and writing the Central
    Directory after closing the stream without truncating the remainder. This
    use of `zipsink` is recommended for advanced users only who need to write
    Zip archives to write-only streams (e.g., network pipes).
"""
function zipsink(fname::AbstractString, args...; kwargs...)
    return zipsink(Base.open(fname, "w"), args...; kwargs...)
end

function zipsink(
    sink::IO;
    utf8::Bool = true,
    comment::AbstractString = ""
)
    directory = CentralDirectoryHeader[]
    outsink = TranscodingStreams.NoopStream(sink)
    z = ZipArchiveOutputStream(
        outsink,
        directory,
        utf8,
        comment,
        Set{String}(),
        Ref{ZipStreams.ZipFileOutputStream}(),
        false,
    )
    return z
end

function zipsink(f::F, args...; kwargs...) where {F<:Function}
    zs = zipsink(args...; kwargs...)
    val = f(zs)
    close(zs)
    return val
end

function Base.close(archive::ZipArchiveOutputStream; close_sink::Bool=true)
    if archive._is_closed
        return
    end
    # close the potentially open file
    if isassigned(archive._open_file)
        close(archive._open_file[])
    end
    # write the Central Directory headers
    stat = TranscodingStreams.stats(archive.sink)
    startpos = stat.transcoded_out
    write_directory(archive.sink, archive.directory; startpos=startpos, comment=archive.comment, utf8=archive.utf8)
    if close_sink
        close(archive.sink)
    end
    archive._is_closed = true
    return
end

"""
    mkdir(archive, path; comment="")

Make a directory within a Zip archive.

If the parent directory does not exist, an error will be thrown. Use
[`mkpath`](@ref) to create the entire directory tree at once. If given, the
`comment` string will be added to the archive's metadata for the directory.

Directories in Zip archives are merely length zero files with names that end in
the `'/'` character.
"""
function Base.mkdir(ziparchive::ZipArchiveOutputStream, path::AbstractString; comment::AbstractString="")
    paths = split(path, ZIP_PATH_DELIMITER; keepempty=false)
    if isempty(paths)
        return path
    end
    for i in 1:length(paths)-1
        p = join(paths[1:i], ZIP_PATH_DELIMITER)
        if p ∉ ziparchive._folders_created
            error("cannot create directory '$path': path '$p' does not exist")
        end
    end
    path = join(paths, ZIP_PATH_DELIMITER)
    info = ZipFileInformation(
        COMPRESSION_STORE,
        0,
        0,
        now(),
        0,
        path * ZIP_PATH_DELIMITER,
        false,
        ziparchive.utf8,
        false,
    )
    # get the offset before writing anything
    stat = TranscodingStreams.stats(ziparchive.sink)
    offset = stat.transcoded_out % UInt64
    local_file_header = LocalFileHeader(info)
    nb = write(ziparchive, local_file_header)
    central_directory_header = CentralDirectoryHeader(info, offset, comment, true)
    push!(ziparchive.directory, central_directory_header)
    push!(ziparchive._folders_created, path)
    return nb
end

"""
    mkpath(archive, path; comment="")

Make a directory within a Zip archive.

If the parent directory does not exist, all parent paths will be created. If
given, the `comment` string will be added to the archive's metadata for the final
path element (all other created parent paths will have no comment).

Directories in Zip archives are merely length zero files with names that end in
the `'/'` character.
"""
function Base.mkpath(ziparchive::ZipArchiveOutputStream, path::AbstractString; comment::AbstractString="")
    paths = split(path, ZIP_PATH_DELIMITER; keepempty=false)
    nb = 0
    if isempty(paths)
        return nb
    end
    for i in 1:length(paths)-1
        p = join(paths[1:i], "/")
        if p ∉ ziparchive._folders_created
            nb += mkdir(ziparchive, p)
        end
    end
    return nb + mkdir(ziparchive, path; comment=comment)
end

function Base.write(za::ZipArchiveOutputStream, value::UInt8)
    return write(za.sink, value)
end

function Base.unsafe_write(za::ZipArchiveOutputStream, x::Ptr{UInt8}, n::UInt)
    return unsafe_write(za.sink, x, n)
end


"""
    open(sink, fname; [keyword arguments]) -> IO

Create a file within a Zip archive and return a handle for writing.


# Keyword arguments
- `compression::Union{UInt16,Symbol} = :deflate`: Can be one of `:deflate`,
`:store`, or the associated codes defined by the Zip archive standard (`0x0008`
or `0x0000`, respectively). Determines how the data is compressed when writing to
the archive.
- `utf8::Bool = true`: If `true`, the file name and comment will be written to the
archive metadata encoded in UTF-8 strings, and a flag will be set in the metadata
to instruct decompression programs to read these strings as such. If `false`, the
default IBM437 encoding will be used. This does not affect the file data itself.
- `comment::AbstractString = ""`: Comment metadata to add to the archive about the
file. This does not affect the file data itself.
- `data = nothing`: Data to write for all-at-once file writing. If this is not
`nothing`, its will be written to the archive (using `write(io, data)`) all at
once rather than streaming. The file object will be closed immediately, and
`nothing` will be returned.

!!! warning "Duplicate file names"

    The Zip archive specification does not clearly define what to do if multiple
    files in the Zip archive share the same name. This method will allow the user
    to create files with the same name in a single Zip archive, but other software
    may not behave as expected when reading the archive.

!!! note "Streaming output"

    File written using `ZipFileOutputStream` methods are incompatable with the
    streaming reading methods of `ZipFileInputStream`. This is because the
    program cannot not know the final compressed and uncompressed file size nor
    the CRC-32 checksum while writing until the file is closed, meaning these
    fields are not accurate in the Local File Header. The streaming reader relies
    on file size information in the Local File Header to know when to stop reading
    file data, thus the two methods are incompatable.

# Examples
```julia
```
"""
function Base.open(
    archive::ZipArchiveOutputStream,
    fname::AbstractString;
    compression::Symbol = :deflate,
    utf8::Bool = true,
    comment::AbstractString = "",
    _uncompressed_size::UInt64 = UInt64(0),
    _compressed_size::UInt64 = UInt64(0),
    _crc::UInt32 = CRC32_INIT,
    _precalculated::Bool = false,
)
    # warn if file already open
    if isassigned(archive._open_file)
        @warn "Opening a new file in an archive closes the previously opened file" previous=archive._open_file[].info
        close(archive._open_file[])
    end

    # 0. check for directories and deal with them accordingly
    if endswith(fname, "/")
        error("file names cannot end in '/'")
    end
    path = split(fname, "/", keepempty=false) # can't trust dirname on Windows
    if length(path) > 1
        mkpath(archive, join(path[1:end-1], "/"))
    end

    # 1. write local header to parent
    ccode = compression_code(compression)
    # get the offset before the local header is written
    flush(archive)
    offset = bytes_written(archive)
    # Branch: if writing all at once, use precalculated size
    if _precalculated
        use_descriptor = false
        zip64 = offset >= typemax(UInt32) || _uncompressed_size >= typemax(UInt32) || _compressed_size >= typemax(UInt32)
    else
        use_descriptor = true
        zip64 = true # always use Zip64 if size is unknown
    end
    info = ZipFileInformation(
        ccode,
        _uncompressed_size,
        _compressed_size,
        now(),
        _crc,
        fname,
        use_descriptor,
        utf8,
        zip64,
    )
    local_file_header = LocalFileHeader(info)
    write(archive, local_file_header)

    # 2. set up compression stream
    if _precalculated || compression == :store
        codec = Noop()
    elseif compression == :deflate
        codec = DeflateCompressor()
    else
        # How did I end up here?
        error("undefined compression type $compression")
    end
    filesink = TranscodingStream(codec, archive)

    # 3. create file object
    zipfile = ZipFileOutputStream(
        filesink,
        info,
        comment,
        offset,
        archive,
        CRC32_INIT,
        false,
    )

    # 4. set file as open (clears the previous open reference)
    archive._open_file[] = zipfile

    # 5. return the file object
    return zipfile

end

function Base.open(f::F, archive::ZipArchiveOutputStream, fname::AbstractString; kwargs...) where {F<:Function}
    zf = Base.open(archive, fname; kwargs...)
    val = f(zf)
    close(zf)
    return val
end

"""
    write_file(sink, fname, data; [keyword arguments])

Archive data to a new file in the archive all at once.

This is a convenience method that will create a new file in the archive with name
`filename` and write all of `data` to that file. The `data` argument can be anything
for which the method `write(io, data)` is defined.

Returns nothing.

Keyword arguments are the same as those accepted by `open(sink, fname)`.
"""
function write_file(
    archive::ZipArchiveOutputStream,
    fname::AbstractString,
    data;
    compression::Symbol = :deflate,
    kwargs...
    )

    # 0. Compress the data if necessary
    buffer = IOBuffer()
    write(buffer, data)
    raw_data = take!(buffer)
    uncompressed_size = sizeof(raw_data) % UInt64
    if compression == :deflate
        compressed_data = transcode(DeflateCompressor, raw_data)
    elseif compression == :store
        compressed_data = raw_data
    else
        error("undefined compression type $compression")
    end
    compressed_size = sizeof(compressed_data) % UInt64
    crc = crc32(compressed_data)

    io = Base.open(archive, fname; _precalculated=true, _uncompressed_size=uncompressed_size, _compressed_size=compressed_size, _crc=crc, kwargs...)
    n_written = write(io, compressed_data)
    close(io; _uncompressed_size=uncompressed_size)

    return n_written
end

Base.flush(za::ZipArchiveOutputStream) = flush(za.sink)
Base.isopen(za::ZipArchiveOutputStream) = isopen(za.sink)
Base.isreadable(za::ZipArchiveOutputStream) = false
Base.iswritable(za::ZipArchiveOutputStream) = iswritable(za.sink)

"""
    bytes_written(za::ZipArchiveOutputStream) -> UInt64

Return the number of bytes written to the archive so far.

This function avoids the ambiguity of "position" when called on an output stream
which has no well-defined starting point.

Note: in order to get an accurate count, flush any buffered but unwritten data
with `flush(za)` before calling this method.
"""
function bytes_written(za::ZipArchiveOutputStream)
    stat = TranscodingStreams.stats(za.sink)
    offset = stat.transcoded_out % UInt64
    return offset
end