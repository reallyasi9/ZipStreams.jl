import Base: bytesavailable, close, eof, isopen, unsafe_read, unsafe_write

const CRC32_INIT = 0x00000000

function crc32(data::Ptr{UInt8}, n::UInt, crc::UInt32=CRC32_INIT)
    return ccall((:crc32, "libz"), Culong, (Culong, Ptr{Cchar}, Cuint), crc, data, n) % UInt32
end

crc32(data::Vector{UInt8}, crc::UInt32) = GC.@preserve data crc32(pointer(data), UInt(length(data)), crc)
crc32(s::String, crc::UInt32) = crc32(Vector{UInt8}(s), crc)

"""
    CRC32Stream

An IOStream that calculates a CRC-32 checksum for read and written data.
"""
mutable struct CRC32Stream <: IO
    _io::IO
    crc32_read::UInt32
    crc32_write::UInt32

    CRC32Stream(io::IO) = new(io, CRC32_INIT, CRC32_INIT)
end

Base.bytesavailable(s::CRC32Stream) = bytesavailable(s._io)
Base.close(s::CRC32Stream) = close(s._io)
Base.eof(s::CRC32Stream) = eof(s._io)
Base.isopen(s::CRC32Stream) = isopen(s._io)

function Base.unsafe_read(s::CRC32Stream, p::Ptr{UInt8}, nb::UInt)
    unsafe_read(s._io, p, nb)
    s.crc32_read = crc32(p, nb, s.crc32_read)
    return
end

function Base.unsafe_write(s::CRC32Stream, p::Ptr{UInt8}, nb::UInt)
    unsafe_write(s._io, p, nb)
    s.crc32_write = crc32(p, nb, s.crc32_write)
    return
end

"""
    TruncatedStream

An IOStream that stops after reading a certain number of bytes.
"""
mutable struct TruncatedStream <: IO
    _io::IO
    nb::UInt64

    TruncatedStream(io::IO, nb::UInt64=typemax(UInt64)) = new(io, nb)
end

Base.bytesavailable(s::TruncatedStream) = min(bytesavailable(s._io), s.nb)
Base.close(s::TruncatedStream) = close(s._io)
Base.eof(s::TruncatedStream) = s.nb == 0 || eof(s._io)
Base.isopen(s::TruncatedStream) = isopen(s._io)

function Base.unsafe_read(s::TruncatedStream, p::Ptr{UInt8}, nb::UInt)
    unsafe_read(s._io, p, nb)
    # NOTE: unsafe means unsafe!
    s.nb -= nb
    return
end
Base.unsafe_write(s::TruncatedStream, p::Ptr{UInt8}, nb::UInt) = unsafe_write(s._io, p, nb)

"""
    ZipStream

A read-only lazy streamable representation of a Zip archive.

Zip archive files are optimized for reading from the beginning of the archive
_and_ appending to the end of the archive. Because information about what files
are stored in the archive are recorded at the end of the file, a Zip archive
technically cannot be validated unless the entire file is present, making
reading a Zip archive sequentially from a stream of data technically not
standards-compliant. However, one can build the Central Directory information
while streaming the data and check validity later (if ever) for faster reading
and processing of a Zip archive.

ZipStream objects are IOStream objects, allowing you to read data from the
archive byte-by-byte. Because this is usually not useful, ZipStream objects
can also be iterated to produce IO-like ZipFile objects (in archive order)
and can be addressed with Filesystem-like methods to access particular files.

# Examples
"""
mutable struct ZipStream
end