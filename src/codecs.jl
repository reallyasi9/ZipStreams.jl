import TranscodingStreams: expectedsize, startproc, process

using TranscodingStreams

mutable struct FixedSizeReadCodec <: TranscodingStreams.Codec
    bytes_remaining::Int
end

function TranscodingStreams.expectedsize(codec::FixedSizeReadCodec, ::TranscodingStreams.Memory)
    return codec.bytes_remaining
end

function TranscodingStreams.startproc(::FixedSizeReadCodec, mode::Symbol, error::TranscodingStreams.Error)
    if mode != :read
        error[] = ErrorException("codec is read-only")
        return :error
    end
    return :ok
end

function TranscodingStreams.process(codec::FixedSizeReadCodec, input::TranscodingStreams.Memory, output::TranscodingStreams.Memory, ::TranscodingStreams.Error)
    n = min(length(input), length(output), codec.bytes_remaining)
    if n <= 0
        return (0,0,:end)
    end
    unsafe_copyto!(output.ptr, input.ptr, n)
    codec.bytes_remaining -= n
    return (n,n,:ok)
end

struct DataDescriptorCodec <: TranscodingStreams.Codec
    sentinel::Vector{UInt8}
    buffer::Vector{UInt8}
end

function DataDescriptorCodec(sentinel::Vector{UInt8} = hotl(bytearray(SIG_DATA_DESCRIPTOR)))
    return DataDescriptorCodec(sentinel, Vector{UInt8}(undef, 2^15))
end

function TranscodingStreams.expectedsize(codec::DataDescriptorCodec, ::TranscodingStreams.Memory)
    return length(codec.sentinel)
end

function TranscodingStreams.startproc(::DataDescriptorCodec, mode::Symbol, error::TranscodingStreams.Error)
    if mode != :read
        error[] = ErrorException("codec is read-only")
        return :error
    end
    return :ok
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


function TranscodingStreams.process(codec::DataDescriptorCodec, input::TranscodingStreams.Memory, output::TranscodingStreams.Memory, ::TranscodingStreams.Error)
    n = min(length(input), length(output), length(codec.buffer))
    if n <= 0
        return (0,0,:end)
    end
    ptr = pointer(codec.buffer)
    unsafe_copyto!(ptr, input.ptr, n)
    spos, found = _findfirst_sentinel_head(codec.sentinel, @view codec.buffer[1:n])
    if found
        spos -= 1
        unsafe_copyto!(output.ptr, ptr, spos)
        return (spos,spos,:end)
    else
        unsafe_copyto!(output.ptr, ptr, spos)
        return (spos,spos,:ok)    
    end
end

mutable struct CRC32ReadCodec <: TranscodingStreams.Codec
    crc::UInt32
    
    CRC32ReadCodec(initial_crc::UInt32 = CRC32_INIT) = new(initial_crc)
end

function TranscodingStreams.startproc(::CRC32ReadCodec, mode::Symbol, error::TranscodingStreams.Error)
    if mode != :read
        error[] = ErrorException("codec is read-only")
        return :error
    end
    return :ok
end

function TranscodingStreams.process(codec::CRC32ReadCodec, input::TranscodingStreams.Memory, output::TranscodingStreams.Memory, ::TranscodingStreams.Error)
    n = min(length(input), length(output))
    if n <= 0
        return (0,0,:end)
    end
    unsafe_copyto!(output.ptr, input.ptr, n)
    codec.crc = crc32(output.ptr, n, codec.crc)
    return (n,n,:ok)
end