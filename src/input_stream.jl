import Base: HasEltype, IteratorEltype, IteratorSize, SizeUnknown, close, eltype, eof, iterate, read

"""
    ZipFileInputStream

A wrapper around an IO stream that includes information about an archived file. 

Use the `filestream(info, io)` method to properly construct a `ZipFileInputStream`
from an arbitrary IO object.
"""
mutable struct ZipFileInputStream{S<:IO} <: IO
    info::ZipFileInformation
    source::S
end

function filestream(info::ZipFileInformation, io::IO; validate_on_close::Bool=true)
    truncstream = TruncatedInputStream(io, info.compressed_size)
    C = info.compression_method == COMPRESSION_DEFLATE ? CodecZlib.DeflateDecompressor : TranscodingStreams.Noop
    transstream = TranscodingStream(C(), truncstream)
    crc32stream = CRC32InputStream(transstream)

    zf = ZipFileInputStream(info, crc32stream)
    if validate_on_close
        finalizer(validate, zf)
    end
    return zf
end

function filestream(f::F, info::ZipFileInformation, io::IO; validate_on_close::Bool=true) where {F <: Function}
    zipfile(info, io; validate_on_close=validate_on_close) |> f
end

"""
    validate(zf)

Validate that the contents read from an archived file match the information stored
in the header.

When called, this method will read through the remainder of the archived file
until EOF is reached.
"""
function validate(zf::ZipFileInputStream)
    # read the remainder of the file
    read(zf.source)
    if zf.source.crc32 != zf.info.crc32
        error("CRC32 check failed: expected $(zf.info.crc32), got $(zf.source.crc32)")
    end
    if zf.source.bytes_read != zf.info.compressed_size
        error("bytes read check failed: expected $(zf.info.compressed_size), got $(zf.source.bytes_read)")
    end
end

Base.read(zf::ZipFileInputStream) = read(zf.source)
Base.eof(zf::ZipFileInputStream) = eof(zf.source)

"""
    ZipArchiveInputStream

A read-only lazy streamable representation of a Zip archive.

Zip archive files are optimized for reading from the beginning of the archive
_and_ appending to the end of the archive. Because information about what files
are stored in the archive are recorded at the end of the file, a Zip archive
technically cannot be validated unless the entire file is present, making
reading a Zip archive sequentially from a stream of data technically not
standards-compliant. However, one can build the Central Directory information
while streaming the data and check validity later (if ever) for faster reading
and processing of a Zip archive.

ZipArchiveInputStream objects can also be iterated to produce read-only IO objects
(in archive order) which, when read, produce the decompressed information from the
archived file.

Create a `ZipArchiveInputStream` using the `zipstream` method.

# Examples
"""
mutable struct ZipArchiveInputStream{S<:IO}
    source::S

    validate_files::Bool
    validate_directory::Bool

    directory::Vector{ZipFileInformation}
end

function zipstream(io::IO; validate_files::Bool=true, validate_directory::Bool=false)
    zs = ZipArchiveInputStream(io, validate_files, validate_directory, ZipFileInformation[])
    if validate_directory
        finalizer(validate, zs)
    end
    return zs
end
zipstream(fname::AbstractString; kwargs...) = zipstream(open(fname, "r"); kwargs...)
zipstream(f::F, x; kwargs...) where {F<:Function} = zipstream(x; kwargs...) |> f

Base.close(zs::ZipArchiveInputStream) = close(zs.source)
Base.eof(zs::ZipArchiveInputStream) = eof(zs.source)

"""
    validate(zs)

Validate the directory in the ZipArchiveInputStream.

Consumes all the remaining data in the source.

Throws an exception if the directory at the end of the `IO` source in the
`ZipArchiveInputStream` does not match the files detected while reading the
archive. If directed to by using the `validate_files` keyword argument, will also
validate the archived files with their own headers as they are read.
"""
function validate(zs::ZipArchiveInputStream; validate_files::Bool=false)
    for f in zs
        if validate_files
            validate(f)
        end
    end
    # Guaranteed to be at the end.
    # Seek backward to and read the directory.
    _seek_to_directory_backward(zs.source)
    # Read off the directory contents and check what was found.
    ncd = 0
    for (i, lf_info) in enumerate(zs.directory)
        ncd += 1
        cd_info = read(zs.source, CentralDirectoryHeader)
        if cd_info.info != lf_info.info
            @error "Central Directory header entry $i does not match Local File header" local_file_header=lf_info.info central_directory_header=cd_info.info
            error("discrepancy detected in central directory entry $i")
        end
    end
    if ncd != length(zs.directory)
        @error "Central Directory had a different number of headers than detected in Local Files" n_local_files=length(zs.directory) n_central_directory=ncd
        error("discrepancy detected in number of central directory entries ($ncd vs $(length(zs.directory)))")
    end
end

function Base.iterate(zs::ZipArchiveInputStream, state::Int=0)
    # skip everything at the start of the archive that is not a local file header.
    readuntil(zs.source, htol(reinterpret(UInt8, [SIG_LOCAL_FILE])))
    if eof(zs.source)
        return nothing
    end
    #! FIXME: this will fail if the source is not seekable
    skip(zs.source, -sizeof(SIG_LOCAL_FILE))
    header = read(zs.source, LocalFileHeader)
    # add the local file header to the directory
    push!(zf.directory, header.info)
    zf = zipfile(header.info, zs.source; validate_on_close=zs.validate_files)
    return (zf, state+1)
end

Base.IteratorSize(::Type{ZipArchiveInputStream}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{ZipArchiveInputStream}) = Base.HasEltype()
Base.eltype(::Type{ZipArchiveInputStream}) = ZipFileInputStream