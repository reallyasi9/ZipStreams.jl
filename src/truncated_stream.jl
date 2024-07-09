# AbstractLimiter types T implement bytes_remaining(::T, ::CRC32Source)::UInt64
"""
    AbstractLimiter

An abstract type that reports a number of bytes remaining to read before EOF.

An AbstractLimiter implements the following interface:
- `bytes_remaining(::AbstractLimiter, ::IO; kwargs...)::Int`: report the number of bytes remaining to read from a given `IO` object.
- `consume!(::AbstractLimiter, ::Integer)::Int`: tell the limiter that a number of bytes has been consumed so it can update its state, returning the number of bytes consumed so far.
- `bytes_consumed(::AbstractLimiter)::Int`: report the number of bytes seen by the limiter.
"""
abstract type AbstractLimiter end

"""
    UnlimitedLimiter

A fake limiter that always reports typemax(Int) bytes remaining.
"""
mutable struct UnlimitedLimiter <: AbstractLimiter
    bytes_consumed::Int
    UnlimitedLimiter() = new(0)
end

function bytes_remaining(::UnlimitedLimiter, io::IO; kwargs...)
    if eof(io)
        return 0
    end
    return typemax(Int)
end

function consume!(limiter::UnlimitedLimiter, n::Integer)
    limiter.bytes_consumed += n
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
    byte_limit::Int
    bytes_remaining::Int
    FixedSizeLimiter(n::Integer) = new(n, n)
end

function bytes_remaining(limiter::FixedSizeLimiter, io::IO; kwargs...)
    if eof(io)
        return 0
    end
    return limiter.bytes_remaining
end

function consume!(limiter::FixedSizeLimiter, n::Integer)
    limiter.bytes_remaining = max(limiter.bytes_remaining - n, 0)
end

function bytes_consumed(limiter::FixedSizeLimiter)
    return limiter.byte_limit - limiter.bytes_remaining
end

"""
    SentinelLimiter

A limiter that signals the number of bytes until a sentinel is found.

This is useful for reading ZIP files that use a data descriptor at the end. Will report the
number of bytes in a stream before the given sentinel bytes. Also matches incomplete
sentinels found at the end of a stream.

Note that the `IO` type of the second argument of `bytes_remaining(::SentinelLimiter, ::IO)`
must support the operations `mark(::IO)` and `reset(::IO)` (i.e., it must be seekable, which
usually means it is buffered). Checking for the sentinel relies on `readbytes!(::IO, ::Int)`,
which has a default (slow) definition for generic `IO`.
"""
mutable struct SentinelLimiter{T} <: AbstractLimiter
    sentinel::Vector{T}
    failure_function::Vector{Int}
    bytes_consumed::Int
    skip::Bool
end

function SentinelLimiter(sentinel::AbstractVector{T}) where {T}
    # Implements Knuth-Morris-Pratt failure function computation
    # https://en.wikipedia.org/wiki/Knuth%E2%80%93Morris%E2%80%93Pratt_algorithm
    s = Vector{T}(sentinel)
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

    return SentinelLimiter{T}(s, t, 0, false)
end

