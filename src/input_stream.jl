import Base: HasEltype, IteratorEltype, IteratorSize, SizeUnknown, close, eltype, eof, iterate, isreadable, iswritable, position, read, seek, show, skip, unsafe_read
using Logging
using Printf
using TranscodingStreams

"""
    ZipFileInputStream

A wrapper around an `IO`` stream that includes information about an archived file. 

A `ZipFileInputStream` implements `read(zf, UInt8)`, allowing all other basic read
opperations to treat the object as if it were a file. Information about the
archived file is stored in the `info` property.
"""
mutable struct ZipFileInputStream{S<:IO} <: IO
    info::ZipFileInformation
    source::S
end

function zipfile(info::ZipFileInformation, io::IO; calculate_crc32::Bool=true)
    truncstream = TruncatedInputStream(io, info.compressed_size)
    C = info.compression_method == COMPRESSION_DEFLATE ? CodecZlib.DeflateDecompressor : TranscodingStreams.Noop
    stream = TranscodingStream(C(), truncstream)
    if calculate_crc32
        stream = CRC32InputStream(stream)
    end
    return ZipFileInputStream(info, stream)
end

function zipfile(f::F, info::ZipFileInformation, io::IO; calculate_crc32::Bool=true) where {F <: Function}
    zipfile(info, io; calculate_crc32=calculate_crc32) |> f
end

"""
    validate(zf)

Validate that the contents read from an archived file match the information stored
in the header.

When called, this method will read through the remainder of the archived file
until EOF is reached.
"""
function validate(zf::ZipFileInputStream{S}) where {S <: CRC32InputStream}
    # read the remainder of the file
    read(zf)
    if zf.source.crc32 != zf.info.crc32
        error("CRC32 check failed: expected $(zf.info.crc32), got $(zf.source.crc32)")
    end
    stats = TranscodingStreams.stats(zf.source.source)
    if stats.transcoded_in != zf.info.compressed_size
        error("compressed size check failed: expected $(zf.info.compressed_size), got $(stats.transcoded_in)")
    end
    if stats.transcoded_out != zf.info.uncompressed_size
        error("uncompressed size check failed: expected $(zf.info.uncompressed_size), got $(stats.transcoded_out)")
    end
end

function validate(zf::ZipFileInputStream)
    # read the remainder of the file
    read(zf)
    stats = TranscodingStreams.stats(zf.source)
    if stats.transcoded_in != zf.info.compressed_size
        error("compressed size check failed: expected $(zf.info.compressed_size), got $(stats.transcoded_in)")
    end
    if stats.transcoded_out != zf.info.uncompressed_size
        error("uncompressed size check failed: expected $(zf.info.uncompressed_size), got $(stats.transcoded_out)")
    end
end

Base.read(zf::ZipFileInputStream, ::Type{UInt8}) = read(zf.source, UInt8)
Base.unsafe_read(zf::ZipFileInputStream, p::Ptr{UInt8}, nb::UInt64) = unsafe_read(zf.source, p, nb)
Base.eof(zf::ZipFileInputStream) = eof(zf.source)
function Base.seek(::ZipFileInputStream, ::Integer)
    error("stream cannot seek")
end
function Base.skip(zf::ZipFileInputStream, n::Integer)
    if n < 0
        error("stream cannot skip backward")
    end
    skip(zf.source, n)
    return
end
Base.isreadable(::ZipFileInputStream) = true
Base.iswritable(::ZipFileInputStream) = false

"""
    ZipArchiveInputStream

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

A `ZipArchiveInputStream` is a wapper around an `IO` object that allows the user
to extract files as they are read from the stream instead of waiting to read the
file information from the Central Directory at the end of the stream.

`ZipArchiveInputStream` objects can be iterated. Each iteration returns an IO
object that will lazily extract (and decompress) file data from the archive.

Create `ZipArchiveInputStream` objects using the [`zipstream`](@ref) function.
"""
mutable struct ZipArchiveInputStream{S<:IO} <: IO
    source::S

    store_file_info::Bool
    calculate_crc32s::Bool
    directory::Vector{ZipFileInformation}

    _bytes_read::UInt64
