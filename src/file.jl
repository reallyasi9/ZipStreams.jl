import Base: read

using CodecZlib
using Dates
using TranscodingStreams

struct ZipFileInformation
    compression_method::UInt16
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
    if signature != SIG_LOCAL_FILE
        error("unexpected local file header signature $(signature)")
    end

    version_needed = readle(io, UInt16)
    if version_needed & 0xff > ZIP64_MINIMUM_VERSION
        @warn "Version needed exceeds ISO standard" version_needed
    end

    flags = readle(io, UInt16)
    if (flags & ~(MASK_COMPRESSION_OPTIONS | FLAG_FILE_SIZE_FOLLOWS | FLAG_LANGUAGE_ENCODING)) != 0
        @warn "Unsupported general purpose flags detected" flags
    end
    descriptor_follows = (flags & FLAG_FILE_SIZE_FOLLOWS) != 0

    compression_method = readle(io, UInt16)
    if compression_method ∉ (COMPRESSION_STORE, COMPRESSION_DEFLATE)
        error("unimplemented compression method $(compression_method)")
    end

    modtime = readle(io, UInt16)
    moddate = readle(io, UInt16)
    last_modified = msdos2datetime(moddate, modtime)

    crc32 = readle(io, UInt32)
    compressed_size = UInt64(readle(io, UInt32))
    uncompressed_size = UInt64(readle(io, UInt32))

    if descriptor_follows && ((crc32 > 0) || (compressed_size > 0) || (uncompressed_size > 0))
        @warn "general purpose flag 3 requires non-zero CRC-32, compressed size, and uncompressed size fields" flags crc32 compressed_size uncompressed_size
    end

    filename_length = readle(io, UInt16)
    extrafield_length = readle(io, UInt16)

    encoding = (flags & FLAG_LANGUAGE_ENCODING) != 0 ? enc"UTF-8" : enc"IBM437"
    (filename, bytes_read) = readstring(io, filename_length; encoding=encoding)
    if bytes_read != filename_length
        error("EOF when reading file name")
    end

    extra_read = 0
    zip64 = false
    while extra_read < extrafield_length
        ex_signature = readle(io, UInt16)
        ex_length = readle(io, UInt16)
        extra_read += 4

        if ex_signature != HEADER_ZIP64
            skip(io, ex_length)
            extra_read += ex_length
            continue
        end

        # MUST include BOTH original and compressed file size fields per 4.5.3.
        uncompressed_size = readle(io, UInt64)
        compressed_size = readle(io, UInt64)
        zip64 = true
        extra_read += ex_length
        # NOTE: this is an assumption. Nothing in the spec says there can't be 
        # more than one Zip64 header, nor what to do if such a case is found.
        break
    end
    # Skip past additional extra data that went unused
    if extra_read < extrafield_length
        skip(io, extrafield_length - extra_read)
    end

    return ZipFileInformation(
        compression_method,
        uncompressed_size,
        compressed_size,
        last_modified,
        crc32,
        filename,
        descriptor_follows,
        zip64,
    )

end

struct ZipFile{S<:IO} <: IO
    info::ZipFileInformation
    _io::S
end

function zipfile(info::ZipFileInformation, io::IO)
    truncstream = TruncatedStream(io, info.compressed_size)
    # FIXME
    C = info.compression_method == DeflateCompression ? CodecZlib.DeflateCompressor : TranscodingStreams.Noop
    transstream = TranscodingStream(C(), truncstream)
    crc32stream = CRC32Stream(transstream)
    return ZipFile(info, crc32stream)
end