"""
    findfirst_sentinel(sl::SentinelLimiter, io::IO)

Search `io` for the first bytes of a sentinel.

Returns the first position in `io` (as given by `position(io)`) where the first byte of the
sentinel is found. Resets the position of `io` to where it was when the method was called.

If no match is found, returns `nothing`.
"""
function findfirst_sentinel(sl::SentinelLimiter{T}, io::IO, clear_skip::Bool) where {T}
    eof(io) && return nothing
    previous_mark = -1
    if ismarked(io)
        previous_mark = io.mark
        unmark(io)
    end
    previous_skip = sl.skip

    sentinel = sl.sentinel
    failure_function = sl.failure_function

    # Implements Knuth-Morris-Pratt with extra logic to deal with the tail of the buffer
    # https://en.wikipedia.org/wiki/Knuth%E2%80%93Morris%E2%80%93Pratt_algorithm

    b_idx = mark(io)
    s_idx = firstindex(sentinel)

    @inbounds while !eof(io)
        r = read(io, T)
        if sl.skip
            sl.skip = false
            continue
        end
        if sentinel[s_idx] == r
            b_idx = position(io)
            s_idx += 1
            if s_idx == lastindex(sentinel) + 1
                # sentinel found
                reset(io)
                if previous_mark >= 0
                    io.mark = previous_mark
                end
                if !clear_skip
                    sl.skip = previous_skip
                end
                return b_idx - s_idx + 1
            end
        else
            s_idx = failure_function[s_idx]
            if s_idx <= 0
                b_idx = position(io)
                s_idx += 1
            end
        end
    end

    # sentinel not found, stream exhausted
    reset(io)
    if previous_mark >= 0
        io.mark = previous_mark
    end
    return nothing
end

function bytes_remaining(limiter::SentinelLimiter{T}, io::IO; clear_skip::Bool=true) where {T}
    pos = findfirst_sentinel(limiter, io, clear_skip)

    if isnothing(pos)
        # sentinel not found is an error
        @error "sentinel not found in stream"
        throw(EOFError())
    end
    
    # sentinel was found at pos, so everything up to pos is readable
    # note that every read is a read of T, not UInt8
    return (pos - position(io)) * sizeof(T)
end

function consume!(limiter::SentinelLimiter, n::Integer)
    limiter.bytes_consumed += n
end

function bytes_consumed(limiter::SentinelLimiter)
    return limiter.bytes_consumed
end


mutable struct TruncatedSource{L<:AbstractLimiter,S<:IO} <: IO
    limiter::L
    stream::S
    eof::Bool
end
TruncatedSource(limiter::AbstractLimiter, stream::IO) = TruncatedSource(limiter, stream, false)

function bytes_consumed(io::TruncatedSource)
    return bytes_consumed(io.limiter)
end

function Base.bytesavailable(io::TruncatedSource) 
    n = bytes_remaining(io.limiter, io.stream)
    if n == 0
        io.eof = true
        return 0
    end
    if n < 0
        return 0
    end
    return min(n, bytesavailable(io.stream))
end

function Base.read(io::TruncatedSource, ::Type{UInt8})
    if eof(io)
        throw(EOFError())
    end
    b = read(io.stream, UInt8)
    consume!(io.limiter, sizeof(b))
    return b
end

function Base.unsafe_read(io::TruncatedSource, p::Ptr{UInt8}, n::UInt)
    unsafe_read(io.stream, p, n)
    consume!(io.limiter, n)
    return nothing
end

function Base.readbytes!(io::TruncatedSource, a::AbstractArray{UInt8}, nb::Integer=length(a))
    if eof(io)
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
        consume!(io.limiter, number_to_read)
        read_so_far += number_to_read
    end
    return read_so_far
end

function Base.readavailable(io::TruncatedSource) 
    if eof(io)
        return UInt8[]
    end
    n = bytesavailable(io)
    a = read(io.stream, n)
    consume!(io.limiter, length(a))
    return a
end

function Base.eof(io::TruncatedSource)
    # in order of complexity
    if io.eof
        return true
    end
    s_eof = eof(io.stream)
    b_eof = bytes_remaining(io.limiter, io.stream; clear_skip=false) == 0
    if s_eof && !b_eof
        error("EOF in underlying stream before limiter reached limit")
    end
    io.eof = s_eof || b_eof
    return io.eof
end

function Base.skip(io::TruncatedSource, offset::Integer)
    read(io, offset) # drop the bytes on the floor
    return
end
Base.seek(::TruncatedSource, ::Integer) = error("TruncatedSource cannot seek")
Base.isreadable(io::TruncatedSource) = isreadable(io.stream)
Base.iswritable(::TruncatedSource) = false
Base.isopen(io::TruncatedSource) = isopen(io.stream)