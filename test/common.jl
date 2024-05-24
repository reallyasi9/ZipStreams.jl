using CodecZlib
using ZipStreams

function file_info(; name::AbstractString="hello.txt", descriptor::Bool=false, utf8::Bool=false, zip64::Bool=false, datetime::DateTime=DateTime(2022, 8, 18, 23, 21, 38), compression::UInt16=ZipStreams.COMPRESSION_STORE)
    uc_size = 13 % UInt64
    if compression == ZipStreams.COMPRESSION_DEFLATE
        c_size = 15 % UInt64
        crc = 0xb2284bb4
    else
        # FIXME in multi
        uc_size = 14 % UInt64
        c_size = uc_size
        crc = 0xfe69594d
    end
    return ZipStreams.ZipFileInformation(
        compression,
        uc_size,
        c_size,
        datetime,
        crc,
        name, # Note: might be different for different files
        descriptor,
        utf8,
        zip64,
    )
end
function subdir_info(; name::AbstractString="subdir/", datetime::DateTime=DateTime(2020, 8, 18, 23, 21, 38), utf8::Bool=false, zip64::Bool=false)
    return ZipStreams.ZipFileInformation(
        ZipStreams.COMPRESSION_STORE,
        0,
        0,
        datetime,
        ZipStreams.CRC32_INIT,
        name, # Note: might be different for different files
        false,
        utf8,
        zip64,
    )
end

struct ForwardReadOnlyIO{S <: IO} <: IO
    io::S
end
Base.read(f::ForwardReadOnlyIO, ::Type{UInt8}) = read(f.io, UInt8)
# Base.unsafe_read(f::ForwardReadOnlyIO, p::Ptr{UInt8}, n::UInt) = unsafe_read(f.io, p, n)
Base.skip(f::ForwardReadOnlyIO, n::Int) = n < 0 ? error("backward skipping forbidden") : skip(f.io, n)
Base.close(f::ForwardReadOnlyIO) = close(f.io)
Base.isopen(f::ForwardReadOnlyIO) = isopen(f.io)
Base.eof(f::ForwardReadOnlyIO) = eof(f.io)
Base.bytesavailable(f::ForwardReadOnlyIO) = bytesavailable(f.io)
Base.position(f::ForwardReadOnlyIO) = position(f.io)

struct ForwardWriteOnlyIO{S <: IO} <: IO
    io::S
end
Base.unsafe_write(f::ForwardWriteOnlyIO, p::Ptr{UInt8}, n::UInt) = unsafe_write(f.io, p, n)
Base.close(f::ForwardWriteOnlyIO) = close(f.io)
Base.isopen(f::ForwardWriteOnlyIO) = isopen(f.io)
# Base.eof(f::ForwardWriteOnlyIO) = eof(f.io)

# All test files have the same content
const FILE_CONTENT = "Hello, Julia!\n"
const FILE_BYTES = collect(codeunits(FILE_CONTENT))
const DEFLATED_FILE_BYTES = UInt8[0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0xf0, 0x2a, 0xcd, 0xc9, 0x4c, 0x54, 0xe4, 0x02, 0x00]
const EMPTY_CRC = UInt32(0)
const ZERO_CRC = UInt32(0xD202EF8D)
const FILE_CONTENT_CRC = UInt32(0xFE69594D)

# build test file names
const ARTIFACT_DIR = artifact"testfiles"
function test_file_name(deflate::Bool, dd::Bool, local64::Bool, utf8::Bool, cd64::Bool, eocd64::Bool, extra::String="")
    s1 = deflate ? "deflate" : "store"
    s2 = dd ? "dd" : "nodd"
    s3 = local64 ? "local64" : "nolocal64"
    s4 = utf8 ? "utf" : "ibm"
    s5 = cd64 ? "cd64" : "nocd64"
    s6 = eocd64 ? "eocd64" : "noeocd64"
    arr = [s1, s2, s3, s4, s5, s6]
    if !isempty(extra)
        push!(arr, extra)
    end
    filename = join(arr, "-") * ".zip"
    return joinpath(ARTIFACT_DIR, filename)
end

function test_file_info(deflate::Bool, dd::Bool, zip64::Bool, utf8::Bool, subdir::String="")
    compression_method = deflate ? ZipStreams.COMPRESSION_DEFLATE : ZipStreams.COMPRESSION_STORE
    uncompressed_size = length(FILE_BYTES)
    compressed_size = deflate ? length(DEFLATED_FILE_BYTES) : uncompressed_size
    last_modified = DateTime(1980, 1, 1, 0, 0, 0)
    crc32 = FILE_CONTENT_CRC
    extrafield_length = zip64 ? 20 : 0
    filename = utf8 ? "hello👋.txt" : "hello.txt"
    if !isempty(subdir)
        filename = subdir * ZipStreams.ZIP_PATH_DELIMITER * filename
    end
    descriptor_follows = dd
    return ZipStreams.ZipFileInformation(
        compression_method,
        uncompressed_size,
        compressed_size,
        last_modified,
        crc32,
        extrafield_length,
        filename,
        descriptor_follows,
        utf8,
        zip64,
    )
end

# Special files
const EMPTY_FILE = joinpath(ARTIFACT_DIR, "noeocd64-empty.zip")
const EMPTY_FILE_EOCD64 = joinpath(ARTIFACT_DIR, "eocd64-empty.zip")