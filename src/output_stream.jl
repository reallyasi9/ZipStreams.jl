using TranscodingStreams
using CodecZlib
using Dates
using Printf

# to allow circular references
abstract type AbstractZipFileSink <: IO end

"""
    ZipArchiveSink

A struct for appending to Zip archives.

Zip archives are optimized for appending to the end of the archive. This struct
is used in tandem with library functions to keep track of what is appended to a
Zip archive so that a proper Central Directory can be written at the end.

Users should not call the `ZipArchiveSink` constructor: instead, use the
[`zipsink`](@ref) method to create a new streaming archive.
"""
mutable struct ZipArchiveSink{S<:AbstractZipFileSink,R<:IO} <: IO
    sink::R
    directory::Vector{CentralDirectoryHeader}

    utf8::Bool
    comment::String

    _bytes_written::UInt64
    _folders_created::Set{String}
    _open_file::Ref{S}
    _is_closed::Bool
end

function Base.show(io::IO, za::ZipArchiveSink)
    nbytes = bytes_out(za)
    entries = length(za.directory)
    byte_string = "byte" * (nbytes == 1 ? "" : "s")
    entries_string = "entr" * (nbytes == 1 ? "y" : "ies")
    eof_string = isopen(za) ? "" : ", closed"
    print(io, "ZipArchiveSink(<$nbytes $byte_string, $entries $entries_string written$eof_string>)")
    return
end

"""
    ZipFileSink{S}([arguments])

A struct representing an open streamable file in a `ZipArchiveSink`.

This struct is an `IO` object, so it inherits `write()` and `unsafe_write()`
methods from `IO`. You cannot read from this type, nor can you seek, skip, or
read the file's position. It functions in this way to allow writing to write-only
streams (like HTTP output).

The type `S` represents the `BufferedStream` type associated with the
(potentially compressed) stream that writes the file information. The raw
`ZipArchiveSink` where this object writes associated file metadata is also referenced
by the object, which means the `ZipArchiveSink` should never be closed before an opened
`ZipFileSink` goes out of scope.

You can only have one `ZipFileSink` open per `ZipArchiveSink`.
Attempts to open a second file in the same archive will issue a warning and
automatically close the previous file before opening the new file.

You should not call the struct constructor directly: instead, use
`open(archive, filename)`.
"""
mutable struct ZipFileSink{S<:CRC32Sink,R<:ZipArchiveSink} <: AbstractZipFileSink
    sink::S
    info::ZipFileInformation
    comment::String
    offset::UInt64

    # for writing data to the parent archive on close
    _raw_sink::R
    # don't close twice
    _closed::Bool
end

function Base.show(io::IO, zf::ZipFileSink)
    info = file_info(zf)
    fname = info.name
    compression = compression_name(info.compression_method)
    csize = bytes_out(zf)
    if info.compression_method == compression_code(:store)
        size_string = human_readable_bytes(csize)
    else
        usize = bytes_in(zf)
        size_string = @sprintf("%s, %s compressed (%0.2f%%)", human_readable_bytes(usize), human_readable_bytes(csize), csize/usize)
    end
    eof_string = isopen(zf) ? "" : ", closed"
    print(io, "ZipFileSink(<$fname> $compression $size_string written$eof_string)")
    return
end

