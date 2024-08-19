using TranscodingStreams
using CRC32: crc32, unsafe_crc32, ByteArray

const CRC32_INIT = UInt32(0)

"""
    CRC32Sink{<:IO}
    CRC32Source{<:IO}

Wrappers around an `IO` object that computes the CRC checksum of all data passing into
or out of it.
"""
mutable struct CRC32Sink{S<:IO} <: IO
    crc32::UInt32
    bytes_seen::Int
    stream::S
end
CRC32Sink(io::IO) = CRC32Sink(CRC32_INIT, 0, io)

mutable struct CRC32Source{S<:IO} <: IO
    crc32::UInt32
    bytes_seen::Int
    stream::S

    mark::Int
    marked_crc32::UInt32
    marked_bytes_seen::Int
end
CRC32Source(io::IO) = CRC32Source(CRC32_INIT, 0, io, -1, CRC32_INIT, 0)

# optimized for CRC32.jl
function Base.write(s::CRC32Sink, a::ByteArray)
    s.crc32 = crc32(a, s.crc32)
    bytes_out = write(s.stream, a)
    s.bytes_seen += bytes_out
    return bytes_out
end

# fallbacks
function Base.unsafe_write(s::CRC32Sink, p::Ptr{UInt8}, n::UInt)
    s.crc32 = unsafe_crc32(p, n, s.crc32)
    bytes_out = unsafe_write(s.stream, p, n)
    s.bytes_seen += bytes_out
    return bytes_out
end

function Base.read(s::CRC32Source, ::Type{UInt8})
    a = Vector{UInt8}(undef, 1)
    readbytes!(s.stream, a, 1)
    s.crc32 = @GC.preserve a unsafe_crc32(pointer(a), UInt(1), s.crc32)
    s.bytes_seen += 1
    return first(a)
end

function Base.unsafe_read(s::CRC32Source, p::Ptr{UInt8}, n::UInt)
    unsafe_read(s.stream, p, n)
    s.crc32 = unsafe_crc32(p, n, s.crc32)
    s.bytes_seen += n
    return nothing
end

function Base.readbytes!(s::CRC32Source, a::AbstractVector{UInt8}, nb::Integer=length(a))
    n = readbytes!(s.stream, a, nb) % UInt64
    s.crc32 = @GC.preserve a unsafe_crc32(pointer(a), n, s.crc32)
    s.bytes_seen += n
    return n
end

Base.readavailable(s::CRC32Source) = Base.read(s)

# emulate TranscodingStreams.stats
for typ = (:CRC32Source, :CRC32Sink)
    # default to using the number of bytes seen
    @eval function stats(s::$typ)
        return TranscodingStreams.Stats(s.bytes_seen, s.bytes_seen, s.bytes_seen, s.bytes_seen)
    end

    # actually use the stats from the stream if we are using a TranscodingStream
    @eval function stats(s::$typ{S}) where {S <: TranscodingStream}
        return TranscodingStreams.stats(s.stream)
    end
end

# other IO stuff
for typ = (:CRC32Source, :CRC32Sink)
    for func in (:close, :isopen, :eof, :position, :bytesavailable)
        @eval Base.$func(s::$typ) = Base.$func(s.stream)
    end

    @eval Base.seek(::$typ) = error("$typ cannot seek")

    @eval ZipStreams.crc32(s::$typ) = s.crc32
    @eval bytes_seen(s::$typ) = s.bytes_seen
    @eval bytes_in(s::$typ) = stats(s).transcoded_out # note: reversed from codec's meaning
    @eval bytes_out(s::$typ) = stats(s).transcoded_in # note: reversed from codec's meaning
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

function Base.mark(s::CRC32Source)
    s.marked_crc32 = s.crc32
    s.marked_bytes_seen = s.bytes_seen
    s.mark = mark(s.stream)
end

function Base.unmark(s::CRC32Source)
    !ismarked(s) && return false
    unmark(s.stream)
    s.mark = -1
    return true
end

function Base.reset(s::CRC32Source)
    ismarked(s) || throw(ArgumentError("CRC32Source not marked"))
    m = reset(s.stream)
    s.mark = -1
    s.bytes_seen = s.marked_bytes_seen
    s.crc32 = s.marked_crc32
    return m
end
