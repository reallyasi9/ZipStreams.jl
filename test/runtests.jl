using Dates
using Test
using TranscodingStreams
using CodecZlib
using ZipStreams
using Random

const THIS_DIR = dirname(@__FILE__)

# All test files have the same content
const FILE_CONTENT = "Hello, Julia!"
const FILE_INFO = ZipStreams.ZipFileInformation(
    ZipStreams.COMPRESSION_DEFLATE,
    13,
    15,
    DateTime(2022, 8, 18, 23, 21, 38),
    0xb2284bb4,
    "hello.txt", # Note: might be different for different files
    false,
    false,
    false,
)
const ZIP64_FILE_INFO = ZipStreams.ZipFileInformation(
    ZipStreams.COMPRESSION_DEFLATE,
    13,
    15,
    DateTime(2022, 8, 18, 23, 21, 38),
    0xb2284bb4,
    "hello.txt", # Note: might be different for different files
    false,
    false,
    true,
)

# Simple tests
const EMPTY_FILE = joinpath(THIS_DIR, "empty.zip")
const SINGLE_FILE = joinpath(THIS_DIR, "single.zip")
const MULTI_FILE = joinpath(THIS_DIR, "multi.zip")
const RECURSIVE_FILE = joinpath(THIS_DIR, "zip.zip")

# Zip64 format tests
const ZIP64_F = joinpath(THIS_DIR, "single-f64.zip")
const ZIP64_FC = joinpath(THIS_DIR, "single-f64-cd64.zip")
const ZIP64_FE = joinpath(THIS_DIR, "single-f64-eocd64.zip")
const ZIP64_FCE = joinpath(THIS_DIR, "single-f64-cd64-eocd64.zip")
const ZIP64_C = joinpath(THIS_DIR, "single-cd64.zip")
const ZIP64_E = joinpath(THIS_DIR, "single-cd64-eocd64.zip")
const ZIP64_CE = joinpath(THIS_DIR, "single-eocd64.zip")

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
    end
end
