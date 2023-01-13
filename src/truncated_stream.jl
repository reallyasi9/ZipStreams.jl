# AbstractLimiter types T implement bytes_remaining(::T, ::CRC32Source)::UInt64
"""
    AbstractLimiter

An abstract type that reports a number of bytes remaining to read before EOF.

An AbstractLimiter implements the following interface:
- `bytes_remaining(::T, ::IO)::Int`: report the number of bytes remaining to read from a given `IO` object.
- `consume!(::T, ::AbstractVector{UInt8})`: report to the limiter that the provided array of bytes has been consumed so it can update its state.
- `bytes_consumed(::T)::UInt64`: report the number of bytes seen by the limiter.
"""
abstract type AbstractLimiter end

"""
    UnlimitedLimiter

A fake limiter that always reports typemax(Int) bytes remaining.
"""
mutable struct UnlimitedLimiter <: AbstractLimiter
    bytes_consumed::UInt64
    UnlimitedLimiter() = new(0)
end

function bytes_remaining(::UnlimitedLimiter, ::IO)
    return typemax(Int)
end

function consume!(limiter::UnlimitedLimiter, a::AbstractVector{UInt8})
    limiter.bytes_consumed += length(a)
    return nothing
end

function bytes_consumed(limiter::UnlimitedLimiter)
    return limiter.bytes_consumed
end

"""
    FixedSizeLimiter

A limiter that counts up to a fixed number of bytes to read.

Useful for reading ZIP files that tell you in the header how many bytes to read.
"""
mutable struct FixedSizeLimiter <: AbstractLimiter
    byte_limit::UInt64
    bytes_remaining::Int
    FixedSizeLimiter(n::Integer) = new(n, n)
end

function bytes_remaining(limiter::FixedSizeLimiter, ::IO)
    return limiter.bytes_remaining
end

function consume!(limiter::FixedSizeLimiter, a::AbstractVector{UInt8})
    limiter.bytes_remaining = max(limiter.bytes_remaining - length(a), 0)
    return nothing
end

function bytes_consumed(limiter::FixedSizeLimiter)
    return (limiter.byte_limit - limiter.bytes_remaining) % UInt64
end

"""
    SentinelLimiter

A limiter that signals the number of bytes until a sentinel is found.

This is useful for reading ZIP files that use a data descriptor at the end. Will first
report a number of bytes before a sentinel so that data can be read up to the sentinel, but
if the first bytes are the start of a sentinel block, will check if the sentinel is valid
based on calculated statistics about the stream.

Note that the `IO` type of the second argument of `bytes_remaining(::SentinelLimiter, ::IO)`
must support the operations `mark(::IO)` and `reset(::IO)` (i.e., it must be seekable, which
usually means it is buffered). Checking for the sentinel relies on `readbytes!(::IO, ::Int)`,
which has a default (slow) definition for generic `IO`.
"""
mutable struct SentinelLimiter <: AbstractLimiter
    sentinel::Vector{UInt8}
    failure_function::Vector{Int}
    crc32::UInt32
    bytes_consumed::UInt64
    # TODO: deal with uncompressed bytes somehow?
end

function SentinelLimiter(sentinel::AbstractVector{UInt8})
    # Implements Knuth-Morris-Pratt failure function computation
    # https://en.wikipedia.org/wiki/Knuth%E2%80%93Morris%E2%80%93Pratt_algorithm
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

    return SentinelLimiter(s, t, CRC32_INIT, 0)
end

"""
    findfirst_sentinel_head(sentinel, failure_function, a)

Search `a` for any of the first bytes of `sentinel`.

Returns the first position in `a` where `sentinel` is found along with the number of
matching bytes. If the tail of `a` is a partial match to `sentinel`, the position of
the start of the partial match will be returned along with a number of matching bytes less
than `length(sentinel)`.

If no match is found, returns `(length(a), 0)`
"""
function findfirst_sentinel_head(sentinel::Vector{UInt8}, failure_function::Vector{Int}, a::Vector{UInt8})
    @boundscheck length(failure_function) == length(sentinel) + 1 || throw(BoundsError("failure function length must be 1 greater than sentinel length: expected $(length(sentinel) + 1), got $(length(failure_function))"))
    @boundscheck checkbounds(sentinel, filter(i -> i != 0, failure_function))
    # Implements Knuth-Morris-Pratt with extra logic to deal with the tail of the buffer
    # https://en.wikipedia.org/wiki/Knuth%E2%80%93Morris%E2%80%93Pratt_algorithm
    b_idx = firstindex(a)
    s_idx = firstindex(sentinel)

    @inbounds while b_idx <= lastindex(a)
        if sentinel[s_idx] == a[b_idx]
            b_idx += 1
            s_idx += 1
            if s_idx == lastindex(sentinel) + 1 || b_idx == lastindex(a) + 1
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

    return lastindex(a), 0
