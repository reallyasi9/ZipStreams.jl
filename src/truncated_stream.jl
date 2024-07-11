"""
    AbstractTruncatedSource <: IO

Wraps an IO stream object and lies about how much is left to read from the stream.

Objects inheriting from this abstract type pass along all IO methods to the wrapped stream
except for `bytesavailable(io)` and `eof(io)`. Inherited types need to implement:
- `source(::AbstractTruncatedSource)::IO`: return the wrapped IO stream.
- `Base.bytesavailable(::AbstractTruncatedSource)::Int`: report the number of bytes available to
    read from the stream until EOF or a buffer refill.
- `Base.eof(::AbstractTruncatedSource)::Bool`: report whether the stream cannot produce any more
    bytes.

Optional methods to implement that might be useful are:
- `Base.reseteof(::AbstractTruncatedSource)::Nothing`: reset EOF status.
- `Base.unsafe_read(::AbstractTruncatedSource, p::Ptr{UInt8}, n::UInt)::Nothing`: copy `n` bytes from the stream into memory pointed to by `p`.
"""
abstract type AbstractTruncatedSource <: IO end

"""
    source(s<:AbstractTruncatedSource) -> IO

Return the wrapped source.
"""
function source end

# unary functions
for func in (:lock, :unlock, :isopen, :close, :closewrite, :flush, :position, :seekstart, :seekend, :mark, :unmark, :reset, :ismarked)
    @eval Base.$func(s::AbstractTruncatedSource) = Base.$func(source(s))
end
# special unary functions
Base.iswritable(::AbstractTruncatedSource) = false

# function Base.readavailable(s::AbstractTruncatedSource)
#     n = bytesavailable(s)
#     v = Vector{UInt8}(undefined, n)
#     readbytes!(source(s), v, n)
#     return v
# end

# n-ary functions
Base.seek(s::AbstractTruncatedSource, n::Integer) = seek(source(s), n)
Base.unsafe_read(s::AbstractTruncatedSource, p::Ptr{UInt8}, n::UInt) = unsafe_read(source(s), p, n)

function Base.read(s::AbstractTruncatedSource, ::Type{UInt8})
    r = Ref{UInt8}()
    unsafe_read(s, r, 1)
    return r[]
end

"""
    FixedLengthSource(io, length) <: AbstractTruncatedSource

A truncated source that reads `io` up to `length` bytes.
"""
mutable struct FixedLengthSource{S<:IO} <: AbstractTruncatedSource
    source::S
    length::Int
    remaining::Int

    FixedLengthSource(io::S, length::Integer) where {S} = new{S}(io, length, length)
end

source(s::FixedLengthSource) = s.source

Base.bytesavailable(s::FixedLengthSource) = min(s.remaining, bytesavailable(source(s)))

Base.eof(s::FixedLengthSource) = eof(source(s)) || s.remaining <= 0

function Base.unsafe_read(s::FixedLengthSource, p::Ptr{UInt8}, n::UInt)
    unsafe_read(source(s), p, n)
    s.remaining -= n
    return nothing
end

"""
    SentinelizedSource(io, sentinel) <: AbstractTruncatedSource

A truncated source that reads `io` until `sentinel` is found.

Can be reset with the `reseteof()` method if the sentinel read is discovered upon further
inspection to be bogus.
"""
mutable struct SentinelizedSource{S<:IO} <: AbstractTruncatedSource
    source::S
    sentinel::Vector{UInt8}
    failure_function::Vector{Int}
    eof::Bool
    skip::Bool

    function SentinelizedSource(io::S, sentinel::AbstractVector{UInt8}) where {S<:IO}
        # Implements Knuth-Morris-Pratt failure function computation
        # https://en.wikipedia.org/wiki/Knuth%E2%80%93Morris%E2%80%93Pratt_algorithm
        s = Vector{UInt8}(sentinel)
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

        new{S}(io, s, t, false, false)
    end
end

source(s::SentinelizedSource) = s.source

function Base.bytesavailable(s::SentinelizedSource)
    if eof(s)
        # already exhausted the stream
        return 0
    end

    n = bytesavailable(source(s))
    if n < length(s.sentinel)
        # only read up until we cannot determine sentinel status: don't refill buffers
        return 0
    end

    # Implements Knuth-Morris-Pratt with extra logic to deal with the tail of the buffer
    # https://en.wikipedia.org/wiki/Knuth%E2%80%93Morris%E2%80%93Pratt_algorithm

    mark(s)
    b_idx = 0
    s_idx = firstindex(s.sentinel)

    try
        while true
            if n + s_idx - 1 <= length(s.sentinel)
                # ran out of bytes to match against the sentinel
                # can read up to the last known non-sentinel byte
                return b_idx - s_idx + 1
            end

            r = read(s, UInt8)
            n -= 1

            if s.sentinel[s_idx] == r
                # if this was a continuation from a previous EOF that was reset,
                # pretend this was not a match and reset the skip flag
                if s.skip && s_idx == firstindex(s.sentinel)
                    s.skip = false
                    s.eof = false
                    continue
                end
                s_idx += 1
                b_idx += 1
                if s_idx == lastindex(s.sentinel) + 1
                    # sentinel found
                    # can read up until the byte before the sentinel
                    s.eof = true
                    return b_idx - s_idx + 1
                end
            else
                # reset to closest matching byte found so far
                s_idx = s.failure_function[s_idx]
                if s_idx <= 0
                    # start over
                    b_idx += 1
                    s_idx += 1
                end
            end
        end
    finally
        reset(s)
    end

    throw(ErrorException("unreachable tail"))
end

function Base.eof(s::SentinelizedSource)
    if eof(source(s))
        s.eof = true
    elseif s.skip
        return false
    end
    return s.eof
end

function Base.reseteof(s::SentinelizedSource)
    Base.reseteof(source(s))
    s.skip = true
    s.eof = false
    return nothing
end

