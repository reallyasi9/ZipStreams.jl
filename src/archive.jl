import Base: close, iterate, IteratorSize, IteratorEltype, eltype, SizeUnknown, HasEltype

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

# Examples
"""
mutable struct ZipArchiveInputStream{S<:IO}
    source::S

    validate_files::Bool
end

function stream(fname::AbstractString; validate_files::Bool=true)
    io = open(fname, "r")
    zs = ZipArchiveInputStream(io, validate_files)
    finalizer(x -> close(x.source), zs)
    return zs
end

function stream(io::IO; validate_files::Bool=true)
    return ZipArchiveInputStream(io, validate_files)
end

function stream(f::F, args...; kwargs...) where {F<:Function}
    return stream(args...; kwargs...) |> f
end

Base.close(zs::ZipArchiveInputStream) = close(zs.source)

function Base.iterate(zs::ZipArchiveInputStream, state::Int=0)
    # skip everything at the start of the archive that is not a local file header.
    readuntil(zs.source, htol(reinterpret(UInt8, [SIG_LOCAL_FILE])))
    if eof(zs.source)
        return nothing
    end
    # FIXME: this will fail if the source is not seekable
    skip(zs.source, -sizeof(SIG_LOCAL_FILE))
    header = read(zs.source, LocalFileHeader)
    zf = zipfile(header.info, zs.source; validate_on_close=zs.validate_files)
    return (zf, state+1)
end

Base.IteratorSize(::Type{ZipArchiveInputStream}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{ZipArchiveInputStream}) = Base.HasEltype()
Base.eltype(::Type{ZipArchiveInputStream}) = ZipFileInputStream

"""
    ZipArchive

A lazy, readable, and somewhat writable representation of a Zip archive.

Zip archive files are optimized for reading from the beginning of the archive
_and_ appending to the end of the archive. Because information about what files
are stored in the archive are recorded at the end of the file, a Zip archive
technically cannot be validated unless the entire file is present, making
reading a Zip archive sequentially from a stream of data technically not
standards-compliant. However, one can build the Central Directory information
while streaming the data and check validity later (if ever) for faster reading
and processing of a Zip archive.

ZipArchive objects are IO objects, allowing you to read data from the
archive byte-by-byte. Because this is usually not useful, ZipArchiveInputStream
objects can also be iterated to produce IO-like ZipFile objects (in archive order)
and can be addressed with Filesystem-like methods to access particular files.

# Examples
"""
mutable struct ZipArchiveInputStream{S<:IO}
    source::S

    validate_files::Bool
end
