import Base: open, close, mkdir, mkpath, write, unsafe_write, flush, isopen, iswritable, isreadable, position

using Dates
using TranscodingStreams

mutable struct ZipFileOutputStream{S<:IO,R<:IO} <: IO
    sink::S
    info::ZipFileInformation
    comment::String
    offset::UInt64

    _raw_sink::R
    _bytes_written::UInt64
    # don't close twice
    _closed::Bool
end

function Base.close(zipfile::ZipFileOutputStream)
    if zipfile._closed
        @debug "File already closed"
        return
    end
    crc32 = zipfile.sink.crc32
    @debug "Flushing writes to file" bytes=zipfile._bytes_written
    write(zipfile.sink.sink, TranscodingStreams.TOKEN_END)
    flush(zipfile.sink.sink)
    stats = TranscodingStreams.stats(zipfile.sink.sink)
    @debug "Stats read from closed sink" stats
    compressed_size = stats.transcoded_out % UInt64
    uncompressed_size = stats.transcoded_in % UInt64
    # FIXME: Not atomic!
    # NOTE: not standard per se, but more common than not to use a signature here.
    writele(zipfile._raw_sink, SIG_DATA_DESCRIPTOR)
    writele(zipfile._raw_sink, crc32)
    # Force Zip64 no matter the actual sizes
    writele(zipfile._raw_sink, compressed_size)
    writele(zipfile._raw_sink, uncompressed_size)

    directory_info = ZipFileInformation(
        zipfile.info.compression_method,
        uncompressed_size,
        compressed_size,
        now(),
        crc32,
        zipfile.info.name,
        true,
        zipfile.info.utf8,
        true, # force Zip64 format
    )
    push!(zipfile._raw_sink.directory, CentralDirectoryHeader(directory_info, zipfile.offset, zipfile.comment))

    zipfile._closed = true

    # clear the referenced open file (not atomic!)
    zipfile._raw_sink._open_file = Ref{ZipFileOutputStream}()

    return
end

function Base.write(zipfile::ZipFileOutputStream, value::UInt8)
    if zipfile._closed
        throw(EOFError())
    end
    @debug "Writing byte to zipfile" value
    nb = write(zipfile.sink, value)
    zipfile._bytes_written += nb
    @debug "Bytes written so far" bytes=zipfile._bytes_written
    return nb
end

function Base.unsafe_write(zf::ZipFileOutputStream, p::Ptr{UInt8}, n::UInt)
    if zf._closed
        throw(EOFError())
    end
    @debug "Writing bytes to zipfile" p n
    nb = unsafe_write(zf.sink, p, n)
    zf._bytes_written += nb
    @debug "Bytes written so far" bytes=zf._bytes_written
    return nb
end

Base.flush(zf::ZipFileOutputStream) = flush(zf.sink)
Base.position(zf::ZipFileOutputStream) = zf._bytes_written
Base.isopen(zf::ZipFileOutputStream) = isopen(zf.sink)
Base.isreadable(zf::ZipFileOutputStream) = false
Base.iswritable(zf::ZipFileOutputStream) = iswritable(zf.sink)


"""
    ZipArchiveOutputStream

A struct for appending to Zip archives.

Zip archives are optimized for appending to the end of the archive. This struct
is used in tandem with library functions to keep track of what is appended to a
Zip archive so that a proper Central Directory can be written at the end.

Use the [`zipsink`](@ref) method to open an existing Zip archive file or to
create a new one.

# Examples
"""
mutable struct ZipArchiveOutputStream{S<:IO} <: IO
    sink::S
    directory::Vector{CentralDirectoryHeader}

    utf8::Bool
    comment::String

    _folders_created::Set{String}
    _bytes_written::UInt64
    _open_file::Ref{ZipFileOutputStream}
end

