import Base: HasEltype, IteratorEltype, IteratorSize, SizeUnknown, bytesavailable, close, eltype, eof, iterate, isopen, isreadable, iswritable, position, read, seek, show, skip, unsafe_read
using Logging
using Printf
using TranscodingStreams

"""
    ZipFileSource

A wrapper around an `IO` stream that includes information about an archived file. 

A `ZipFileSource` implements `read(zf, UInt8)`, allowing all other basic read
opperations to treat the object as if it were a file. Information about the
archived file is stored in the `info` property.
"""
mutable struct ZipFileSource{S<:IO} <: IO
    info::ZipFileInformation
    source::S

    _crc32::UInt32
end

function Base.show(io::IO, zf::ZipFileSource)
    fname = zf.info.name
    csize = zf.info.compressed_size
    usize = zf.info.uncompressed_size
    cread = bytes_read(zf)
    uread = uncompressed_bytes_read(zf)
    size_string = human_readable_bytes(uread, usize)
    if zf.info.compression_method != COMPRESSION_STORE
        size_string *= " ($(human_readable_bytes(cread, csize)) compressed)"
    end
    print(io, "ZipFileSource(<$fname> $size_string consumed)")
    return
end

function zipfilesource(info::ZipFileInformation, io::IO)
    if info.descriptor_follows
        if info.compressed_size == 0
            error("files using data descriptors cannot be streamed")
        else
            @warn "Data descriptor found in local file header, but size information present: extracted data may be corrupt" info.compressed_size
        end
    end
    truncstream = TruncatedInputStream(io, info.compressed_size)
    C = info.compression_method == COMPRESSION_DEFLATE ? CodecZlib.DeflateDecompressor : TranscodingStreams.Noop
    stream = TranscodingStream(C(), truncstream)
    return ZipFileSource(info, stream, CRC32_INIT)
end

function zipfilesource(f::F, info::ZipFileInformation, io::IO) where {F <: Function}
    zs = zipfilesource(info, io)
    return f(zs)
end

"""
    validate(zf::ZipFileSource)

Validate that the contents read from an archived file match the information stored
in the Local File Header and return the data read.

If the contents of the file do not match the information in the Local File Header, the
method will throw an error. The method checks that the compressed and uncompressed file
sizes match what is in the header, and that the CRC-32 of the compressed data matches what
is reported in the header.

This method will return the remainder of the raw file data that has not yet been read from
the archive as a `Vector{UInt8}`.
"""
function validate(zf::ZipFileSource)
    # read the remainder of the file
    data = read(zf)
    stats = TranscodingStreams.stats(zf.source)
    badcom = stats.transcoded_in != zf.info.compressed_size
    badunc = stats.transcoded_out != zf.info.uncompressed_size
    badcrc = zf._crc32 != zf.info.crc32

    if badcom
        @error "Compressed size check failed: expected $(zf.info.compressed_size), got $(stats.transcoded_in)"
    end
    if badunc
        @error "Uncompressed size check failed: expected $(zf.info.uncompressed_size), got $(stats.transcoded_out)"
    end
    if badcrc
        @error "CRC-32 check failed: expected $(zf.info.crc32), got $(zf._crc32)"
    end
    if badcom || badunc || badcrc
        error("validation failed")
    else
        @debug "validation succeeded"
    end
    return data
end

function Base.read(zf::ZipFileSource, ::Type{UInt8})
    x = read(zf.source, UInt8)
    zf._crc32 = crc32([x], zf._crc32)
    return x
end

function Base.unsafe_read(zf::ZipFileSource, p::Ptr{UInt8}, nb::UInt64) 
    n = unsafe_read(zf.source, p, nb)
    zf._crc32 = crc32(p, n, zf._crc32)
    return n
end

Base.eof(zf::ZipFileSource) = eof(zf.source)
function Base.seek(::ZipFileSource, ::Integer)
    error("stream cannot seek")
end
function Base.skip(zf::ZipFileSource, n::Integer)
    if n < 0
        error("stream cannot skip backward")
    end
    skip(zf.source, n)
    return
end
Base.isreadable(zf::ZipFileSource) = isreadable(zf.source)
Base.iswritable(::ZipFileSource) = false
Base.isopen(zf::ZipFileSource) = isopen(zf.source)
Base.bytesavailable(zf::ZipFileSource) = bytesavailable(zf.source)
Base.close(::ZipFileSource) = nothing # closing doesn't do anything

function bytes_read(zf::ZipFileSource)
    stats = TranscodingStreams.stats(zf.source)
    return stats.in % UInt64
end

function uncompressed_bytes_read(zf::ZipFileSource)
    stats = TranscodingStreams.stats(zf.source)
    return stats.out % UInt64
