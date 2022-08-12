import Base: transcode, position, seek, seekstart, seekend, unsafe_read, unsafe_write

using TranscodingStreams
import TranscodingStreams: expectedsize, minoutsize, finalize, startproc, process, stats, fillbuffer, flushbuffer, flushbufferall, flushuntilend

const CRC32_INIT = 0x00000000

function crc32(data::Ptr{UInt8}, n::UInt, crc::UInt32=CRC32_INIT)
    return ccall((:crc32, "libz"), Culong, (Culong, Ptr{Cchar}, Cuint), crc, data, n) % UInt32
end

crc32(data::Vector{UInt8}, crc::UInt32=CRC32_INIT) = GC.@preserve data crc32(pointer(data), UInt(length(data)), crc)
crc32(data::Vector, crc::UInt32=CRC32_INIT) = GC.@preserve data crc32(pointer(reinterpret(UInt8, data)), UInt(sizeof(data)), crc)
crc32(s::String, crc::UInt32=CRC32_INIT) = crc32(Vector{UInt8}(s), crc)

mutable struct CRC32Codec <: TranscodingStreams.Codec
    crc32::UInt32
    codec::Noop
    CRC32Codec() = new(CRC32_INIT, Noop())
end

TranscodingStreams.expectedsize(codec::CRC32Codec, input::TranscodingStreams.Memory) = expectedsize(codec.codec, input)
TranscodingStreams.minoutsize(codec::CRC32Codec, input::TranscodingStreams.Memory) = minoutsize(codec.codec, input)
TranscodingStreams.finalize(codec::CRC32Codec) = finalize(codec.codec)
TranscodingStreams.startproc(codec::CRC32Codec, mode::Symbol, error::TranscodingStreams.Error) = startproc(codec.codec, mode, error)

function TranscodingStreams.process(codec::CRC32Codec, input::TranscodingStreams.Memory, output::TranscodingStreams.Memory, error::TranscodingStreams.Error)
    if input.size == 0
        return 0, 0, :end
    end
    codec.crc32 = crc32(input.ptr, input.size, codec.crc32)

    return input.size, output.size, :ok
end

# copied from TranscodingStreams.Noop
const CRC32Stream{S} = TranscodingStream{CRC32Codec,S} where S<:IO

function CRC32Stream(stream::IO; kwargs...)
    return TranscodingStream(CRC32Codec(), stream; kwargs...)
end

function TranscodingStream(codec::CRC32Codec, stream::IO;
                           bufsize::Integer=TranscodingStreams.DEFAULT_BUFFER_SIZE,
                           sharedbuf::Bool=(stream isa TranscodingStream))
    TranscodingStreams.checkbufsize(bufsize)
    TranscodingStreams.checksharedbuf(sharedbuf, stream)
    if sharedbuf
        buffer = stream.state.buffer1
    else
        buffer = TranscodingStreams.Buffer(bufsize)
    end
    return TranscodingStream(codec, stream, TranscodingStreams.State(buffer, buffer))
end

"""
    position(stream::NoopStream)
Get the current poition of `stream`.
Note that this method may return a wrong position when
- some data have been inserted by `TranscodingStreams.unread`, or
- the position of the wrapped stream has been changed outside of this package.
"""
function Base.position(stream::CRC32Stream)
    mode = stream.state.mode
    TranscodingStreams.@checkmode (:idle, :read, :write)
    if mode === :idle
        return Int64(0)
    elseif mode === :write
        return position(stream.stream) + buffersize(stream.state.buffer1)
    elseif mode === :read
        return position(stream.stream) - buffersize(stream.state.buffer1)
    end
    @assert false "unreachable"
end

function Base.seek(stream::CRC32Stream, pos::Integer)
    seek(stream.stream, pos)
    TranscodingStreams.initbuffer!(stream.state.buffer1)
    return
end

function Base.seekstart(stream::CRC32Stream)
    seekstart(stream.stream)
    TranscodingStreams.initbuffer!(stream.state.buffer1)
    return
end

function Base.seekend(stream::CRC32Stream)
    seekend(stream.stream)
    TranscodingStreams.initbuffer!(stream.state.buffer1)
    return
end