end

function peekbytes!(io::IO, a::Vector{UInt8})
    mark(io)
    n = 0
    try
        n = readbytes!(io, a)
    finally
        reset(io)
    end
    return n
end

function bytes_remaining(limiter::SentinelLimiter, io::IO)
    slen = length(limiter.sentinel)
    buflen = max(slen, bytesavailable(io))
    buffer = Vector{UInt8}(undef, buflen)
    nb = peekbytes!(io, buffer)
    resize!(buffer, nb)
    (pos, len) = findfirst_sentinel_head(limiter.sentinel, limiter.failure_function, buffer)

    if len == 0
        # sentinel not found, so everything is available
        return nb
    end
    if pos > 1
        # read only up to the byte before the start of the sentinel
        return pos-1
    end
    # the sentinel is at position 1
    # check to see if the descriptor matches the stats block
    if nb < slen + 20 # 4 CRC bytes, 16 size bytes
        return -1 # the input was too short to make a determination, so ask for more data
    end
    if bytesle2int(UInt32, buffer[slen+1:slen+4]) != limiter.crc32
        return 1 # the sentinel was fake, so we can consume 1 byte and move on
    end
    # TODO: figure out how to handle compressed bytes read from a stream...
    # if bytesle2int(UInt32, buffer[slen+5:slen+12]) != bytes_out(stream)
    #     return 1
    # end
    if bytesle2int(UInt32, buffer[slen+13:slen+20]) != limiter.bytes_consumed
        return 1
    end

    return 0 # the sentinel was found, no bytes available to read anymore
end

function consume!(limiter::SentinelLimiter, a::AbstractVector{UInt8})
    limiter.bytes_consumed += length(a)
    limiter.crc32 = crc32(a, limiter.crc32)
    return nothing
end

function bytes_consumed(limiter::SentinelLimiter)
    return limiter.bytes_consumed
end


mutable struct TruncatedSource{L<:AbstractLimiter,S<:IO} <: IO
    limiter::L
    stream::S
    _eof::Bool
end
TruncatedSource(limiter::AbstractLimiter, stream::IO) = TruncatedSource(limiter, stream, false)

function bytes_consumed(io::TruncatedSource)
    return bytes_consumed(io.limiter)
end

function Base.bytesavailable(io::TruncatedSource)
    if io._eof
        return 0
    end
    n = bytes_remaining(io.limiter, io.stream)
    if n == 0
        io._eof = true
        return 0
    end
    if n == -1
        # unable to determine based on current buffer
        # don't signal EOF, but don't claim to be able to read anything, either
        return 0 
    end
    return min(n, bytesavailable(io.stream))
end

function Base.read(io::TruncatedSource, ::Type{UInt8})
    br = bytes_remaining(io.limiter, io.stream)
    if eof(io) || br == 0
        io._eof = true
        throw(EOFError())
    end
    b = read(io.stream, 1) # read to array
    consume!(io.limiter, b)
    return first(b)
end

function Base.unsafe_read(io::TruncatedSource, p::Ptr{UInt8}, n::Int)
    br = bytesavailable(io)
    nr = min(br, n)
    unsafe_read(io.stream, p, nr)
    consume!(io.limiter, unsafe_wrap(Vector{UInt8}, p, nr; own=false))
    if nr < n
        io._eof = true
        throw(EOFError())
    end
    return nothing
end

function Base.readbytes!(io::TruncatedSource, a::AbstractArray{UInt8}, nb::Integer=length(a))
    if eof(io) || bytes_remaining(io.limiter, io.stream) == 0
        io._eof = true
        throw(EOFError())
    end
    read_so_far = 0
    while read_so_far < nb && !eof(io)
        number_to_read = min(bytesavailable(io), nb - read_so_far)
        if number_to_read == 0
            break
        end
        while length(a) < read_so_far + number_to_read
            resize!(a, max(read_so_far + number_to_read, min(length(a) * 2, nb)))
        end
        @GC.preserve a unsafe_read(io.stream, pointer(a, read_so_far+1), number_to_read)
        consume!(io.limiter, a[read_so_far+1:read_so_far+number_to_read])
        read_so_far += number_to_read
    end
    return read_so_far
end

function Base.readavailable(io::TruncatedSource) 
    if eof(io)
        io._eof = true
        return UInt8[]
    end
    n = bytesavailable(io)
    a = read(io.stream, n)
    consume!(io.limiter, a)
    return a
end

Base.eof(io::TruncatedSource) = io._eof || eof(io.stream)
function Base.skip(io::TruncatedSource, offset::Integer)
    read(io, offset) # drop the bytes on the floor
    return
end
Base.seek(::TruncatedSource) = error("TruncatedSource cannot seek")
Base.isreadable(io::TruncatedSource) = isreadable(io.stream)
Base.iswritable(::TruncatedSource) = false