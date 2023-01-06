import TranscodingStreams: expectedsize, minoutsize, initialize, finalize, startproc, process

using TranscodingStreams

struct StatBlock
    bytes_in::UInt64
    bytes_out::UInt64
    crc32_out::UInt32
end

# AbstractLimiter types T implement bytes_remaining(::T, in::Memory, stats::StatBlock)
abstract type AbstractLimiter end

"""
    FixedSizeLimiter

A limiter that counts the number of bytes availabe to read.

Useful for reading ZIP files that tell you in the header how many bytes to read.
"""
struct FixedSizeLimiter <: AbstractLimiter
    bytes::UInt64
end

function bytes_remaining(limiter::FixedSizeLimiter, in::TranscodingStreams.Memory, stats::StatBlock)
    return min(stats.bytes_in - limiter.bytes, length(in))
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


function bytes_remaining(limiter::SentinelLimiter, in::TranscodingStreams.Memory, stats::StatBlock)
    buffer = unsafe_wrap(Vector{UInt8}, in.ptr, length(in); own=false)
    (pos, found) = _findfirst_sentinel_head(limiter.sentinel, buffer)
    if !found
        return length(in)
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

mutable struct ZipStatCodec{L<:AbstractLimiter,C<:TranscodingStreams.Codec} <: TranscodingStreams.Codec
    stats::StatBlock
    limiter::L
    codec::C
end
ZipStatCodec(limiter, codec) = ZipStatCodec(StatBlock(0,0,CRC32_INIT), limiter, codec)

function TranscodingStreams.startproc(::ZipStatCodec, mode::Symbol, error::TranscodingStreams.Error)
    if mode != :read
        error[] = ErrorException("codec is read-only")
        return :error
    end
    return :ok
end

function TranscodingStreams.process(codec::ZipStatCodec, input::TranscodingStreams.Memory, output::TranscodingStreams.Memory, error::TranscodingStreams.Error)
    n = bytes_remaining(codec.limiter, input, codec.stats)
    
    if n < 0
        # more data requested
        return (0,0,:ok)
    end

    if min(length(input), n) == 0
        return (0,0,:end)
    end

    # limit to number of bytes remaining
    new_input = TranscodingStreams.Memory(input.ptr, n)
    (i, o, status) = process(codec.codec, new_input, output, error)
    if status != :error
        codec.stats = StatBlock(
            codec.stats.bytes_in + i,
            codec.stats.bytes_out + o,
            crc32(output.ptr, o, codec.stats.crc32_out)
        )
    end

    return i, o, status
end

# needed to allow processing of Noop like a regular codec
function TranscodingStreams.process(::Noop, input::TranscodingStreams.Memory, ::TranscodingStreams.Memory, ::TranscodingStreams.Error)
    n = length(input)
    status = n == 0 ? :end : :ok
    @info "noop processing" n status
    return n, n, status
end