"""
    file_info(zipfile)

Return a ZipFileInformation object describing the file.

See: [ZipFileInformation](@ref) for details.
"""
file_info(zf::ZipFileSink) = zf.info

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
    zipfile::ZipFileSink,
    )
    if !isopen(zipfile)
        @debug "File already closed"
        return
    end
    flush(zipfile)
    crc = crc32(zipfile.sink)
    c_size = bytes_in(zipfile)
    uc_size = bytes_out(zipfile)
    fi = file_info(zipfile)
    # FIXME: Not atomic!
    # NOTE: not standard per se, but more common than not to use a signature here.
    if fi.descriptor_follows
        writele(zipfile._raw_sink, SIG_DATA_DESCRIPTOR)
        writele(zipfile._raw_sink, crc)
        # Force Zip64 no matter the actual sizes
        writele(zipfile._raw_sink, c_size)
        writele(zipfile._raw_sink, uc_size)
    else
        if crc != fi.crc32
            error("file data written to archive does not match local header data: expected CRC-32 $(fi.crc32), got $crc")
        elseif c_size != fi.compressed_size
            error("file data written to archive does not match local header data: expected compressed size $(fi.compressed_size), got $c_size")
        elseif uc_size != fi.uncompressed_size
            error("file data written to archive does not match local header data: expected uncompressed size $(fi.uncompressed_size), got $uc_size")
        end
    end

    # Only force Zip64 in the Central Directory if necessary
    zip64 = zipfile.offset >= typemax(UInt32) || c_size >= typemax(UInt32) || uc_size >= typemax(UInt32)
    extra = zip64 ? 0 : 20
    directory_info = ZipFileInformation(
        file_info(zipfile).compression_method,
        uc_size,
        c_size,
        now(),
        crc,
        extra,
        file_info(zipfile).name,
        true,
        file_info(zipfile).utf8,
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

    # DO NOT CLOSE THE TRANSCODING STREAM!
    # Just let the garbage collector collect it later.

    return
end

function Base.unsafe_write(zf::ZipFileSink, p::Ptr{UInt8}, n::UInt)
    if !isopen(zf)
        throw(EOFError())
    end
    return unsafe_write(zf.sink, p, n)
end

function Base.flush(zf::ZipFileSink{CRC32Sink{S}}) where {S <: TranscodingStream}
    write(zf.sink.stream, TranscodingStreams.TOKEN_END)
    flush(zf.sink.stream)
end
Base.flush(zf::ZipFileSink) = flush(zf.sink)
Base.isopen(zf::ZipFileSink) = !zf._closed && isopen(zf.sink)
Base.isreadable(zf::ZipFileSink) = false
Base.iswritable(zf::ZipFileSink) = !zf._closed && iswritable(zf.sink)

"""
    bytes_out(zf::ZipFileSink) -> UInt64

Return the number of possibly compressed bytes written to the file so far.

This function avoids the ambiguity of "position" when called on an output stream
which has no well-defined starting point.

Note: in order to get an accurate count, flush any buffered but unwritten data
with `flush(zf)` before calling this method.
"""
function bytes_out(zf::ZipFileSink)
    return bytes_out(zf.sink)
end

"""
    bytes_in(zf::ZipFileSink) -> UInt64

Return the number of uncompressed bytes written to the file so far.

This function avoids the ambiguity of "position" when called on an output stream
which has no well-defined starting point.

Note: in order to get an accurate count, flush any buffered but unwritten data
with `flush(zf)` before calling this method.
"""
function bytes_in(zf::ZipFileSink)
    return bytes_in(zf.sink)
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
    z = ZipArchiveSink(
        sink,
        directory,
        utf8,
        comment,
        UInt64(0),
        Set{String}(),
        Ref{ZipStreams.ZipFileSink}(),
        false,
    )
    return z
end

function zipsink(f::F, sink::IO; kwargs...) where {F<:Function}
    zs = zipsink(sink; kwargs...)
    val = f(zs)
    close(zs; close_sink=false)
    return val
end

function zipsink(f::F, fname::AbstractString; kwargs...) where {F<:Function}
    zs = zipsink(fname; kwargs...)
    val = f(zs)
    close(zs; close_sink=true)
    return val
end

"""
    close(s::ZipArchiveSink; close_sink::Bool=true)

Close the archive sink, optionally closing the underlying IO object as well.
"""
function Base.close(archive::ZipArchiveSink; close_sink::Bool=true)
    if archive._is_closed
        return
    end
    # close the potentially open file
    if isassigned(archive._open_file)
        close(archive._open_file[])
    end
    # write the Central Directory headers
    startpos = bytes_out(archive)
    write_directory(archive.sink, archive.directory; startpos=startpos, comment=archive.comment, utf8=archive.utf8)
    # sync writes
    flush(archive)
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
        0,
        p * ZIP_PATH_DELIMITER,
        false,
        ziparchive.utf8,
        false,
    )
    # get the offset before writing anything
    flush(ziparchive)
    offset = bytes_out(ziparchive) % UInt64
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

Returns the number of bytes written to the archive when creating the entire path.
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

function Base.unsafe_write(za::ZipArchiveSink, x::Ptr{UInt8}, n::UInt)
    bytes_out = unsafe_write(za.sink, x, n)
    za._bytes_written += bytes_out
    return bytes_out
end