end

"""
    ZipArchiveSource

A read-only lazy streamable representation of a Zip archive.

The authoritative record of files present in a Zip archive is stored in the
Central Directory at the end of the archive. This allows for easy appending of new
files to the archive by overwriting the Central Directory and adding a new
Central Directory with the updated contents afterward. It also allows for easy
deletion of files from the old archive by overwriting the Central Directory with
the updated contents and relying on compliant Zip archive extraction programs
ignoring the actual bytes in the file and only trusting the new Central Directory.

Unfortunately, this choice makes reading the contents of a Zip archive
sub-optimal, especially over streaming IO interfaces like networks, where seeking
to the end of the file requires reading all of the file's contents first.

However, this package chooses not to be a compliant Zip archive reader. By
ignoring the Central Directory, one can begin extracting data from a Zip archive
immediately upon reading the first Local File Header record it sees in the stream,
greatly reducing latency to first read on large files, and also reducing the
amount of data necessary to cache on disk or in memory.

A `ZipArchiveSource` is a wapper around an `IO` object that allows the user
to extract files as they are read from the stream instead of waiting to read the
file information from the Central Directory at the end of the stream.

`ZipArchiveSource` objects can be iterated. Each iteration returns an IO
object that will lazily extract (and decompress) file data from the archive.

Information about each file in the archive is stored in the `directory` property of the
struct as the file is read from the archive.

Create `ZipArchiveSource` objects using the [`zipsource`](@ref) function.
"""
mutable struct ZipArchiveSource{S<:IO} <: IO
    source::S
    directory::Vector{ZipFileInformation}
    offsets::Vector{UInt64}

    # make sure we do not iterate into the central directory
    _no_more_files::Bool
end

function Base.show(io::IO, za::ZipArchiveSource)
    nbytes = position(za)
    entries = length(za.directory)
    byte_string = human_readable_bytes(nbytes)
    entries_string = "entr" * (entries == 1 ? "y" : "ies")
    eof_string = eof(za) ? ", EOF" : ""
    print(io, "ZipArchiveSource($byte_string from $entries $entries_string consumed$eof_string)")
    return
end

"""
    zipsource(io)
    zipsource(f, io)

Create a read-only lazy streamable representation of a Zip archive.

The first form returns a `ZipArchiveSource` wrapped around `io` that allows
the user to extract files as they are read from the stream by iterating over the
returned object. `io` can be an object that inherits from `Base.IO` (technically
only requiring `read`, `eof`, `isopen`, `close`, and `bytesavailable` to be
defined) or an `AbstractString` file name, which will open the file in read-only
mode and wrap that `IOStream`.

The second form takes a unary function as the first argument. The constructed
`ZipArchiveSource` object will be passed to the function and the results of
the function will be returned to the user. This allows compatability with `do`
blocks. If `io` is an `AbstractString` file name, the file will be automatically
closed when the block exits. If `io` is a `Base.IO` object as described above, it
will _not_ be closed when the block exits, allowing the caller to have control over
the lifetime of the argument.

!!! warning "Reading before knowing where files end can be dangerous!"

    The Central Directory in the Zip archive is the _authoritative source_ for
    file locations, compressed and uncompressed sizes, and CRC-32 checksums. A
    Local File Header can lie about this information, leading to improper file
    extraction.  We **highly** recommend that users validate the file contents
    against the Central Directory using the `validate` method before beginning
    to trust the extracted files from uncontrolled sources.

"""
function zipsource(io::IO)
    stream = TranscodingStreams.NoopStream(io)
    zs = ZipArchiveSource(stream, ZipFileInformation[], UInt64[], false)
    return zs
end
zipsource(fname::AbstractString; kwargs...) = zipsource(Base.open(fname, "r"); kwargs...)
function zipsource(f::F, x::IO; kwargs...) where {F<:Function}
    zs = zipsource(x; kwargs...)
    return f(zs)
end
function zipsource(f::F, x::AbstractString; kwargs...) where {F<:Function}
    zs = zipsource(x; kwargs...)
    val = f(zs)
    close(zs)
    return val
end

Base.eof(zs::ZipArchiveSource) = eof(zs.source)
Base.isopen(zs::ZipArchiveSource) = isopen(zs.source)
Base.bytesavailable(zs::ZipArchiveSource) = bytesavailable(zs.source)
Base.close(zs::ZipArchiveSource) = close(zs.source)

Base.read(zs::ZipArchiveSource, ::Type{UInt8}) = read(zs.source, UInt8)
Base.unsafe_read(zs::ZipArchiveSource, p::Ptr{UInt8}, nb::UInt64) = unsafe_read(zs.source, p, nb)
function Base.position(zs::ZipArchiveSource)
    stat = TranscodingStreams.stats(zs.source)
    return stat.in
