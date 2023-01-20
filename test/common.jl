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
const DEFLATED_FILE_CONTENT = transcode(DeflateCompressor, FILE_CONTENT)

const FILE_INFO = file_info(; compression=ZipStreams.COMPRESSION_DEFLATE, datetime=DateTime(2023, 1, 20, 0, 35, 14))
const ZIP64_FILE_INFO = file_info(; compression=ZipStreams.COMPRESSION_DEFLATE, zip64=true)
const SUBDIR_INFO = subdir_info()
const MULTI_INFO = ZipStreams.ZipFileInformation[
    file_info(; name="hello1.txt", datetime=DateTime(2022, 8, 19, 21, 46, 44)),
    subdir_info(; name="subdir/", datetime=DateTime(2022, 8, 19, 21, 47, 34)),
    file_info(; name="subdir/hello2.txt", datetime=DateTime(2022, 8, 19, 21, 47, 24)),
    file_info(; name="subdir/hello3.txt", datetime=DateTime(2022, 8, 19, 21, 47, 34)),
    subdir_info(; name="subdir/subdir/", datetime=DateTime(2022, 8, 19, 21, 47, 44)),
    subdir_info(; name="subdir/subdir/subdir/", datetime=DateTime(2022, 8, 19, 21, 48, 2)),
    file_info(; name="subdir/subdir/subdir/hello5.txt", datetime=DateTime(2022, 8, 19, 21, 47, 54)),
    file_info(; name="subdir/subdir/subdir/hello6.txt", datetime=DateTime(2022, 8, 19, 21, 48, 00)),
    file_info(; name="subdir/subdir/subdir/hello7.txt", datetime=DateTime(2022, 8, 19, 21, 48, 02)),
    file_info(; name="subdir/subdir/hello4.txt", datetime=DateTime(2022, 8, 19, 21, 47, 44)),
]

# Simple tests
const ARTIFACT_DIR = artifact"testfiles"
const EMPTY_FILE = joinpath(ARTIFACT_DIR, "empty.zip")
const SINGLE_FILE = joinpath(ARTIFACT_DIR, "single.zip")
const MULTI_FILE = joinpath(ARTIFACT_DIR, "multi.zip")
const RECURSIVE_FILE = joinpath(ARTIFACT_DIR, "zip.zip")

# Zip64 format tests
const ZIP64_F = joinpath(ARTIFACT_DIR, "single-f64.zip")
const ZIP64_FC = joinpath(ARTIFACT_DIR, "single-f64-cd64.zip")
const ZIP64_FE = joinpath(ARTIFACT_DIR, "single-f64-eocd64.zip")
const ZIP64_FCE = joinpath(ARTIFACT_DIR, "single-f64-cd64-eocd64.zip")
const ZIP64_C = joinpath(ARTIFACT_DIR, "single-cd64.zip")
const ZIP64_E = joinpath(ARTIFACT_DIR, "single-cd64-eocd64.zip")
const ZIP64_CE = joinpath(ARTIFACT_DIR, "single-eocd64.zip")

# Data descriptor tests
const SINGLE_DD_FILE = joinpath(ARTIFACT_DIR, "single-dd.zip")
const MULTI_DD_FILE = joinpath(ARTIFACT_DIR, "multi-dd.zip")

# Pathological tests
const PATHOLOGICAL_DD_FILE = joinpath(ARTIFACT_DIR, "single-dd-pathological.zip")

@test Any[] == detect_ambiguities(Base, Core, ZipStreams)