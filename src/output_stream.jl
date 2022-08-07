import Base: open, close

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
    use_signatures::Bool
    comment::String
end

mutable struct ZipFileOutputStream{S<:IO} <: IO
    sink::S
    write_signature::Bool

    #! NOT THREAD SAFE!
    parent_archive::ZipArchiveOutputStream
    header_crc_pos::Int
    header_compressed_size_pos::Int
    header_uncompressed_size_pos::Int

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
    use_signature::Bool = false,
    comment::AbstractString = "",
)
    # 1. write local header to parent
    offset = position(archive.sink)
    info = ZipFileInformation(
        compression,
        0,
        0,
        now(),
        0,
        offset,
        fname,
        comment,
        use_signature,
        utf8,
        true,
    )
    local_file_header = LocalFileHeader(info)
    nb = write(archive.sink, local_file_header)

    # 2. record parent position of signature
    # TODO: deal with non-Zip64 files?
    # Always in the same place for Zip64 files written how we write them.
    header_crc_pos = offset + 14
    header_uncompressed_size_pos = offset + nb - 16
    header_compressed_size_pos = header_uncompressed_size_pos + 8

    # 3. set up compression stream
    if compression == COMPRESSION_DEFLATE
        codec = DeflateCompressor()
    elseif compression == COMPRESSION_STORE
        codec = Noop()
    else
        error("undefined compression type $compression")
    end
    transcoder = TranscodingStream(codec, archive.sink)
    filesink = CRC32OutputStream(transcoder)

    # 4. create file object
    zipfile = ZipFileOutputStream(
        filesink,
        use_signature,
        archive,
        header_crc_pos,
        header_compressed_size_pos,
        header_uncompressed_size_pos,
        false,
    )

    # 5. set up finalizer
    finalizer(close, zipfile)

    # 6. return file object
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
    uncompressed_size = TranscodingStreams.stats(zipfile.sink.sink).transcoded_in

    if zipfile.write_signature
        # FIXME: Not atomic!
        writele(zipfile.parent_archive.sink, crc32)
        writele(zipfile.parent_archive.sink, compressed_size)
        writele(zipfile.parent_archive.sink, uncompressed_size)
    else
        # FIXME: Not atomic!
        mark(zipfile.parent_archive.sink)
        seek(zipfile.parent_archive.sink, zipfile.header_crc_pos)
        writele(zipfile.parent_archive.sink, crc32)
        seek(zipfile.parent_archive.sink, zipfile.header_uncompressed_size_pos)
        writele(zipfile.parent_archive.sink, uncompressed_size)
        seek(zipfile.parent_archive.sink, zipfile.header_compressed_size_pos)
        writele(zipfile.parent_archive.sink, compressed_size)
        reset(zipfile.parent_archive.sink)
    end
    zipfile._closed = true
    return
end

Base.write(zipfile::ZipFileOutputStream, value::UInt8) = write(zipfile.sink, value)

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
- `use_signatures::Bool=false`: Use signatures after the file data to record
written file size, original file size, and CRC-32 checksum data. If `true`, the
data will be written to stream in a truly write-only fashion; if `false`, the
sink stream must be seekable to allow overwriting previously-written Local File
Header data with the proper information. Setting `use_signatures` to `true` speeds
up writing data, but it may make the resulting archive incompatable with stream
reading.
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
    use_signatures::Bool = false,
    comment::AbstractString = "",
)
    # assume the user knows their stuff
    return ZipArchiveOutputStream(
        io,
        CentralDirectoryHeader[],
        utf8,
        use_signatures,
        comment,
    )
end

function zipsink(
    fname::AbstractString,
    mode::AbstractString="w";
    utf8::Bool = true,
    use_signatures::Bool = false,
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

    return ZipArchiveOutputStream(sink, directory, utf8, use_signatures, comment)
end

zipsink(f::F, args...; kwargs...) where {F<:Function} = zipsink(args...; kwargs...) |> f