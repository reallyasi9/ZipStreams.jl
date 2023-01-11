"""
    CRC32Sink{<:IO}
    CRC32Source{<:IO}

Wrappers around an `IO` object that computes the CRC checksum of all data passing into
or out of it.
"""
mutable struct CRC32Sink{S<:IO} <: IO
    crc32::UInt32
    bytes_in::Int
    bytes_out::Int
    stream::S
end
CRC32Sink(io::IO) = CRC32Sink(CRC32_INIT, 0, 0, io)

mutable struct CRC32Source{S<:IO} <: IO
    crc32::UInt32
    bytes_in::Int
    bytes_out::Int
    stream::S
end
CRC32Source(io::IO) = CRC32Source(CRC32_INIT, 0, 0, io)

# optimized for CRC32.jl
function Base.write(s::CRC32Sink, a::ByteArray)
    s.crc32 = crc32(a, s.crc32)
    s.bytes_in += sizeof(a)
    bytes_out = write(s.stream, a)
    s.bytes_out += bytes_out
    return bytes_out
end

# fallbacks
function Base.unsafe_write(s::CRC32Sink, p::Ptr{UInt8}, n::UInt)
    s.crc32 = unsafe_crc32(p, n, s.crc32)
    s.bytes_in += n
    bytes_out = unsafe_write(s.stream, p, n)
    s.bytes_out += bytes_out
    return bytes_out
end

function Base.unsafe_read(s::CRC32Source, p::Ptr{UInt8}, n::UInt)
    p0 = position(s.stream)
    unsafe_read(s.stream, p, n)
    δp = position(s.stream) - p0
    s.crc32 = unsafe_crc32(p, n, s.crc32)
    s.bytes_in += δp
    s.bytes_out += n
    return nothing
end

function Base.readbytes!(s::CRC32Source, a::AbstractVector{UInt8}, nb::Integer=length(a))
    p0 = position(s.stream)
    n = readbytes!(s.stream, a, nb) % UInt64
    δp = position(s.stream) - p0
    s.crc32 = @GC.preserve a unsafe_crc32(pointer(a), n, s.crc32)
    s.bytes_in += δp
    s.bytes_out += n
    return n
end

# other IO stuff
for typ = (:CRC32Source, :CRC32Sink)
    for func = (:close, :isopen, :eof, :position, :bytesavailable)
        @eval Base.$func(s::$typ) = $func(s.stream)
    end

    @eval Base.seek(::$typ) = error("$typ cannot seek")

    @eval crc32(s::$typ) = s.crc32
    @eval bytes_in(s::$typ) = s.bytes_in
    @eval bytes_out(s::$typ) = s.bytes_out
end

Base.flush(s::CRC32Sink) = flush(s.stream)

Base.isreadable(s::CRC32Sink) = false
Base.isreadable(s::CRC32Source) = isreadable(s.stream)

Base.iswritable(s::CRC32Sink) = iswritable(s.stream)
Base.iswritable(s::CRC32Source) = false

Base.peek(s::CRC32Source) = peek(s.stream) # do not update CRC!

function Base.skip(s::CRC32Source, offset::Integer)
    read(s, offset) # drop on the floor to update CRC
    return nothing
end