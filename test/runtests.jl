using CodecZlib
using Dates
using LazyArtifacts
using Random
using Test
using TranscodingStreams
using ZipStreams

import Base: bytesavailable, close, eof, isopen, read, seek, unsafe_read, unsafe_write

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
const FILE_CONTENT = "Hello, Julia!"
const DEFLATED_FILE_CONTENT = transcode(DeflateCompressor, FILE_CONTENT)
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

const FILE_INFO = file_info(; compression=ZipStreams.COMPRESSION_DEFLATE)
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

@test Any[] == detect_ambiguities(Base, Core, ZipStreams)

@testset "MSDOSDateTime" begin
    # round trip
    test_now = now()
    @test test_now - (test_now |> ZipStreams.datetime2msdos |> ZipStreams.msdos2datetime) < Second(2)

    # minimum datetime
    @test ZipStreams.datetime2msdos(DateTime(1980, 1, 1, 0, 0, 0)) == (0x0021, 0x0000)
    @test ZipStreams.msdos2datetime(0x0021, 0x0000) == DateTime(1980, 1, 1, 0, 0, 0)
    # equivalent in Julia
    @test ZipStreams.datetime2msdos(DateTime(1979,12,31,24, 0, 0)) == (0x0021, 0x0000)
    # errors (separate minima for day and month)
    @test_throws InexactError ZipStreams.datetime2msdos(DateTime(1979,12,31,23,59,59))
    @test_throws ArgumentError ZipStreams.msdos2datetime(0x0040, 0x0000)
    @test_throws ArgumentError ZipStreams.msdos2datetime(0x0001, 0x0000)

    # maximum datetime
    @test ZipStreams.datetime2msdos(DateTime(2107,12,31,23,59,58)) == (0xff9f, 0xbf7d)
    @test ZipStreams.msdos2datetime(0xff9f, 0xbf7d) == DateTime(2107,12,31,23,59,58)
    # errors (separate maxima for month/day, hour, minute, and second)
    @test_throws ArgumentError ZipStreams.datetime2msdos(DateTime(2107,12,31,24, 0, 0))
    @test_throws ArgumentError ZipStreams.msdos2datetime(0xffa0, 0x0000)
    @test_throws ArgumentError ZipStreams.msdos2datetime(0xffa0, 0x0000)
    @test_throws ArgumentError ZipStreams.msdos2datetime(0x0000, 0xc000)
    @test_throws ArgumentError ZipStreams.msdos2datetime(0x0000, 0xbf80)
    @test_throws ArgumentError ZipStreams.msdos2datetime(0x0000, 0xbf7e)
end

@testset "CRC32" begin
    @testset "Array" begin
        @test ZipStreams.crc32(UInt8[]) == 0x00000000
        @test ZipStreams.crc32(UInt8[0]) == 0xd202ef8d
        @test ZipStreams.crc32(UInt8[1, 2, 3, 4]) == 0xb63cfbcd

        @test ZipStreams.crc32(UInt8[5, 6, 7, 8], ZipStreams.crc32(UInt8[1, 2, 3, 4])) ==
            ZipStreams.crc32(UInt8[1, 2, 3, 4, 5, 6, 7, 8]) ==
            0x3fca88c5

        @test ZipStreams.crc32(UInt16[0x0201, 0x0403]) ==
            ZipStreams.crc32(UInt8[1, 2, 3, 4]) ==
            0xb63cfbcd
    end
    @testset "String" begin
        @test ZipStreams.crc32("") == 0x00000000
        @test ZipStreams.crc32("The quick brown fox jumps over the lazy dog") == 0x414fa339

        @test ZipStreams.crc32("Julia!", ZipStreams.crc32("Hello ")) ==
            ZipStreams.crc32("Hello Julia!") ==
            0x424b94c7
    end
end

@testset "TruncatedInputStream" begin
    s = ZipStreams.TruncatedInputStream(
        IOBuffer("The quick brown fox jumps over the lazy dog"), 15
    )
    @test !eof(s)
    @test bytesavailable(s) == 15

    @test read(s, String) == "The quick brown"
    @test eof(s)
    @test bytesavailable(s) == 0
    @test read(s) == UInt8[]

    s = ZipStreams.TruncatedInputStream(
        IOBuffer("The quick brown fox jumps over the lazy dog"), 100
    )
    @test bytesavailable(s) == 43

    @test read(s, String) == "The quick brown fox jumps over the lazy dog"
    @test eof(s)
    @test bytesavailable(s) == 0
    @test read(s) == UInt8[]
end