end

function Base.show(io::IO, za::ZipArchiveInputStream)
    # show different results depending on whether or not the file info is stored
    # and whether or not we have reached EOF on the input stream
    print(io, "Zip stream data after ", position(za), " bytes")
    if eof(za)
        print(io, " (EOF)")
    end
    if za.store_file_info
        print(io, ", number of entries")
        print(io, ": ", length(za.directory), ", ")
    end
    if za.calculate_crc32s
        print(io, ", CRC-32 checksums calculated")
    else
        print(io, ", CRC-32 checksums not calculated")
    end
    if za.store_file_info && length(za.directory) > 0
        println(io)
        total_uc = 0
        total_c = 0
        for entry in za.directory
            println(io, entry)
            total_uc += entry.uncompressed_size
            total_c += entry.compressed_size
        end
        print(io, length(za.directory), " files")
        if total_uc > 0
            @printf(io, ", %d bytes uncompressed, %d bytes compressed: %5.1f%%", total_uc, total_c, (total_uc - total_c) * 100 / total_uc)
        end
    end
    return
end

"""
    zipstream(io; <keyword arguments>)
    zipstream(f, io; <keyword arguments>)

Create a read-only lazy streamable representation of a Zip archive.

The first form returns a `ZipArchiveInputStream` wrapped around `io` that allows
the user to extract files as they are read from the stream by iterating over the
returned object. `io` can be an object that inherits from `Base.IO` (technically
only requiring `read`, `eof`, and `skip` to be defined) or an `AbstractString`
file name, which will open the file in read-only mode and wrap that `IOStream`.

The second form takes a unary function as the first argument. The constructed
`ZipArchiveInputStream` object will be passed to the function and the results of
the function will be returned to the user. This allows compatability with `do`
blocks.

# Keyword arguments
- `validate_files::Bool=true`: If `true`, validate the data in each of the
returned file objects after they go out of scope. See
[`validate(::ZipFileInputStream)`](@ref) for more information.
- `validate_directory::Bool=true`: If `true`, record information about each file
while iterating and validate the information with the Central Directory when the
`ZipArchiveInputStream` object goes out of scope. If this is `false`, no
information is recorded while streaming, improving performance at the expense of
making after-the-fact integrity checking impossible. Required to be `true` for
manual calls to [`validate(::ZipArchiveInputStream)`](@ref)

!!! warning "Reading before knowing where files end can be dangerous!"

    The Central Directory in the Zip archive is the _authoritative source_ for
    file locations, compressed and uncompressed sizes, and CRC-32 checksums. A
    Local File Header can lie about this information, leading to improper file
    extraction.  The `zipstream` method has a keyword argument
    `validate_directory` which allows the user to validate the discovered files
    against the Central Directory records when the stream is closed. It is
    **highly** recommended that users validate the file contents against the
    Central Directory before even beginning to trust the extracted files.

# Examples
```jldoctest
```
"""
function zipstream(io::IO; store_file_info::Bool=false, calculate_crc32s::Bool=false)
    # If storing file information, use a Noop stream to catch the offsets without
    # having to call position on the stream (which might not have a position!)
    if store_file_info
        stream = TranscodingStream(Noop(), io)
        zs = ZipArchiveInputStream(stream, store_file_info, calculate_crc32s, ZipFileInformation[], 0)
    else
        zs = ZipArchiveInputStream(io, store_file_info, calculate_crc32s, ZipFileInformation[], 0)
    end
    finalizer(close, zs)
    return zs
end
zipstream(fname::AbstractString; kwargs...) = zipstream(open(fname, "r"); kwargs...)
zipstream(f::F, x; kwargs...) where {F<:Function} = zipstream(x; kwargs...) |> f

