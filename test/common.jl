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
Base.seek(f::ForwardReadOnlyIO, n::Int) = n < 0 ? error("backward seeking forbidden") : seek(f.io, n)
Base.close(f::ForwardReadOnlyIO) = close(f.io)
Base.isopen(f::ForwardReadOnlyIO) = isopen(f.io)
Base.eof(f::ForwardReadOnlyIO) = eof(f.io)
Base.bytesavailable(f::ForwardReadOnlyIO) = bytesavailable(f.io)

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

# Special files
const EMPTY_FILE = joinpath(ARTIFACT_DIR, "noeocd64-empty.zip")
const EMPTY_FILE_EOCD64 = joinpath(ARTIFACT_DIR, "eocd64-empty.zip")