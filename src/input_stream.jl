using TranscodingStreams
using CodecZlib

"""
    ZipFileSource

A wrapper around an `IO` stream that includes information about an archived file. 

A `ZipFileSource` implements `read(zf, UInt8)`, allowing all other basic read
opperations to treat the object as if it were a file. Information about the
archived file is stored in the `info` property.
"""
struct ZipFileSource <: IO
    info::Ref{ZipFileInformation}
    source::CRC32Source
end

# Expected size of the entire file, header and data descriptor included, in bytes
function Base.sizeof(zf::ZipFileSource)
    i = zf.info[]
    extra = !i.descriptor_follows ? 0 : i.zip64 ? 24 : 16
    return sizeof(i) + i.compressed_size + extra
end

# TODO: make data descriptor files a little prettier than 0/0 bytes expected
function Base.show(io::IO, zf::ZipFileSource)
    i = zf.info[]
    fname = i.name
    csize = i.compressed_size
    usize = i.uncompressed_size
    cread = bytes_in(zf)
    uread = bytes_out(zf)

    size_string = human_readable_bytes(uread, usize)
    if i.compression_method != COMPRESSION_STORE
        size_string *= " ($(human_readable_bytes(cread, csize)) compressed)"
    end
    print(io, "ZipFileSource(<$fname> $size_string consumed)")
    return
end

function zipfilesource(info::Ref{ZipFileInformation}, io::IO)
    if info[].descriptor_follows
        if info[].compressed_size != 0
            @warn "Data descriptor signalled in local file header, but size information present as well: data descriptor will be used, but extracted data may be corrupt" info.compressed_size maxlog=3
        else
            @warn "Data descriptor signalled in local file header: extracted data may corrupt or truncated" maxlog=3
        end
        trunc_source = SentinelizedSource(io, htol(bytearray(SIG_DATA_DESCRIPTOR)))
    else
        trunc_source = FixedLengthSource(io, info[].compressed_size)
    end

    if info[].compression_method == COMPRESSION_DEFLATE
        source = DeflateDecompressorStream(trunc_source; stop_on_end=true) # the truncator will signal :end to the stream
    elseif info[].compression_method == COMPRESSION_STORE
        source = NoopStream(trunc_source)
    else
        error("unsupported compression method $(info[].compression_method)")
    end

    crcstream = CRC32Source(source)

    return ZipFileSource(info, crcstream)
end

zipfilesource(info::ZipFileInformation, io::IO) = zipfilesource(Ref(info), io)

function zipfilesource(f::F, info::ZipFileInformation, io::IO) where {F <: Function}
    zs = zipfilesource(info, io)
    return f(zs)
end

"""
    file_info(zipfile)

Return a ZipFileInformation object describing the file.

See: [ZipFileInformation](@ref) for details.
"""
file_info(z::ZipFileSource) = z.info[]

"""
    validate(zf::ZipFileSource)

Validate that the contents read from an archived file match the information stored
in the Local File Header and return the data read.

If the contents of the file do not match the information in the Local File Header, the
method will throw an error. The method checks that the compressed and uncompressed file
sizes match what is in the header, and that the CRC-32 of the uncompressed data matches what
is reported in the header.

This method will return the remainder of the raw file data that has not yet been read from
the archive as a `Vector{UInt8}`.
"""
function validate(zf::ZipFileSource)
    # read the remainder of the file
    data = read(zf)
    if !eof(zf)
        throw("expected EOF not reached")
    end
    # FIXME The limiter checks if the Data Descriptor's compressed size is valid for what
    # has been read, but the uncompressed size cannot (yet) be checked on compressed files.

    i = zf.info[]
    if i.descriptor_follows
        # If we are at EOF and we have a data descriptor, we have guaranteed that everything
        # in the data descriptor checks out.
        # Replace the data in the file info so it checks out with the central dictionary
        T = i.zip64 ? UInt64 : UInt32
        (crc, c_bytes, u_bytes, _) = read_data_descriptor(T, zf)
        zf.info[] = ZipFileInformation(
            i.compression_method,
            u_bytes,
            c_bytes,
            i.last_modified,
            crc,
            i.extra_field_size,
            i.name,
            i.descriptor_follows,
            i.utf8,
            i.zip64,
        )
        @debug "validation succeeded"
        return data
    end

    badcrc = zf.source.crc32 != i.crc32
    badcom = bytes_in(zf) != i.compressed_size
    badunc = bytes_out(zf) != i.uncompressed_size

    if badcom
        @error "Compressed size check failed: expected $(i.compressed_size), got $(bytes_in(zf))"
    end
    if badunc
        @error "Uncompressed size check failed: expected $(i.uncompressed_size), got $(bytes_out(zf))"
    end
    if badcrc
        @error "CRC-32 check failed: expected $(string(i.crc32; base=16)), got $(string(zf.source.crc32; base=16))"
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
    return x
end

function Base.unsafe_read(zf::ZipFileSource, p::Ptr{UInt8}, nb::UInt) 
    unsafe_read(zf.source, p, nb)
    return nothing
end

function Base.readavailable(zf::ZipFileSource) 
    x = readavailable(zf.source)
    return x
end

function Base.readbytes!(zf::ZipFileSource, a::AbstractVector{UInt8}, nb=length(a))
    n = readbytes!(zf.source, a, nb)
    return n
