using TranscodingStreams

"""
    CRC32Stream

An wrapper around an `IO` object that computes the CRC checksum of all data passing into
or out of it.

Note: The CRC-32 checksum is calculated independently for read and write operations.
"""
mutable struct CRC32Stream <: IO
    crc32_read::UInt32
    crc32_write::UInt32
    bytes_read::Int
    bytes_written::Int
    stream::IO
end
CRC32Stream(io::IO) = CRC32Stream(CRC32_INIT, CRC32_INIT, 0, 0, io)

# optimized for CRC32.jl
function Base.write(s::CRC32Stream, a::ByteArray)
    s.crc32_write = crc32(a, s.crc32_write)
    s.bytes_written += sizeof(a)
    return write(s.stream, a)
end

# fallbacks
function Base.unsafe_write(s::CRC32Stream, p::Ptr{UInt8}, n::UInt)
    s.crc32_write = unsafe_crc32(p, n, s.crc32_write)
    s.bytes_written += n
    return unsafe_write(s.stream, p, n)
end

function Base.unsafe_read(s::CRC32Stream, p::Ptr{UInt8}, nb::UInt)
    unsafe_read(s.stream, p, nb)
    s.crc32_read = unsafe_crc32(p, nb, s.crc32_read)
    s.bytes_read += nb
    return nothing
end

function Base.readbytes!(s::CRC32Stream, a::AbstractVector{UInt8}, nb::Integer=length(a))
    n = readbytes!(s.stream, a, nb) % UInt64
    s.crc32_read = @GC.preserve a unsafe_crc32(pointer(a), n, s.crc32_read)
    s.bytes_read += n
    return n
end

# necessary for stopping the stream if the stream is an EndToken
Base.write(s::CRC32Stream, t::TranscodingStreams.EndToken) = write(s.sink, t)

# other IO stuff
Base.close(s::CRC32Stream) = close(s.stream)
Base.flush(s::CRC32Stream) = flush(s.stream)
Base.isopen(s::CRC32Stream) = isopen(s.stream)
Base.isreadable(s::CRC32Stream) = isreadable(s.stream)
Base.isreadonly(s::CRC32Stream) = isreadonly(s.stream)
Base.iswritable(s::CRC32Stream) = iswritable(s.stream)
Base.peek(s::CRC32Stream) = peek(s.stream) # do not update CRC!
Base.position(s::CRC32Stream) = s.bytes_read # NOTE: we keep track of this
Base.seek(::CRC32Stream, ::Integer) = error("stream cannot seek")
function Base.skip(s::CRC32Stream, offset::Integer)
    read(s, offset) # drop on the floor
    return nothing
end
Base.eof(s::CRC32Stream) = eof(s.stream)

crc32_read(s::CRC32Stream) = s.crc32_read
crc32_write(s::CRC32Stream) = s.crc32_write
bytes_read(s::CRC32Stream) = s.bytes_read
bytes_written(s::CRC32Stream) = s.bytes_written