"""
    zipsink(fname, [mode=:append]; [keyword arguments]) -> ZipArchiveOutputStream
    zipsink(io; [keyword arguments]) -> ZipArchiveOutputStream
    zipsink(f, args...)

Open an `IO` stream of a Zip archive for writing data.

# Positional arguments
- `fname::AbstractString`: The name of a Zip archive file to open for writing.
Will be created if the file does not exist.
- `mode::AbstractString="a"`: The operation mode of the stream. Can be any of the
following:
| Mode | Description |
|:-----|:------------|
| `w`  | Write to the file, creating it if it does not exist, and truncating the length to zero. |
| `a`  | Append to the file, overwriting the Central Directory at the end (if detected) with updated contents. |

- `f<:Function`: A unary function to which the opened stream will be passed. This
method signature allows for `do` block usage. When called with the signature, the
return value of `f` will be returned to the user.

# Keyword arguments
- `utf8::Bool=true`: Encode file names and comments with UTF-8 encoding. If
`false`, follows the Zip standard of treating text as encoded in IBM437 encoding.
- `comment::AbstractString=""`: A comment to store with the Zip archive. This
information is stored in plain text at the end of the archive and does not affect
the Zip archive in any other way.

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
    z = ZipArchiveOutputStream(sink, directory, utf8, comment, Set{String}(), 0 % UInt64, Ref{ZipStreams.ZipFileOutputStream}())
    finalizer(close, z)
    return z
end

zipsink(f::F, args...; kwargs...) where {F<:Function} = zipsink(args...; kwargs...) |> f

function Base.close(archive::ZipArchiveOutputStream)
    # close the potentially open file
    if isassigned(archive._open_file)
        close(archive._open_file[])
    end
    # write the Central Directory headers
    write_directory(archive.sink, archive.directory; startpos=archive._bytes_written, comment=archive.comment, utf8=archive.utf8)
    close(archive.sink)
end

function Base.mkdir(ziparchive::ZipArchiveOutputStream, path::AbstractString; comment::AbstractString="")
    paths = split(path, ZIP_PATH_DELIMITER; keepempty=false)
    if isempty(paths)
        return path
    end
    for i in 1:length(paths)-1
        p = join(paths[1:i], "/")
        if p ∉ ziparchive._folders_created
            error("cannot create directory '$path': path '$p' does not exist")
        end
    end
    path = join(paths, "/")
    info = ZipFileInformation(
        COMPRESSION_STORE,
        0,
        0,
        now(),
        0,
        path * "/",
        false,
        ziparchive.utf8,
        false,
    )
    offset = ziparchive._bytes_written
    local_file_header = LocalFileHeader(info)
    nb = write(ziparchive, local_file_header)
    central_directory_header = CentralDirectoryHeader(info, offset, comment, true)
    push!(ziparchive.directory, central_directory_header)
    push!(ziparchive._folders_created, path)
    return nb
end

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
    nb = write(za.sink, value)
    za._bytes_written += nb
    return nb
end

function Base.unsafe_write(za::ZipArchiveOutputStream, x::Ptr{UInt8}, n::UInt)
    nb = unsafe_write(za.sink, x, n)
    za._bytes_written += nb
    return nb
end


"""
    open(sink, fname; [keyword arguments]) -> IO

Create a file within a Zip archive and return a handle for writing.

!!! warning "Duplicate file names"

    The Zip archive specification does not clearly define what to do if multiple
    files in the Zip archive share the same name. This method will allow the user
    to create files with the same name in a single Zip archive, but other software
    may not behave as expected when reading the archive.
"""
function Base.open(
    archive::ZipArchiveOutputStream,
    fname::AbstractString;
    compression::Symbol = :deflate,
    utf8::Bool = true,
    comment::AbstractString = "",
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
    offset = position(archive)
    info = ZipFileInformation(
        ccode,
        0,
        0,
        now(),
        0,
        fname,
        true,
        utf8,
        true, # because the final file size is unknown, always use Zip64.
    )
    local_file_header = LocalFileHeader(info)
    write(archive, local_file_header)

    # 2. set up compression stream
    if compression == :deflate
        codec = DeflateCompressor()
    elseif compression == :store
        codec = Noop()
    else
        error("undefined compression type $compression")
    end
    transcoder = TranscodingStream(codec, archive)
    filesink = CRC32OutputStream(transcoder)

    # 3. create file object
    zipfile = ZipFileOutputStream(
        filesink,
        info,
        comment,
        offset,
        archive,
        0 % UInt64,
        false,
    )

    # 4. set file as open (clears the previous open reference)
    archive._open_file[] = zipfile

    # 5. set up finalizer
    finalizer(close, zipfile)

    # 6. return file object
    return zipfile
end

Base.flush(za::ZipArchiveOutputStream) = flush(za.sink)
Base.position(za::ZipArchiveOutputStream) = za._bytes_written
Base.isopen(za::ZipArchiveOutputStream) = isopen(za.sink)
Base.isreadable(za::ZipArchiveOutputStream) = false
Base.iswritable(za::ZipArchiveOutputStream) = iswritable(za.sink)

