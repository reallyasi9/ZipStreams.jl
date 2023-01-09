import Base: bytesavailable, eof, flush, unsafe_read

using TranscodingStreams

struct StatBlock
    crc32_out::UInt32
    bytes_out::UInt64
    bytes_in::UInt64
end
StatBlock() = StatBlock(CRC32_INIT, 0, 0)

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
    # avoid overflow of UInt64
    if stats.bytes_in >= limiter.bytes
        return Int(0)
    end
    return Int(limiter.bytes - stats.bytes_in)
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
    failure_function::Vector{Int}
end

function SentinelLimiter(sentinel::AbstractVector{UInt8})
    s = copy(sentinel)
    t = ones(Int, length(s) + 1)
    pos = firstindex(s) + 1
    cnd = firstindex(t)

    t[cnd] = 0
    @inbounds while pos <= lastindex(s)
        if s[pos] == s[cnd]
            t[pos] = t[cnd]
        else
            t[pos] = cnd
            while cnd > 0 && s[pos] != s[cnd]
                cnd = t[cnd]
            end
        end
        pos += 1
        cnd += 1
    end
    t[pos] = cnd

    return SentinelLimiter(s, t)
end

"""
    _findfirst_sentinel_head(sentinel, buffer)

Search the bytes of `buffer` for any of the first bytes of `sentinel`.

Returns the first position in `buffer` where `sentinel` is found along with the number of
matching bytes. If the tail of `buffer` is a partial match to `sentinel`, the position of
the start of the partial match will be returned along with a number of matching bytes less
than `length(sentinel)`.

If no match is found, returns `(lastindex(buffer), 0)`
"""
function _findfirst_sentinel_head(sentinel::AbstractVector{UInt8}, failure_function::AbstractVector{Int}, buffer::AbstractVector{UInt8})
    @boundscheck length(failure_function) == length(sentinel) + 1 || throw(BoundsError("failure function length must be 1 greater than sentinel length: expected $(length(sentinel) + 1), got $(length(failure_function))"))
    @boundscheck checkbounds(sentinel, filter(i -> i != 0, failure_function))
    # Implements Knuth-Morris-Pratt with extra logic to deal with the tail of the buffer
    # https://en.wikipedia.org/wiki/Knuth%E2%80%93Morris%E2%80%93Pratt_algorithm
    b_idx = firstindex(buffer)
    s_idx = firstindex(sentinel)

    @inbounds while b_idx <= lastindex(buffer)
        if sentinel[s_idx] == buffer[b_idx]
            b_idx += 1
            s_idx += 1
            if s_idx == lastindex(sentinel) + 1 || b_idx == lastindex(buffer) + 1
                # index found or head found
                return b_idx - s_idx + 1, s_idx - 1
            end
        else
            s_idx = failure_function[s_idx]
            if s_idx <= 0
                b_idx += 1
                s_idx += 1
            end
        end
    end

    return lastindex(buffer), 0
end

function bytes_remaining(limiter::SentinelLimiter, stream::TranscodingStream, stats::StatBlock)
    buffer = readavailable(stream)
    (pos, len) = _findfirst_sentinel_head(limiter.sentinel, limiter.failure_function, buffer)
    unread(stream, buffer)
    if len == 0
        # sentinel not found, so everything is available
        return length(buffer)
    end
    if pos > 1
        # read only up to the byte before the start of the sentinel
        return pos-1
    end
    # check to see if the descriptor matches the stats block
    slen = length(limiter.sentinel)
    if length(buffer) < slen + 20 # 4 CRC bytes, 16 size bytes
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
    return 0 # the sentinel was found, no bytes available to read anymore 
end


mutable struct TruncatedStream{L<:AbstractLimiter,S<:TranscodingStream} <: IO
    stats::StatBlock
    limiter::L
    stream::S
end
TruncatedStream(limiter::AbstractLimiter, stream::TranscodingStream) = TruncatedStream(StatBlock(), limiter, stream)

function update_stats!(s::TruncatedStream, δpos::Int, p::Ptr{UInt8}, n::Int)
    s.stats = StatBlock(
        crc32(p, n, s.stats.crc32_out),
        s.stats.bytes_out + n,
        s.stats.bytes_in + δpos,
    )
end

function update_stats!(s::TruncatedStream, δpos::Int, value::UInt8)
    s.stats = StatBlock(
        crc32([value], s.stats.crc32_out),
        s.stats.bytes_out + 1,
        s.stats.bytes_in + δpos,
    )
end

function signal_eof!(io::TruncatedStream)
    mode = io.stream.state.mode
    if mode == :stop || mode == :close
        return
    end
    TranscodingStreams.changemode!(io.stream, :stop)
end

function Base.bytesavailable(stream::TruncatedStream)
    if eof(stream)
        return 0
    end
    n = bytes_remaining(stream.limiter, stream.stream, stream.stats)
    if n == 0
        signal_eof!(stream)
        return 0
    end
    if n == -1
        # unable to determine based on current buffer
        # don't signal EOF, but don't claim to be able to read anything, either
        return 0 
    end
    return n
end

function Base.unsafe_read(io::TruncatedStream, p::Ptr{UInt8}, n::Int)
    if eof(io)
        throw(EOFError())
    end
    # Noop stats are a bit broken because the same buffer is used for input and output
    # Rely on position before and after instead
    pos_before = position(io.stream)
    unsafe_read(io.stream, p, n)
    pos_after = position(io.stream)
    update_stats!(io, pos_after - pos_before, p, n)
    return nothing
end

function Base.read(io::TruncatedStream, ::Type{UInt8})
    if eof(io)
        throw(EOFError())
    end
    # Noop stats are a bit broken because the same buffer is used for input and output
    # Rely on position before and after instead
    pos_before = position(io.stream)
    out = read(io.stream, UInt8)
    pos_after = position(io.stream)
    update_stats!(io, pos_after - pos_before, out)
    return out
end

Base.flush(io::TruncatedStream) = flush(io.stream)
Base.eof(io::TruncatedStream) = eof(io.stream) || bytes_remaining(io.limiter, io.stream, io.stats) == 0
function Base.skip(io::TruncatedStream, offset::Integer)
    read(io.stream, offset)
    return
end
Base.position(io::TruncatedStream) = position(io.stream)
Base.seek(::TruncatedStream) = error("TruncatedStream cannot seek")
Base.isreadable(io::TruncatedStream) = isreadable(io.stream)
Base.iswritable(::TruncatedStream) = false
Base.close(io::TruncatedStream) = close(io.stream)

# TODO: readbytes! ?