@testset "Seek backward" begin
    @testset "End" begin
        fake_data = UInt8.(rand('a':'z', 10_000))
        signature = UInt8.(collect("FOO"))
        fake_data[end-2:end] .= signature
        stream = IOBuffer(fake_data)
        seekend(stream)
        ZipStreams.seek_backward_to(stream, signature)
        @test position(stream) == length(fake_data)-length(signature) # streams are zero indexed
    end

    @testset "Random" begin
        signature = UInt8.(collect("BAR"))
        for i in 1:100
            fake_data = UInt8.(rand('a':'z', 10_000))
            pos = rand(1:length(fake_data)-length(signature)+1)
            fake_data[pos:pos+length(signature)-1] .= signature
            stream = IOBuffer(fake_data)
            seekend(stream)
            ZipStreams.seek_backward_to(stream, signature)
            @test position(stream) == pos-1 # streams are zero indexed
            @test read(stream, length(signature)) == signature
        end
    end

    @testset "Multiple" begin
        signature = UInt8.(collect("BAZ"))
        fake_data = UInt8.(rand('a':'z', 10_000))
        fake_data[1001:1003] .= signature
        fake_data[9001:9003] .= signature
        stream = IOBuffer(fake_data)
        seekend(stream)
        ZipStreams.seek_backward_to(stream, signature)
        @test position(stream) == 9000
        @test read(stream, length(signature)) == signature
    end

    @testset "Multiple same block" begin
        signature = UInt8.(collect("BIN"))
        fake_data = UInt8.(rand('a':'z', 10_000))
        fake_data[9991:9993] .= signature
        fake_data[9981:9983] .= signature
        stream = IOBuffer(fake_data)
        seekend(stream)
        ZipStreams.seek_backward_to(stream, signature)
        @test position(stream) == 9990
        @test read(stream, length(signature)) == signature
    end

    @testset "Straddle 4k" begin
        signature = UInt8.(collect("Hello, Julia!"))
        fake_data = UInt8.(rand('a':'z', 10_000))
        fake_data[end-4100:end-4088] .= signature
        stream = IOBuffer(fake_data)
        seekend(stream)
        ZipStreams.seek_backward_to(stream, signature)
        @test position(stream) == length(fake_data) - 4101
        @test read(stream, length(signature)) == signature
    end

    @testset "Missing" begin
        signature = UInt8.(collect("QUA"))
        fake_data = UInt8.(rand('a':'z', 10_000))
        stream = IOBuffer(fake_data)
        seekend(stream)
        ZipStreams.seek_backward_to(stream, signature)
        @test eof(stream)
    end
end

@testset "File components" begin
    @testset "LocalFileHeader" begin
        @testset "Empty archive" begin
            open(EMPTY_FILE, "r") do f
                skip(f, 4)
                @test_throws ArgumentError read(f, ZipStreams.LocalFileHeader)
            end
        end

        @testset "Simple archive" begin
            open(SINGLE_FILE, "r") do f
                skip(f, 4)
                @test read(f, ZipStreams.LocalFileHeader).info == FILE_INFO
            end
        end

        @testset "Zip64 local header" begin
            open(ZIP64_F, "r") do f
                skip(f, 4)
                @test read(f, ZipStreams.LocalFileHeader).info == ZIP64_FILE_INFO
            end
        end
    end

    @testset "CentralDirectoryHeader" begin
        @testset "Empty archive" begin
            open(EMPTY_FILE, "r") do f
                skip(f, 4)
                @test_throws ArgumentError read(f, ZipStreams.CentralDirectoryHeader)
            end
        end

        @testset "Simple archive" begin
            open(SINGLE_FILE, "r") do f
                skip(f, 0x3A)
                header = read(f, ZipStreams.CentralDirectoryHeader)
                @test header.info == FILE_INFO
                @test header.offset == 0
                @test header.comment == ""
            end
        end

        @testset "Zip64 Central Directory" begin
            open(ZIP64_C, "r") do f
                skip(f, 0x3A)
                header = read(f, ZipStreams.CentralDirectoryHeader)
                @test header.info == ZIP64_FILE_INFO
                @test header.offset == 0
                @test header.comment == ""
            end
        end

        @testset "Multi archive" begin
            open(MULTI_FILE, "r") do f
                skip(f, 0x371)
                for cmp in MULTI_INFO
                    skip(f, 0x4)
                    header = read(f, ZipStreams.CentralDirectoryHeader)
                    @test header.info == cmp
                end
            end
        end
    end
end

