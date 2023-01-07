import Base: bytesavailable, eof, flush, unsafe_read

using TranscodingStreams

struct StatBlock
    bytes_in::UInt64
    bytes_out::UInt64
    crc32_out::UInt32
end

# AbstractLimiter types T implement bytes_remaining(::T, stream::TranscodingStream, stats::StatBlock)
abstract type AbstractLimiter end

"""
    FixedSizeLimiter

A limiter that counts the number of bytes availabe to read.

Useful for reading ZIP files that tell you in the header how many bytes to read.
"""
struct FixedSizeLimiter <: AbstractLimiter
    bytes::UInt64
end

function bytes_remaining(limiter::FixedSizeLimiter, ::TranscodingStream, stats::StatBlock)
    return min(limiter.bytes - stats.bytes_in, 0)
end

"""
    SentinelLimiter

A limiter that signals the number of bytes until a sentinel is found.

This is useful for reading ZIP files that use a data descriptor at the end. Will first
report a number of bytes before a sentinel so that data can be read up to the sentinel, but
if the first bytes are the start of a sentinel block, will check if the sentinel is valid
based on the stats given.
"""
struct SentinelLimiter <: AbstractLimiter
    sentinel::Vector{UInt8}
end

"""
    _findfirst_sentinel_head(sentinel, buffer, n)

Search the bytes of `buffer` for any of the first bytes of `sentinel`.

If all of `sentinel` is found starting at `pos`, return `(pos,true)`, else if some
of the head of `sentinel` is found starting at `pos`, return `(pos,false)`. If none of
the head of `sentinel` is found, return `(lastindex(buffer),false)`.
"""
function _findfirst_sentinel_head(sentinel::AbstractVector{UInt8}, buffer::AbstractVector{UInt8})
    @debug "finding first sentinel" sentinel buffer 
    found = findfirst(sentinel, buffer)
    if !isnothing(found)
        return (first(found), true)
    end
    # slide the sentinel along the last bytes of the buffer
    # NOTE: this is not optimized, and runs in length(sentinel)^2 time
    if length(buffer) == 1
        return (1, buffer[1] == sentinel[1])
    end
    if length(buffer) < length(sentinel)
        first_bbyte = firstindex(buffer) + 1
        last_sbyte = length(buffer) - 1
    else
        first_bbyte = lastindex(buffer) - length(sentinel) + 1
        last_sbyte = lastindex(sentinel) - 1
    end
    for i in first_bbyte:lastindex(buffer)
        for j in last_sbyte:firstindex(sentinel)
            if buffer[i:end] == sentinel[1:j]
                return (i, false)
            end
        end
    end
    return (lastindex(buffer), false)
end

function bytes_remaining(limiter::SentinelLimiter, stream::TranscodingStream, stats::StatBlock)
    buffer = readavailable(stream)
    (pos, found) = _findfirst_sentinel_head(limiter.sentinel, buffer)
    unread(stream, buffer)
    if !found
        return length(input)
    end
    if pos > 1
        return pos-1
    end
    # check to see if the descriptor matches the stats block
    slen = length(limiter.sentinel)
    if length(in) < slen + 20 # 4 CRC bytes, 16 size bytes
        return -1 # the input was too short to make a determination, so ask for more data
    end
    if bytesle2int(UInt32, buffer[slen+1:slen+4]) != stats.crc32_out
        return 1 # the sentinel was fake, so we can consume 1 byte and move on
    end
    if bytesle2int(UInt64, buffer[slen+5:slen+12]) != stats.bytes_out
        return 1
    end
    if bytesle2int(UInt64, buffer[slen+13:slen+20]) != stats.bytes_in
        return 1
    end
    return 0 # it's a good one!
end


mutable struct TruncatedStream{L<:AbstractLimiter,S<:TranscodingStream} <: IO
    stats::StatBlock
    limiter::L
    stream::S
end
TrancatedStream(limiter, stream) = TrancatedStream(StatBlock(0,0,CRC32_INIT), limiter, stream)

function update_stats!(io::TruncatedStream, p::Ptr{UInt8}, n::Int)
    stat = TruncatedStreams.stats(io.stream)
    io.stats = StatBlock(
        stat.in, stat.out, crc32(p, n, stat.crc32_out)
    )
end

function update_stats!(io::TruncatedStream, value::UInt8)
    stat = TruncatedStreams.stats(io.stream)
    io.stats = StatBlock(
        stat.in, stat.out, crc32([value], stat.crc32_out)
    )
end

Base.bytesavailable(stream::TruncatedStream) = bytes_remaining(stream.limiter, stream.stream, stream.stats)

function Base.unsafe_read(io::TruncatedStream, p::Ptr{UInt8}, n::Int)
    unsafe_read(io.stream, p, n)
    update_stats!(io, p, n)
    return nothing
end

function Base.read(io::TruncatedStream, ::Type{UInt8})
    out = read(io.stream, UInt8)
    update_stats!(io, out)
    return out
end

Base.flush(io::TruncatedStream) = flush(io.stream)
Base.eof(io::TruncatedStream) = eof(io.stream) || bytesavailable(io) == 0
function Base.skip(io::TruncatedStream, offset::Integer)
    read(io.stream, offset)
    return
end
Base.position(io::TruncatedStream) = io.stats.bytes_in
Base.seek(::TruncatedStream) = error("TruncatedStream cannot seek")
Base.isreadable(io::TruncatedStream) = isreadable(io.stream)
Base.iswritable(::TruncatedStream) = false
Base.close(io::TruncatedStream) = close(io.stream)