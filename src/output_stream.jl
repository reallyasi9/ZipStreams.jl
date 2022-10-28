import Base: open, close, mkdir, mkpath, write, unsafe_write, flush, isopen, iswritable, isreadable, position

using Dates
using TranscodingStreams

"""
    ZipFileSink{S,R}([arguments])

A struct representing an open streamable file in a `ZipArchiveSink`.

This struct is an `IO` object, so it inherits `write()` and `unsafe_write()`
methods from `IO`. You cannot read from this type, nor can you seek, skip, or
read the file's position. It functions in this way to allow writing to write-only
streams (like HTTP output).

The types `S` and `R` represent the `TranscodingStream` types associated with the
(potentially compressed) stream that writes the file information and the raw
`ZipArchiveSink` where this object writes associated file metadata.

You can only have one `ZipFileSink` open per `ZipArchiveSink`.
Attempts to open a second file in the same archive will issue a warning and
automatically close the previous file before opening the new file.

You should not call the struct constructor directly: instead, use
`open(archive, filename)`.
"""
mutable struct ZipFileSink{S<:IO,R<:IO} <: IO
    sink::S
    info::ZipFileInformation
    comment::String
    offset::UInt64

    _raw_sink::R
    _crc32::UInt32
    # don't close twice
    _closed::Bool
end

function Base.show(io::IO, zf::ZipFileSink)
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

Closes a `ZipFileSink`. This method must be called before closing the
enclosing `ZipArchiveSink` or before opening a new `ZipFileSink`
in the same archive so that the appropriate Data Descriptor information can be
written to disk and the file can be added to the archive.

It is automatically called by `close(zipoutarchive)` and the finalizer routine of
`ZipFileSink` objects, but it is best practice to close the file manually
when you have finished writing to it.
"""
function Base.close(
    zipfile::ZipFileSink;
    _uncompressed_size::Union{UInt64,Nothing}=nothing,
    _crc::Union{UInt32,Nothing}=nothing,
    )
    if zipfile._closed
        @debug "File already closed"
        return
    end
    if !isnothing(_crc)
        crc = _crc
    else
        crc = zipfile._crc32
    end
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
    zipfile._raw_sink._open_file = Ref{ZipFileSink}()

    return
end

function Base.write(zipfile::ZipFileSink, value::UInt8)
    if zipfile._closed
        throw(EOFError())
    end
    zipfile._crc32 = crc32(value, zipfile._crc32)
    return write(zipfile.sink, value)
end

function Base.unsafe_write(zf::ZipFileSink, p::Ptr{UInt8}, n::UInt)
    if zf._closed
        throw(EOFError())
    end
    zf._crc32 = crc32(p, n, zf._crc32)
    return unsafe_write(zf.sink, p, n)
end

Base.flush(zf::ZipFileSink) = flush(zf.sink)
Base.isopen(zf::ZipFileSink) = isopen(zf.sink)
Base.isreadable(zf::ZipFileSink) = false
Base.iswritable(zf::ZipFileSink) = !zf._closed && iswritable(zf.sink)

"""
    bytes_written(zf::ZipFileSink) -> UInt64

Return the number of possibly compressed bytes written to the file so far.

This function avoids the ambiguity of "position" when called on an output stream
which has no well-defined starting point.

Note: in order to get an accurate count, flush any buffered but unwritten data
with `flush(zf)` before calling this method.
"""
function bytes_written(zf::ZipFileSink)
    stat = TranscodingStreams.stats(zf.sink)
    offset = stat.out % UInt64
    return offset
end

"""
    uncompressed_bytes_written(zf::ZipFileSink) -> UInt64

Return the number of uncompressed bytes written to the file so far.

This function avoids the ambiguity of "position" when called on an output stream
which has no well-defined starting point.

Note: in order to get an accurate count, flush any buffered but unwritten data
with `flush(zf)` before calling this method.
"""
function uncompressed_bytes_written(zf::ZipFileSink)
    stat = TranscodingStreams.stats(zf.sink)
    offset = stat.in % UInt64
    return offset
end

"""
    ZipArchiveSink

A struct for appending to Zip archives.

Zip archives are optimized for appending to the end of the archive. This struct
is used in tandem with library functions to keep track of what is appended to a
Zip archive so that a proper Central Directory can be written at the end.

Users should not call the `ZipArchiveSink` constructor: instead, use the
[`zipsink`](@ref) method to create a new streaming archive.
"""
mutable struct ZipArchiveSink{S<:IO} <: IO
    sink::S
    directory::Vector{CentralDirectoryHeader}

    utf8::Bool
    comment::String

    _folders_created::Set{String}
    _open_file::Ref{ZipFileSink}
    _is_closed::Bool
end

function Base.show(io::IO, za::ZipArchiveSink)
    nbytes = bytes_written(za)
    entries = length(za.directory)
    byte_string = "byte" * (nbytes == 1 ? "" : "s")
    entries_string = "entr" * (nbytes == 1 ? "y" : "ies")
    eof_string = isopen(za) ? "" : ", closed"
    print(io, "ZipArchiveSink(<$nbytes $byte_string, $entries $entries_string written$eof_string>)")
    return
end

"""
    zipsink(fname; [keyword arguments]) -> ZipArchiveSink
    zipsink(io; [keyword arguments]) -> ZipArchiveSink
    zipsink(f, args...)