end

function Base.eof(zf::ZipFileSource)
    # stream chain is CRC<-Transcoder<-Truncated<-(Raw from ZipArchiveSource)
    crc_stream = zf.source
    e = eof(crc_stream)
    if !zf.info[].descriptor_follows
        # just return what the fixed size limiter tells us
        return e
    end
    # no false negatives with the sentinel
    if !e
        return false
    end

    # check if the sentinel was correct
    double_check = double_check_eof(zf, crc_stream.crc32, bytes_in(zf), bytes_out(zf))
    if !double_check
        Base.reseteof(crc_stream.stream.stream)
        return false
    end
    return true
end

function double_check_eof(zf::ZipFileSource, crc::UInt32, cbytes::Integer, ubytes::Integer)
    T = zf.info[].zip64 ? UInt64 : UInt32
    (dd_crc, dd_cbytes, dd_ubytes, dd_ok) = read_data_descriptor(T, zf)
    return dd_ok && crc == dd_crc && cbytes == dd_cbytes && ubytes == dd_ubytes
end

function read_data_descriptor(::Type{T}, zf::ZipFileSource) where {T <: Unsigned}
    # stream chain is CRC<-Transcoder<-Truncated<-(Raw from ZipArchiveSource)
    raw_stream = source(zf.source.stream.stream) # .stream.stream.stream.stream...
    mark(raw_stream)
    try
        # skip the header
        skip(raw_stream, 4)
        # read three values in a row
        return readle(raw_stream, UInt32), readle(raw_stream, T), readle(raw_stream, T), true
    catch e
        if isa(e, EOFError)
            return UInt32(0), zero(T), zero(T), false
        else
            throw(e)
        end
    finally
        reset(raw_stream)
    end
end

function Base.seek(::ZipFileSource, ::Integer)
    error("stream cannot seek")
end

function Base.skip(zf::ZipFileSource, n::Integer)
    if n < 0
        error("stream cannot skip backward")
    end
    skip(zf.source, n) # consistent with not being able to seek backward
    return
end

Base.isreadable(zf::ZipFileSource) = isreadable(zf.source)
Base.iswritable(::ZipFileSource) = false
Base.isopen(zf::ZipFileSource) = isopen(zf.source)
Base.bytesavailable(zf::ZipFileSource) = bytesavailable(zf.source)
Base.close(::ZipFileSource) = nothing # Do not close the source!
Base.position(zf::ZipFileSource) = position(zf.source)

function bytes_in(zf::ZipFileSource)
    stats = TranscodingStreams.stats(zf.source.stream)
    return stats.transcoded_in
end

function bytes_out(zf::ZipFileSource)
    stats = TranscodingStreams.stats(zf.source.stream)
    return stats.transcoded_out
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
    source::NoopStream{S}
    directory::Vector{Ref{ZipFileInformation}}
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
    zs = ZipArchiveSource(NoopStream(io), Ref{ZipFileInformation}[], UInt64[], false)
    return zs
end
function zipsource(io::NoopStream) 
    zs = ZipArchiveSource(io, ZipFileInformation[], UInt64[], false)
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

for func in (:eof, :isopen, :bytesavailable, :close, :isreadable)
    @eval Base.$func(s::ZipArchiveSource) = Base.$func(s.source)
end

Base.read(zs::ZipArchiveSource, ::Type{UInt8}) = read(zs.source, UInt8)
Base.unsafe_read(zs::ZipArchiveSource, p::Ptr{UInt8}, nb::UInt64) = unsafe_read(zs.source, p, nb)
Base.readbytes!(zs::ZipArchiveSource, b::AbstractVector{UInt8}, nb=length(b)) = readbytes!(zs.source, b, nb)

Base.position(zs::ZipArchiveSource) = UInt64(position(zs.source))
bytes_in(zs::ZipArchiveSource) = position(zs)

function Base.skip(zs::ZipArchiveSource, n::Integer)
    if n < 0
        error("stream cannot skip backward")
    end
    # read and drop on the floor to update position properly
    read(zs.source, n)
    return
end

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
    # Read off the directory contents and check what was found.
    ncd = 0
    for (i, lf_info_ref) in enumerate(zs.directory)
        ncd += 1
        cd_info = read(zs.source, CentralDirectoryHeader)
        # read is complete, so size information should be filled in
        if !is_consistent(cd_info.info, lf_info_ref; check_sizes=true)
            error("discrepancy detected in central directory entry $i: expected $(lf_info_ref[]), got $(cd_info.info)")
        end
        if cd_info.offset != zs.offsets[i]
            error("discrepancy detected in central directory offset $i: expected $(zs.offsets[i]), got $(cd_info.offset)")
        end
        # If this isn't the end of the file, skip the signature bytes
        if !eof(zs.source)
            skip(zs.source, sizeof(SIG_CENTRAL_DIRECTORY))
        end
    end
    if ncd != length(zs.directory)
        error("discrepancy detected in number of central directory entries: expected $ncd, got $(length(zs.directory))")
    end
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
    header_ref = Ref(header.info)
    push!(zs.directory, header_ref)
    push!(zs.offsets, offset)

    # if this is a directory, move on to the next file
    if isdir(header.info)
        return iterate(zs, state)
    end

    zf = zipfilesource(header_ref, zs.source)
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