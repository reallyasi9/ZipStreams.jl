import Base: bytesavailable, close, eof, isopen, read, unsafe_read, unsafe_write

using CodecZlib
using Dates
using TranscodingStreams

struct ZipFileInformation
    compression_method::CompressionMethod
    uncompressed_size::UInt64
    compressed_size::UInt64
    last_modified::DateTime
    crc32::UInt32

    name::String

    descriptor_follows::Bool
    zip64::Bool
end

function Base.read(io::IO, ::Type{ZipFileInformation})
    signature = readle(io, UInt32)
    if signature != Integer(LocalFileHeaderSignature)
        error("unexpected local file header signature $(signature)")
    end

    version_needed = readle(io, UInt16)
    if version_needed & 0xff > 45
        @warn "Version needed exceeds ISO standard" version_needed
    end

    flags = readle(io, UInt16)
    if (flags & ~(Integer(CompressionOptionsFlags) | Integer(LocalHeaderSignatureEmptyFlag) | Integer(LanguageEncodingFlag))) != 0
        @warn "Unsupported general purpose flags detected" flags
    end
    descriptor_follows = (flags & Integer(LocalHeaderSignatureEmptyFlag)) != 0

    compression_method = readle(io, UInt16)
    if compression_method ∉ [Integer(StoreCompression), Integer(DeflateCompression)]
        error("unimplemented compression method $(compression_method)")
    end
    if compression_method == Integer(StoreCompression) && descriptor_follows
        error("stream-archived data (flag 3) cannot be extracted reliably without reading the Central Directory")
    end

    modtime = readle(io, UInt16)
    moddate = readle(io, UInt16)
    last_modified = msdos2datetime(moddate, modtime)

    crc32 = readle(io, UInt32)
    compressed_size = UInt64(readle(io, UInt32))
    uncompressed_size = UInt64(readle(io, UInt32))

    if descriptor_follows && ((crc32 > 0) || (compressed_size > 0) || (uncompressed_size > 0))
        error("general purpose flag 3 requires non-zero CRC-32, compressed size, and uncompressed size fields")
    end

    filename_length = readle(io, UInt16)
    extrafield_length = readle(io, UInt16)

    encoding = (flags & Integer(LanguageEncodingFlag)) != 0 ? enc"UTF-8" : enc"IBM437"
    (filename, bytes_read) = readstring(io, filename_length; encoding=encoding)
    if bytes_read != filename_length
        error("EOF when reading file name")
    end

    extradata = Array{UInt8}(undef, extrafield_length)
    bytes_read = readbytes!(io, extradata, extrafield_length)
    if bytes_read != extrafield_length
        error("EOF when reading extra field")
    end

    extra_view = @view extradata[:]
    zip64 = false
    while length(extra_view) > 0
        ex_signature = bytesle2int(extra_view[1:2], UInt16)
        ex_length = bytesle2int(extra_view[3:4], UInt16)

        if ex_signature != Integer(Zip64Header)
            extra_view = @view extra_view[5 + ex_length:end]
            continue
        end

        # MUST include BOTH original and compressed file size fields per 4.5.3.
        uncompressed_size = bytesle2int(extra_view[5:12], UInt64)
        compressed_size = bytesle2int(extra_view[13:20], UInt64)
        zip64 = true
        break
    end

    return ZipFileInformation(
        CompressionMethod(compression_method),
        uncompressed_size,
        compressed_size,
        last_modified,
        crc32,
        filename,
        descriptor_follows,
        zip64,
    )

end

struct ZipFile{C<:TranscodingStreams.Codec,S<:IO} <: IO
    info::ZipFileInformation
    _io::TranscodingStream{C,S}
end

function ZipFile{C}(info::ZipFileInformation, io::IO) where (C<:TranscodingStreams.Codec)
    truncstream = TruncatedStream(io, info.compressed_size)
    crc32stream = CRC32Stream(truncstream)
    transstream = TranscodingStream(C(), crc32stream)
    return ZipFile{C,CRC32Stream}(info, transstream)
end

Base.bytesavailable(s::ZipFile) = bytesavailable(s._io)
Base.close(s::ZipFile) = close(s._io)
Base.eof(s::ZipFile) = eof(s._io)
Base.isopen(s::ZipFile) = isopen(s._io)
Base.unsafe_read(s::ZipFile, p::Ptr{UInt8}, nb::UInt) = unsafe_read(s._io, p, nb)
Base.unsafe_write(s::ZipFile, p::Ptr{UInt8}, nb::UInt) = unsafe_write(s._io, p, nb)
