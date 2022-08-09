import Base: open, close, mkdir, mkpath

using Dates
using TranscodingStreams

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
mutable struct ZipArchiveOutputStream{S<:IO}
    sink::S
    directory::Vector{CentralDirectoryHeader}

    utf8::Bool
    comment::String

    _folders_created::Set{String}
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
function zipsink(
    io::IO;
    utf8::Bool = true,
    comment::AbstractString = "",
)
    # assume the user knows their stuff
    return ZipArchiveOutputStream(
        io,
        CentralDirectoryHeader[],
        utf8,
        comment,
        Set{String}(),
    )
end

function zipsink(
    fname::AbstractString,
    mode::AbstractString="w";
    utf8::Bool = true,
    comment::AbstractString = "",
)
    if mode ∉ ("w", "a")
        error("expected mode of 'w' or 'a', got $(mode)")
    end
    sink = open(fname, mode)
    directory = CentralDirectoryHeader[]
    if mode == "a"
        # look for the CD and record the information for updating later
        seek_to_directory(sink)
        mark(sink)

        while true
            try
                cd_info = read(sink, CentralDirectoryHeader)
                push!(directory, cd_info)
            catch
                # TODO: should inspect exception to know if this is expected
            end
        end

        reset(sink) # move back to the CD so that it can be overwritten
    end

    return ZipArchiveOutputStream(sink, directory, utf8, comment, Set{String}())
end

zipsink(f::F, args...; kwargs...) where {F<:Function} = zipsink(args...; kwargs...) |> f

function Base.close(archive::ZipArchiveOutputStream)
    # write the Central Directory headers
    nb = 0
    startpos = position(archive.sink)
    zip64 = false
    for header in archive.directory
        nb += write(archive.sink, header)
        zip64 |= header.info.zip64
    end
    endpos = position(archive.sink)

    # write the EoCD, using Zip64 standard as necessary
    n_entries = UInt64(length(archive.directory))
    zip64 |= (nb >= typemax(UInt32) || startpos >= typemax(UInt32) || endpos >= typemax(UInt32) || n_entries >= typemax(UInt16))
    if zip64
        _write_zip64_eocd_record(archive.sink, n_entries, UInt64(nb), UInt64(startpos))
        _write_zip64_eocd_locator(archive.sink, UInt64(endpos))
        _write_eocd_record(archive.sink, typemax(UInt16), typemax(UInt32), typemax(UInt32), archive.comment)
    else
        _write_eocd_record(archive.sink, n_entries % UInt16, nb % UInt32, startpos % UInt32, archive.comment)
    end

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
    path = join(paths, "/") * "/"
    offset = position(ziparchive.sink)
    info = ZipFileInformation(
        COMPRESSION_STORE,
        0,
        0,
        now(),
        0,
        offset,
        path,
        comment,
        false,
        ziparchive.utf8,
        false,
    )
    local_file_header = LocalFileHeader(info)
    write(ziparchive.sink, local_file_header)
    central_directory_header = CentralDirectoryHeader(info)
    push!(ziparchive.directory, central_directory_header)
    push!(ziparchive._folders_created, path)
    return path
end

function Base.mkpath(ziparchive::ZipArchiveOutputStream, path::AbstractString; comment::AbstractString="")
    paths = split(path, ZIP_PATH_DELIMITER; keepempty=false)
    if isempty(paths)
        return path
    end
    for i in 1:length(paths)-1
        p = join(paths[1:i], "/")
        if p ∉ ziparchive._folders_created
            mkdir(ziparchive, p)
        end
    end
    return mkdir(ziparchive, path)
end

mutable struct ZipFileOutputStream{S1<:IO, S2<:IO} <: IO
    sink::S1
    info::ZipFileInformation

    #! NOT THREAD SAFE!
    parent::ZipArchiveOutputStream{S2}

    # don't close twice
    _closed::Bool
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
    compression::UInt16 = COMPRESSION_DEFLATE,
    utf8::Bool = true,
    comment::AbstractString = "",
)
    # 0. check for directories and deal with them accordingly
    if endswith(fname, "/")
        error("file names cannot end in '/'")
    end
    path = split(fname, "/", keepempty=false) # can't trust dirname on Windows
    if length(path) > 1
        mkpath(archive, join(path[1:end-1], "/"))
    end

    # 1. write local header to parent
    raw_sink = archive.sink
    offset = position(raw_sink)
    info = ZipFileInformation(
        compression,
        0,
        0,
        now(),
        0,
        offset,
        fname,
        comment,
        true,
        utf8,
        true,
    )
    local_file_header = LocalFileHeader(info)
    write(raw_sink, local_file_header)

    # 2. set up compression stream
    if compression == COMPRESSION_DEFLATE
        codec = DeflateCompressor()
    elseif compression == COMPRESSION_STORE
        codec = Noop()
    else
        error("undefined compression type $compression")
    end
    transcoder = TranscodingStream(codec, raw_sink)
    filesink = CRC32OutputStream(transcoder)

    # 3. create file object
    zipfile = ZipFileOutputStream(
        filesink,
        info,
        archive,
        false,
    )

    # 4. set up finalizer
    finalizer(close, zipfile)

    # 5. return file object
    return zipfile
end

function Base.close(zipfile::ZipFileOutputStream)
    if zipfile._closed
        return
    end
    flush(zipfile.sink)
    crc32 = zipfile.sink.crc32
    # NOTE: always Zip64 format
    compressed_size = zipfile.sink.bytes_written
    uncompressed_size = UInt64(TranscodingStreams.stats(zipfile.sink.sink).transcoded_in)

    # FIXME: Not atomic!
    writele(zipfile.parent.sink, crc32)
    writele(zipfile.parent.sink, compressed_size)
    writele(zipfile.parent.sink, uncompressed_size)

    directory_info = ZipFileInformation(
        zipfile.info.compression_method,
        uncompressed_size,
        compressed_size,
        now(),
        crc32,
        zipfile.info.offset,
        zipfile.info.name,
        zipfile.info.comment,
        true,
        zipfile.info.utf8,
        zipfile.info.zip64,
    )
    push!(zipfile.parent.directory, CentralDirectoryHeader(directory_info))

    zipfile._closed = true
    return
end

function Base.write(zipfile::ZipFileOutputStream, value::UInt8)
    if zipfile._closed
        error("attempted write to closed file")
    end
    return write(zipfile.sink, value)
end