function Base.unsafe_read(stream::CRC32Stream, output::Ptr{UInt8}, nbytes::UInt)
    TranscodingStreams.changemode!(stream, :read)
    buffer = stream.state.buffer1
    p = output
    p_end = output + nbytes
    while p < p_end && !eof(stream)
        if TranscodingStreams.buffersize(buffer) > 0
            m = min(TranscodingStreams.buffersize(buffer), p_end - p)
            TranscodingStreams.copydata!(p, buffer, m)
            stream.codec.crc32 = crc32(p, m, stream.codec.crc32)
        else
            # directly read data from the underlying stream
            m = p_end - p
            Base.unsafe_read(stream.stream, p, m)
            stream.codec.crc32 = crc32(p, m, stream.codec.crc32)
        end
        p += m
    end
    if p < p_end && eof(stream)
        throw(EOFError())
    end
    return
end

function Base.unsafe_write(stream::CRC32Stream, input::Ptr{UInt8}, nbytes::UInt)
    TranscodingStreams.changemode!(stream, :write)
    stream.codec.crc32 = crc32(input, nbytes, stream.codec.crc32)
    buffer = stream.state.buffer1
    if TranscodingStreams.marginsize(buffer) ≥ nbytes
        TranscodingStreams.copydata!(buffer, input, nbytes)
        return Int(nbytes)
    else
        TranscodingStreams.flushbuffer(stream)
        # directly write data to the underlying stream
        return unsafe_write(stream.stream, input, nbytes)
    end
end

function Base.transcode(::Type{CRC32Codec}, data::TranscodingStreams.ByteData)
    # Copy data because the caller may expect the return object is not the same
    # as from the input.
    # Does nothing because the codec is not given as input
    return Vector{UInt8}(data)
end

function Base.transcode(codec::CRC32Codec, data::TranscodingStreams.ByteData)
    # Copy data because the caller may expect the return object is not the same
    # as from the input.
    # Updates the codec.
    return read(TranscodingStream(codec, IOBuffer(data)), sizeof(data))
end


# Stats
# -----

function TranscodingStreams.stats(stream::CRC32Stream)
    state = stream.state
    mode = state.mode
    TranscodingStreams.@checkmode (:idle, :read, :write)
    buffer = state.buffer1
    @assert buffer === stream.state.buffer2
    if mode == :idle
        consumed = supplied = 0
    elseif mode == :read
        supplied = buffer.transcoded
        consumed = supplied - TranscodingStreams.buffersize(buffer)
    elseif mode == :write
        supplied = buffer.transcoded + TranscodingStreams.buffersize(buffer)
        consumed = buffer.transcoded
    else
        @assert false "unreachable"
    end
    return TranscodingStreams.Stats(consumed, supplied, supplied, supplied)
end


# Buffering
# ---------
#
# These methods are overloaded for the `CRC32Codec` codec because it has only one
# buffer for efficiency.

function TranscodingStreams.fillbuffer(stream::CRC32Stream; eager::Bool = false)
    TranscodingStreams.changemode!(stream, :read)
    buffer = stream.state.buffer1
    @assert buffer === stream.state.buffer2
    if stream.stream isa TranscodingStream && buffer === stream.stream.state.buffer1
        # Delegate the operation when buffers are shared.
        return TranscodingStreams.fillbuffer(stream.stream, eager = eager)
    end
    nfilled::Int = 0
    while ((!eager && TranscodingStreams.buffersize(buffer) == 0) || (eager && TranscodingStreams.makemargin!(buffer, 0, eager = true) > 0)) && !eof(stream.stream)
        TranscodingStreams.makemargin!(buffer, 1)
        nfilled += TranscodingStreams.readdata!(stream.stream, buffer)
    end
    buffer.transcoded += nfilled
    return nfilled
end

function TranscodingStreams.flushbuffer(stream::CRC32Stream, all::Bool=false)
    TranscodingStreams.changemode!(stream, :write)
    buffer = stream.state.buffer1
    @assert buffer === stream.state.buffer2
    nflushed::Int = 0
    if all
        while TranscodingStreams.buffersize(buffer) > 0
            nflushed += TranscodingStreams.writedata!(stream.stream, buffer)
        end
    else
        nflushed += TranscodingStreams.writedata!(stream.stream, buffer)
        TranscodingStreams.makemargin!(buffer, 0)
    end
    buffer.transcoded += nflushed
    return nflushed
end

function TranscodingStreams.flushuntilend(stream::CRC32Stream)
    stream.state.buffer1.transcoded += TranscodingStreams.writedata!(stream.stream, stream.state.buffer1)
    return
end