@testset "Input archive construction" begin
    @testset "Empty archive" begin
        buffer = IOBuffer()
        archive = zipsink(buffer)
        close(archive)
    end

    @testset "Write files" begin
        @testset "Single file, uncompressed" begin
            buffer = IOBuffer()
            archive = zipsink(buffer)
            f = open(archive, "hello.txt"; compression=:store)
            @test write(f, FILE_CONTENT) == 13
            close(f)
            close(archive; close_sink=false)
            @test buffer.size == 173

            readme = IOBuffer(take!(buffer))
            skip(readme, 4)
            header = read(readme, ZipStreams.LocalFileHeader)
            @test header.info.compressed_size == 0
            @test header.info.compression_method == ZipStreams.COMPRESSION_STORE
            @test header.info.crc32 == ZipStreams.CRC32_INIT
            @test header.info.descriptor_follows == true
            @test header.info.name == "hello.txt"
            @test header.info.uncompressed_size == 0
            @test header.info.utf8 == true
            @test header.info.zip64 == true
        end
        @testset "Single file, compressed" begin
            buffer = IOBuffer()
            archive = zipsink(buffer)
            f = open(archive, "hello.txt"; compression=:deflate)
            @test write(f, FILE_CONTENT) == 13
            close(f)
            close(archive; close_sink=false)
            @test buffer.size == 175

            readme = IOBuffer(take!(buffer))
            skip(readme, 4)
            header = read(readme, ZipStreams.LocalFileHeader)
            @test header.info.compressed_size == 0
            @test header.info.compression_method == ZipStreams.COMPRESSION_DEFLATE
            @test header.info.crc32 == ZipStreams.CRC32_INIT
            @test header.info.descriptor_follows == true
            @test header.info.name == "hello.txt"
            @test header.info.uncompressed_size == 0
            @test header.info.utf8 == true
            @test header.info.zip64 == true
        end
        @testset "Single file, subdirectory (make_path=false, default)" begin
            buffer = IOBuffer()
            archive = zipsink(buffer)
            @test_throws ArgumentError open(archive, "subdir/hello.txt")
            @test_throws ArgumentError open(archive, "subdir/hello.txt"; make_path=false)
            close(archive)
        end
        @testset "Single file, subdirectory (make_path=true)" begin
            buffer = IOBuffer()
            archive = zipsink(buffer)
            f = open(archive, "subdir/hello.txt"; make_path=true)
            write(f, FILE_CONTENT)
            close(f)
            close(archive)
        end
        @testset "Write at once" begin
            buffer = IOBuffer()
            archive = zipsink(buffer)
            write_file(archive, "hello.txt", FILE_CONTENT)
            close(archive; close_sink=false)
            @test buffer.size == 131

            readme = IOBuffer(take!(buffer))
            skip(readme, 4)
            header = read(readme, ZipStreams.LocalFileHeader)
            @test header.info.compressed_size == sizeof(DEFLATED_FILE_CONTENT)
            @test header.info.compression_method == ZipStreams.COMPRESSION_DEFLATE
            @test header.info.crc32 == ZipStreams.crc32(FILE_CONTENT)
            @test header.info.descriptor_follows == false
            @test header.info.name == "hello.txt"
            @test header.info.uncompressed_size == sizeof(FILE_CONTENT)
            @test header.info.utf8 == true
            @test header.info.zip64 == false
        end
    end
end

@testset "Archive iteration" begin
    @testset "next_file" begin
        @testset "Empty archive" begin
            archive = zipsource(EMPTY_FILE)
            f = next_file(archive)
            @test isnothing(f)
            close(archive)
        end

        @testset "Simple archive" begin
            archive = zipsource(SINGLE_FILE)
            f = next_file(archive)
            @test !isnothing(f)
            @test f.info == FILE_INFO
            f = next_file(archive)
            @test isnothing(f)
            close(archive)
        end

        @testset "Multi archive" begin
            archive = zipsource(MULTI_FILE)
            for info in MULTI_INFO
                if isdir(info)
                    continue
                end
                f = next_file(archive)
                @test !isnothing(f)
                @test f.info == info
            end
            f = next_file(archive)
            @test isnothing(f)
            close(archive)
        end
    end

    @testset "iterator" begin
        @testset "Empty archive" begin
            archive = zipsource(EMPTY_FILE)
            for f in archive
                @test false
            end
            close(archive)
        end

        @testset "Simple archive" begin
            archive = zipsource(SINGLE_FILE)
            for f in archive
                @test !isnothing(f)
                @test f.info == FILE_INFO
            end
            f = next_file(archive)
            @test isnothing(f)
            close(archive)
        end

        @testset "Multi archive" begin
            archive = zipsource(MULTI_FILE)
            for (f, info) in zip(archive, filter(x -> !isdir(x), MULTI_INFO))
                @test !isnothing(f)
                @test f.info == info
            end
            f = next_file(archive)
            @test isnothing(f)
            close(archive)
        end
    end
end


@testset "Mock stream IO" begin
    buffer = IOBuffer()
    wo = ForwardWriteOnlyIO(buffer)
    sink = zipsink(wo)
    write_file(sink, "hello.txt", FILE_CONTENT)
    close(sink; close_sink=false)

    seekstart(buffer)
    ro = ForwardReadOnlyIO(buffer)
    source = zipsource(ro)
    zf = next_file(source)
    @test read(zf, String) == FILE_CONTENT
    close(source)
end

@testset "Stream-to-Archive IO" begin
    buffer = IOBuffer()
    zipsink(buffer) do sink
        open(SINGLE_FILE, "r") do f
            open(sink, "test.zip") do zf
                @test write(zf, f) == filesize(f)
            end
        end
    end
end