Open an `IO` stream of a Zip archive for writing data.

# Positional arguments
- `fname::AbstractString`: The name of a Zip archive file to open for writing. Will be created if the file does not exist. If the file does exist, it will be truncated before writing.
- `io::IO`: An `IO` object that can be written to. The object will be closed when you call `close` on the returned object.
- `f<:Function`: A unary function to which the opened stream will be passed. This method signature allows for `do` block usage. When called with the signature, the return value of `f` will be returned to the user.

# Keyword arguments
- `utf8::Bool=true`: Encode file names and comments with UTF-8 encoding. If `false`, follows the Zip standard of treating text as encoded in IBM437 encoding.
- `comment::AbstractString=""`: A comment to store with the Zip archive. This information is stored in plain text at the end of the archive and does not affect the Zip archive in any other way. The comment is always stored using IBM437 encoding.

!!! note "Using IO arguments"

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
    z = ZipArchiveSink(
        outsink,
        directory,
        utf8,
        comment,
        Set{String}(),
        Ref{ZipStreams.ZipFileSink}(),
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

function Base.close(archive::ZipArchiveSink; close_sink::Bool=true)
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

# From Base.splitdrive
const DRIVE_SPEC_RE = r"^[^\\]+:|\\\\[^\\]+\\[^\\]+|\\\\\?\\UNC\\[^\\]+\\[^\\]+|\\\\\?\\[^\\]+:"
# split and normalize the path (resolve . and .. elements)
# throws if the path is absolute or contains a Windows-like drive specifier as the first element
function _split_norm_path(path::AbstractString)
    m = match(DRIVE_SPEC_RE, path)
    if !isnothing(m)
        throw(ArgumentError("Windows-like drive specifiers cannot be used: path started with drive specifier '$(m.match)'"))
    end
    paths = split(path, ZIP_PATH_DELIMITER; keepempty=false)
    return paths
end

"""
    mkdir(archive, path; comment="")

Make a single directory within a ZIP archive.

Path elements in ZIP archives are separated by the forward slash character (`/`).
Backslashes (`\\`) and dots (`.` and `..`) are treated as literal characters in the
directory or file names. The final forward slash character will automatically be added to
the directory name when this method is used.

If any parent directory in the path does not exist, an error will be thrown. Use
[`mkpath`](@ref) to create the entire path at once, including parent paths. Empty directory
names (`//`) will be ignored, as will directories that have already been created in the
archive.

The `comment` string will be added to the archive's metadata for the directory. It does not
affect the stored data in any way.

Returns the number of bytes written to the archive when creating the directory.
"""
function Base.mkdir(ziparchive::ZipArchiveSink, path::AbstractString; comment::AbstractString="")
    paths = _split_norm_path(path)
    if isempty(paths)
        return 0
    end
    p = paths[1]
    for element in paths[2:end]
        if p ∉ ziparchive._folders_created
            error("cannot create directory '$path': path '$p' does not exist")
        end
        p *= ZIP_PATH_DELIMITER * element
    end
    if p ∈ ziparchive._folders_created
        return 0
    end
    info = ZipFileInformation(
        COMPRESSION_STORE,
        0,
        0,
        now(),
        0,
        p * ZIP_PATH_DELIMITER,
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
    push!(ziparchive._folders_created, p)
    return nb
end

"""
    mkpath(archive, path; comment="")

Make a directory and all its parent directories in a ZIP archive.

Path elements in ZIP archives are separated by the forward slash character (`/`).
Backslashes (`\\`) and dots (`.` and `..`) are treated as literal characters in the
directory or file names. The final forward slash character will automatically be added to
the directory name when this method is used.

If any parent directory in the path does not exist, it will be created automatically. Empty
directory names (`//`) will be ignored, as will directories that have already been created
in the archive.

The `comment` string will be added to the archive's metadata only for the last directory in
the path. All other directories created by this method will have no comment. This does not
affect the stored data in any way.

Returns the number of bytes written to the archive when creating p.
"""
function Base.mkpath(ziparchive::ZipArchiveSink, path::AbstractString; comment::AbstractString="")
    paths = _split_norm_path(path)
    nb = 0
    if isempty(paths)
        return nb
    end
    p = paths[1]
    for element in paths[2:end-1]
        if p ∉ ziparchive._folders_created
            nb += mkdir(ziparchive, p)
        end
        p *= ZIP_PATH_DELIMITER * element
    end
    return nb + mkdir(ziparchive, p; comment=comment)
end

function Base.write(za::ZipArchiveSink, value::UInt8)
    return write(za.sink, value)
end

function Base.unsafe_write(za::ZipArchiveSink, x::Ptr{UInt8}, n::UInt)
    return unsafe_write(za.sink, x, n)
end


"""
    open(sink, fname; [keyword arguments]) -> IO

Create a file within a Zip archive and return a handle for writing.

# Keyword arguments
- `compression::Union{UInt16,Symbol} = :deflate`: Can be one of `:deflate`, `:store`, or the associated codes defined by the Zip archive standard (`0x0008` or `0x0000`, respectively). Determines how the data is compressed when writing to the archive.
- `utf8::Bool = true`: If `true`, the file name and comment will be written to the archive metadata encoded in UTF-8 strings, and a flag will be set in the metadata to instruct decompression programs to read these strings as such. If `false`, the default IBM437 encoding will be used. This does not affect the file data itself.
- `comment::AbstractString = ""`: Comment metadata to add to the archive about the file. This does not affect the file data itself.
- `make_path::Bool = false`: If `true`, any directories in `fname` will be created first. If `false` and any directory in the path does not exist, an exception will be thrown.

!!! warning "Duplicate file names"

    The Zip archive specification does not clearly define what to do if multiple
    files in the Zip archive share the same name. This method will allow the user
    to create files with the same name in a single Zip archive, but other software
    may not behave as expected when reading the archive.

!!! note "Streaming output"

    File written using `ZipFileSink` methods are incompatable with the
    streaming reading methods of `ZipFileSource`. This is because the
    program cannot not know the final compressed and uncompressed file size nor
    the CRC-32 checksum while writing until the file is closed, meaning these
    fields are not accurate in the Local File Header. The streaming reader relies
    on file size information in the Local File Header to know when to stop reading
    file data, thus the two methods are incompatable.
"""
function Base.open(
    archive::ZipArchiveSink,
    fname::AbstractString;
    compression::Union{Symbol,UInt16} = :deflate,
    utf8::Bool = true,
    comment::AbstractString = "",
    make_path::Bool = false,
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
    if endswith(fname, ZIP_PATH_DELIMITER)
        throw(ArgumentError("file names cannot end in '$ZIP_PATH_DELIMITER'"))
    end
    path = split(fname, ZIP_PATH_DELIMITER, keepempty=false) # can't trust dirname on Windows
    if length(path) > 1
        parent = join(path[1:end-1], ZIP_PATH_DELIMITER)
        if parent ∉ archive._folders_created
            if make_path
                mkpath(archive, join(path[1:end-1], ZIP_PATH_DELIMITER))
            else
                throw(ArgumentError("parent path '$parent' does not exist"))
            end
        end
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
    if _precalculated || ccode == COMPRESSION_STORE
        codec = Noop()
    elseif ccode == COMPRESSION_DEFLATE
        codec = DeflateCompressor()
    else
        # How did I end up here?
        error("undefined compression type $compression")
    end
    filesink = TranscodingStream(codec, archive)

    # 3. create file object
    zipfile = ZipFileSink(
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

function Base.open(f::F, archive::ZipArchiveSink, fname::AbstractString; kwargs...) where {F<:Function}
    zf = Base.open(archive, fname; kwargs...)
    val = f(zf)
    close(zf)
    return val
end

"""
    write_file(sink, fname, data; [keyword arguments])

Archive `data` to a new file named `fname` in an archive sink all at once.

This is a convenience method that will create a new file in the archive with name
`fname` and write all of `data` to that file. The `data` argument can be anything
for which the method `write(io, data)` is defined.

Returns the number of bytes written to the archive.

Keyword arguments are the same as those accepted by [`open(::ZipArchiveSink, ::AbstractString)`](@ref).
"""
function write_file(
    archive::ZipArchiveSink,
    fname::AbstractString,
    data;
    compression::Union{Symbol,UInt16} = :deflate,
    kwargs...
    )

    # 0. Compress the data if necessary
    buffer = IOBuffer()
    write(buffer, data)
    raw_data = take!(buffer)
    uncompressed_size = sizeof(raw_data) % UInt64
    ccode = compression_code(compression)
    if ccode == COMPRESSION_DEFLATE
        compressed_data = transcode(DeflateCompressor, raw_data)
    elseif ccode == COMPRESSION_STORE
        compressed_data = raw_data
    else
        error("undefined compression type $compression")
    end
    compressed_size = sizeof(compressed_data) % UInt64
    crc = crc32(raw_data)

    io = Base.open(archive, fname; _precalculated=true, _uncompressed_size=uncompressed_size, _compressed_size=compressed_size, _crc=crc, kwargs...)
    n_written = write(io, compressed_data)
    close(io; _uncompressed_size=uncompressed_size, _crc=crc)

    return n_written
end

Base.flush(za::ZipArchiveSink) = flush(za.sink)
Base.isopen(za::ZipArchiveSink) = isopen(za.sink)
Base.isreadable(za::ZipArchiveSink) = false
Base.iswritable(za::ZipArchiveSink) = iswritable(za.sink)

"""
    bytes_written(za::ZipArchiveSink) -> UInt64

Return the number of bytes written to the archive so far.

This function avoids the ambiguity of "position" when called on an output stream
which has no well-defined starting point.

Note: in order to get an accurate count, flush any buffered but unwritten data
with `flush(za)` before calling this method.
"""
function bytes_written(za::ZipArchiveSink)
    stat = TranscodingStreams.stats(za.sink)
    offset = stat.transcoded_out % UInt64
    return offset
end