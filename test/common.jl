using CodecZlib

struct ForwardReadOnlyIO{S <: IO} <: IO
    io::S
end
Base.read(f::ForwardReadOnlyIO, ::Type{UInt8}) = read(f.io, UInt8)
# Base.unsafe_read(f::ForwardReadOnlyIO, p::Ptr{UInt8}, n::UInt) = unsafe_read(f.io, p, n)
Base.seek(f::ForwardReadOnlyIO, n::Int) = n < 0 ? error("backward seeking forbidden") : seek(f.io, n)
Base.close(f::ForwardReadOnlyIO) = close(f.io)
Base.isopen(f::ForwardReadOnlyIO) = isopen(f.io)
Base.eof(f::ForwardReadOnlyIO) = eof(f.io)
Base.bytesavailable(f::ForwardReadOnlyIO) = bytesavailable(f.io)

struct ForwardWriteOnlyIO{S <: IO} <: IO
    io::S
end
Base.unsafe_write(f::ForwardWriteOnlyIO, p::Ptr{UInt8}, n::UInt) = unsafe_write(f.io, p, n)
Base.close(f::ForwardWriteOnlyIO) = close(f.io)
Base.isopen(f::ForwardWriteOnlyIO) = isopen(f.io)
# Base.eof(f::ForwardWriteOnlyIO) = eof(f.io)

# All test files have the same content
const FILE_CONTENT = "Hello, Julia!\n"
const DEFLATED_FILE_CONTENT = transcode(DeflateCompressor, FILE_CONTENT)