"""
    open(sink, fname; [keyword arguments]) -> IO

Create a file within a Zip archive and return a handle for writing.

# Keyword arguments
- `compression::Union{UInt16,Symbol} = :deflate`: Can be one of `:deflate`, `:store`, or the associated codes defined by the Zip archive standard (`0x0008` or `0x0000`, respectively). Determines how the data is compressed when writing to the archive.
- `level::Integer = $(CodecZlib.Z_DEFAULT_COMPRESSION)`: zlib compression level for `:deflate` compression method, higher values corresponding to better compression and slower compression speed (valid values [-1..9] with -1 corresponding to the default level of 6, ignored if `compression == :store`).
- `utf8::Bool = true`: If `true`, the file name and comment will be written to the archive metadata encoded in UTF-8 strings, and a flag will be set in the metadata to instruct decompression programs to read these strings as such. If `false`, the default IBM437 encoding will be used. This does not affect the file data itself.
- `comment::AbstractString = ""`: Comment metadata to add to the archive about the file. This does not affect the file data itself.
- `make_path::Bool = false`: If `true`, any directories in `fname` will be created first. If `false` and any directory in the path does not exist, an exception will be thrown.

!!! warning "Duplicate file names"

    The Zip archive specification does not clearly define what to do if multiple
    files in the Zip archive share the same name. This method will allow the user
    to create files with the same name in a single Zip archive, but other software
    may not behave as expected when reading the archive.
"""
function Base.open(
    archive::ZipArchiveSink,
    fname::AbstractString;
    compression::Union{Symbol,UInt16} = :deflate,
    level::Integer = CodecZlib.Z_DEFAULT_COMPRESSION,
    utf8::Bool = true,
    comment::AbstractString = "",
    make_path::Bool = false,
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
    offset = bytes_out(archive) % UInt64
    use_descriptor = true
    zip64 = true # always use Zip64 if size is unknown
    info = ZipFileInformation(
        ccode,
        0,
        0,
        now(),
        CRC32_INIT,
        20%UInt16, # always using ZIP64
        fname,
        use_descriptor,
        utf8,
        zip64,
    )
    local_file_header = LocalFileHeader(info)
    write(archive, local_file_header)

    # 2. set up compression stream
    if ccode == COMPRESSION_STORE
        sink = NoopStream(archive)
    elseif ccode == COMPRESSION_DEFLATE
        sink = DeflateCompressorStream(archive; level=level)
    else
        # How did I end up here?
        error("undefined compression type $compression")
    end
    filesink = CRC32Sink(sink)

    # 3. create file object
    zipfile = ZipFileSink(
        filesink,
        info,
        comment,
        offset,
        archive,
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

!!! note "Memory requirements"

    This method reads `data` into a buffer before writing it to the archive. Both `data` and
    the buffered (potentially compressed) copy must be able to fit into memory
    simultaneously.
"""
function write_file(
    archive::ZipArchiveSink,
    fname::AbstractString,
    data;
    compression::Union{Symbol,UInt16} = :deflate,
    utf8::Bool = true,
    comment::AbstractString = "",
    make_path::Bool = false,
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

    # 1. write the raw data to a buffer
    ccode = compression_code(compression)
    if ccode == COMPRESSION_STORE
        cdata = data
    elseif ccode == COMPRESSION_DEFLATE
        cdata = transcode(DeflateCompressor, data)
    else
        # How did I end up here?
        error("undefined compression type $compression")
    end

    # 2. write local header to parent
    crc = crc32(data)
    ubytes = sizeof(data) % UInt64
    cbytes = sizeof(cdata) % UInt64

    # get the offset before the local header is written
    flush(archive)
    offset = bytes_out(archive)
    use_descriptor = false
    zip64 = offset >= typemax(UInt32) || ubytes >= typemax(UInt32) || cbytes >= typemax(UInt32)
    extra = zip64 ? 20 : 0

    info = ZipFileInformation(
        ccode,
        ubytes,
        cbytes,
        now(),
        crc,
        extra,
        fname,
        use_descriptor,
        utf8,
        zip64,
    )
    local_file_header = LocalFileHeader(info)
    write(archive, local_file_header)

    # 3. write the data
    n_written = write(archive, cdata)

    # 4. Add the entry to the directory
    is_dir = false
    cd_header = CentralDirectoryHeader(info, offset, comment, is_dir)
    push!(archive.directory, cd_header)

    return n_written
end

Base.flush(za::ZipArchiveSink) = flush(za.sink)
Base.isopen(za::ZipArchiveSink) = isopen(za.sink)
Base.isreadable(za::ZipArchiveSink) = false
Base.iswritable(za::ZipArchiveSink) = iswritable(za.sink)

"""
    bytes_out(za::ZipArchiveSink) -> UInt64

Return the number of bytes written to the archive so far.

This function avoids the ambiguity of "position" when called on an output stream
which has no well-defined starting point.

Note: in order to get an accurate count, flush any buffered but unwritten data
with `flush(za)` before calling this method.
"""
function bytes_out(za::ZipArchiveSink)
    return za._bytes_written
end