open(fname::AbstractString; kwargs...) = zipstream(fname; kwargs...)
open(f::F, x; kwargs...) where {F<:Function} = zipstream(x; kwargs...) |> f

Base.eof(zs::ZipArchiveInputStream) = eof(zs.source)
Base.close(zs::ZipArchiveInputStream) = close(zs.source)

function Base.read(zs::ZipArchiveInputStream, ::Type{UInt8})
    x = read(zs.source)
    zs._bytes_read += 1
    return x
end

function Base.unsafe_read(zf::ZipArchiveInputStream, p::Ptr{UInt8}, nb::UInt64)
    unsafe_read(zf.source, p, nb)
    zs._bytes_read += nb
    return
end

Base.position(zs::ZipArchiveInputStream) = zs._bytes_read
function Base.skip(zs::ZipArchiveInputStream, n::Integer)
    if n < 0
        error("stream cannot skip backward")
    end
    skip(zs.source, n)
    zs._bytes_read += n
    return
end
function Base.seek(::ZipArchiveInputStream, ::Integer)
    error("stream cannot seek")
end

Base.isreadable(::ZipArchiveInputStream) = true
Base.iswritable(::ZipArchiveInputStream) = false

"""
    validate(zs)

Validate the files in the archive `zs` against the Central Directory at the end of
the archive.

Consumes all the remaining data in the source stream of `zs` and throws an
exception if the file information read does not match the information in the
Central Directory.

!!! warning "Requires `validate_directory`"

    Unless the archive is empty, this method is guaranteed to throw if `zs` was
    not created with `validate_directory` equal to `true`.

Throws an exception if the directory at the end of the `IO` source in the
`ZipArchiveInputStream` does not match the files detected while reading the
archive. If `zs` has the `validate_files` property set to `true`, this method will
also validate the archived files with their own headers as they are read.

See also [`validate(::ZipFileInputStream)`](@ref).
"""
function validate(zs::ZipArchiveInputStream)
    # validate remaining files
    for f in zs
        validate(f)
    end
    # Guaranteed to be after the last local header found,
    # maybe after the central directory?
    if !zs.store_file_info
        @error "Unable to validate files against Central Directory because `store_file_info` argument set to `false`"
        return
    end
    @debug "Central directory for validation" zs.directory
    # Read off the directory contents and check what was found.
    ncd = 0
    for (i, lf_info) in enumerate(zs.directory)
        @debug "Reading central directory element $i"
        ncd += 1
        cd_info = read(zs.source, CentralDirectoryHeader)
        if cd_info.info != lf_info
            @debug "central directory entry does not match local file header" i cd_info.info lf_info
            error("discrepancy detected in central directory entry $i")
        end
    end
    if ncd != length(zs.directory)
        @error "Central Directory had a different number of headers than detected in Local Files" n_local_files=length(zs.directory) n_central_directory=ncd
        error("discrepancy detected in number of central directory entries ($ncd vs $(length(zs.directory)))")
    end
end

function Base.iterate(zs::ZipArchiveInputStream, state::Int=0)
    # skip everything at the start of the archive that is not the next signature.
    while true
        readuntil(zs, htol(reinterpret(UInt8, [SIG_L])))
        if eof(zs)
            return nothing
        end
        highbytes = readle(zs, UInt16)
        if highbytes == SIG_LOCAL_FILE_H
            break
        elseif highbytes == SIG_CENTRAL_DIRECTORY_H
            return nothing
        end
    end
    
    # add the local file header to the directory
    header = read(zs, LocalFileHeader)
    if zs.store_file_info
        @debug "Adding header to central directory" header.info
        push!(zs.directory, header.info)
    end
    zf = zipfile(header.info, zs; calculate_crc32=zs.calculate_crc32s)
    return (zf, state+1)
end

Base.IteratorSize(::Type{ZipArchiveInputStream}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{ZipArchiveInputStream}) = Base.HasEltype()
Base.eltype(::Type{ZipArchiveInputStream}) = ZipFileInputStream