end
function bytes_read(zs::ZipArchiveSource)
    stat = TranscodingStreams.stats(zs.source)
    return stat.in
end
function uncompressed_bytes_read(zs::ZipArchiveSource)
    stat = TranscodingStreams.stats(zs.source)
    return stat.out
end

function Base.skip(zs::ZipArchiveSource, n::Integer)
    if n < 0
        error("stream cannot skip backward")
    end
    # read and drop on the floor to update position properly
    read(zs.source, n)
    return
end
function Base.seek(::ZipArchiveSource, ::Integer)
    error("stream cannot seek")
end

Base.isreadable(za::ZipArchiveSource) = isreadable(za.source)
Base.iswritable(::ZipArchiveSource) = false

"""
    validate(source::ZipArchiveSource)

Validate the files in the archive `source` against the Central Directory at the end of
the archive and return all data read as a vector of byte vectors (one per file).

This method consumes _all_ the remaining data in the source stream of `source` and throws an
exception if the file information read does not match the information in the Central
Directory. Files that have already been consumed prior to calling this method will still
be validated, even if their contents are not returned.

See also [`validate(::ZipFileSource)`](@ref).
"""
function validate(zs::ZipArchiveSource)
    # validate remaining files
    filedata = Vector{Vector{UInt8}}()
    for file in zs
        push!(filedata, validate(file))
    end

    # Guaranteed to be after the last local header found,
    # maybe after the central directory?

    @debug "Central directory for validation" zs.directory
    # Read off the directory contents and check what was found.
    ncd = 0
    for (i, lf_info) in enumerate(zs.directory)
        @debug "Reading central directory element $i"
        ncd += 1
        cd_info = read(zs.source, CentralDirectoryHeader)
        if cd_info.info != lf_info
            @error "central directory entry does not match local file header" i cd_info.info lf_info
            error("discrepancy detected in central directory entry $i")
        end
        if cd_info.offset != zs.offsets[i]
            @error "central directory offset does not match local file offset" i cd_info.offset zs.offsets[i]
            error("discrepancy detected in central directory offset $i")
        end
        # If this isn't the end of the file, skip the next 4 signature bytes
        if !eof(zs.source)
            skip(zs.source, 4)
        end
    end
    if ncd != length(zs.directory)
        @error "Central Directory had a different number of headers than detected in Local Files" n_local_files=length(zs.directory) n_central_directory=ncd
        error("discrepancy detected in number of central directory entries ($ncd vs $(length(zs.directory)))")
    end
    @debug "Zip archive Central Directory valid"
    # TODO: validate EOCD record(s)
    # Until then, just read to EOF
    read(zs)
    return filedata
end
"""
    iterate(zs::ZipArchiveSource)

Iterate through files stored in an archive.

Files in archive are iterated in archive order. Directories (files that have zero size and
have names ending `'/'`) are skipped.
"""
function Base.iterate(zs::ZipArchiveSource, state::Int=0)
    if zs._no_more_files
        # nothing else to read (already saw the central directory)
        return nothing
    end
    # skip everything at the start of the archive that is not the next signature.
    sentinel = htol(reinterpret(UInt8, [SIG_L]))
    while true
        readuntil(zs, sentinel)
        if eof(zs)
            zs._no_more_files = true
            return nothing
        end
        highbytes = readle(zs, UInt16)
        if highbytes == SIG_LOCAL_FILE_H
            break
        elseif highbytes == SIG_CENTRAL_DIRECTORY_H
            zs._no_more_files = true
            return nothing
        end
    end
    # get the offset of the header (minus 4 bytes to cover the signature)
    offset = (position(zs) - 4) % UInt64

    # add the local file header to the directory
    header = read(zs, LocalFileHeader)
    @debug "Read local file header" header.info offset
    push!(zs.directory, header.info)
    push!(zs.offsets, offset)

    # if this is a directory, move on to the next file
    if isdir(header.info)
        return iterate(zs, state)
    end

    zf = zipfilesource(header.info, zs)
    return (zf, state+1)
end

"""
    next_file(archive) => Union{IO, Nothing}

Read the next file in the archive and return a readable `IO` object or `nothing`.

This is the same as calling `first(iterate(archive))`.
"""
function next_file(archive::ZipArchiveSource)
    f = iterate(archive)
    if isnothing(f)
        return f
    end
    return first(f)
end

Base.IteratorSize(::Type{ZipArchiveSource}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{ZipArchiveSource}) = Base.HasEltype()
Base.eltype(::Type{ZipArchiveSource}) = ZipFileSource