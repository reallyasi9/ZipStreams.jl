using TranscodingStreams

# AbstractLimiter types T implement bytes_remaining(::T, ::CRC32Source)::UInt64
abstract type AbstractLimiter end

"""
    UnlimitedLimiter

A fake limiter that returns infinite bytes remaining.
"""
struct UnlimitedLimiter <: AbstractLimiter end

function bytes_remaining(::UnlimitedLimiter, ::CRC32Source)
    return typemax(UInt64)
end

"""
    FixedSizeLimiter

A limiter that counts the number of bytes availabe to read.

Useful for reading ZIP files that tell you in the header how many bytes to read.
"""
struct FixedSizeLimiter <: AbstractLimiter
    bytes::UInt64
end

function bytes_remaining(limiter::FixedSizeLimiter, s::CRC32Source)
    return limiter.bytes - bytes_in(s)
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

    return SentinelLimiter(s, t)
end

"""
    unsafe_findfirst_sentinel_head(sentinel, failure_function, ptr, nb)

Search the first `nb` bytes starting at `ptr` for any of the first bytes of `sentinel`.

Returns the first position after `ptr` where `sentinel` is found along with the number of
matching bytes. If the tail of the data pointed to by `ptr` is a partial match to `sentinel`, the position of
the start of the partial match will be returned along with a number of matching bytes less
than `length(sentinel)`.

If no match is found, returns `(nb, 0)`
"""
function unsafe_findfirst_sentinel_head(sentinel::AbstractVector{UInt8}, failure_function::AbstractVector{Int}, ptr::Ptr{UInt8}, nb::Int)
    @boundscheck length(failure_function) == length(sentinel) + 1 || throw(BoundsError("failure function length must be 1 greater than sentinel length: expected $(length(sentinel) + 1), got $(length(failure_function))"))
    @boundscheck checkbounds(sentinel, filter(i -> i != 0, failure_function))
    # Implements Knuth-Morris-Pratt with extra logic to deal with the tail of the buffer
    # https://en.wikipedia.org/wiki/Knuth%E2%80%93Morris%E2%80%93Pratt_algorithm
    b_idx = 1
    s_idx = firstindex(sentinel)

    @inbounds while b_idx <= nb
        if sentinel[s_idx] == unsafe_load(ptr, b_idx)
            b_idx += 1
            s_idx += 1
            if s_idx == lastindex(sentinel) + 1 || b_idx == nb + 1
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

    return nb, 0
end

function bytes_remaining(limiter::SentinelLimiter, stream::CRC32Source{S}) where {S <: TranscodingStream}
    buffer = stream.stream.state.buffer1
    @GC.preserve buffer begin
        ptr = TranscodingStreams.bufferptr(buffer)
        nb = TranscodingStreams.buffersize(buffer)
        (pos, len) = unsafe_findfirst_sentinel_head(
            limiter.sentinel,
            limiter.failure_function,
            ptr,
            nb,
        )
        if len == 0
            # sentinel not found, so everything is available
            return nb
        end
        if pos > 1
            # read only up to the byte before the start of the sentinel
            return pos-1
        end
        # check to see if the descriptor matches the stats block
        slen = length(limiter.sentinel)
        if nb < slen + 20 # 4 CRC bytes, 16 size bytes
            return -1 # the input was too short to make a determination, so ask for more data
        end
        if unsafe_bytesle2int(UInt32, ptr+slen) != crc32(stream)
            return 1 # the sentinel was fake, so we can consume 1 byte and move on
        end
        if unsafe_bytesle2int(UInt64, ptr+slen+4) != bytes_out(stream)
            return 1
        end
        if unsafe_bytesle2int(UInt64, ptr+slen+12) != bytes_in(stream)
            return 1
        end
    end
    return 0 # the sentinel was found, no bytes available to read anymore 
end


mutable struct TruncatedSource{L<:AbstractLimiter,S<:TranscodingStream} <: IO
    limiter::L
    stream::CRC32Source{S}
    _eof::Bool
end
TruncatedSource(limiter::AbstractLimiter, stream::TranscodingStream) = TruncatedSource(limiter, CRC32Source(stream), false)

function Base.bytesavailable(stream::TruncatedSource)
    if eof(stream)
        return 0
    end
    n = bytes_remaining(stream.limiter, stream.stream)
    if n == 0
        stream._eof = true
        return 0
    end
    if n == -1
        # unable to determine based on current buffer
        # don't signal EOF, but don't claim to be able to read anything, either
        return 0 
    end
    return n
end

function Base.read(io::TruncatedSource, ::Type{UInt8})
    if eof(io)
        throw(EOFError())
    end
    b = read(io.stream, UInt8)
    if eof(io)
        io._eof = true
    end
    return b
end

function Base.unsafe_read(io::TruncatedSource, p::Ptr{UInt8}, n::Int)
    if eof(io)
        throw(EOFError())
    end
    unsafe_read(io.stream, p, n)
    if eof(io)
        io._eof = true
    end
    return nothing
end

function Base.readbytes!(io::TruncatedSource, a::AbstractArray{UInt8}, nb::Integer=length(a))
    if eof(io)
        throw(EOFError())
    end
    n = 0
    while n < nb && !eof(io)
        na = min(bytesavailable(io), nb - n)
        if length(a) < n + na
            resize!(a, min(length(a) * 2, nb))
        end
        @GC.preserve a unsafe_read(io.stream, pointer(a, n+1), na)
        n += na
    end
    return n
end

function Base.readavailable(io::TruncatedSource)
    return read(io.stream, bytesavailable(io))
end

for func in (:flush, :position, :close)
    @eval Base.$func(io::TruncatedSource) = $func(io.stream)
end

Base.eof(io::TruncatedSource) = io._eof || eof(io.stream)

function Base.skip(io::TruncatedSource, offset::Integer)
    read(io, offset) # drop the bytes on the floor
    return
end

Base.seek(::TruncatedSource) = error("TruncatedStream cannot seek")

Base.isreadable(io::TruncatedSource) = isreadable(io.stream)

Base.iswritable(::TruncatedSource) = false

bytes_in(io::TruncatedSource) = bytes_in(io.stream)
bytes_out(io::TruncatedSource) = bytes_out(io.stream)