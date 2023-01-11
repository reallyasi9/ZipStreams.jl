using TranscodingStreams
using Dates
using LazyArtifacts
using Random
using Test
using ZipStreams

include("common.jl")
include("test_crc32.jl")

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
            @test write(f, FILE_CONTENT) == 14
            close(f)
            close(archive; close_sink=false)

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
            @test write(f, FILE_CONTENT) == 14
            close(f)
            close(archive; close_sink=false)

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

            readme = IOBuffer(take!(buffer))
            skip(readme, 4)
            header = read(readme, ZipStreams.LocalFileHeader)
            @test header.info.compressed_size == sizeof(DEFLATED_FILE_CONTENT)
            @test header.info.compression_method == ZipStreams.COMPRESSION_DEFLATE
            @test header.info.crc32 == ZipStreams.crc32(codeunits(FILE_CONTENT))
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

@testset "Convenient extract and archive" begin
    tdir = mktempdir()
    @testset "Unzip with unzip_files" begin
        unzip_files(MULTI_FILE; output_path=tdir)
        for info in MULTI_INFO
            if isdir(info)
                @test isdir(joinpath(tdir, info.name))
            else
                @test isfile(joinpath(tdir, info.name))
                @test read(joinpath(tdir, info.name), String) == FILE_CONTENT
            end
        end
    end
    # @testset "Zip back up with zip_files" begin
    #     archive_name = tempname(tdir)
    #     zip_files(archive_name, readdir(tdir; join=true))

    #     archive = zipsource(archive_name)
    #     # Cannot be streamed
    #     # for (f, info) in zip(archive, filter(x -> !isdir(x), MULTI_INFO))
    #     #     @test !isnothing(f)
    #     #     @test f.info == info
    #     # end
    #     @test_throws ErrorException next_file(archive)
    #     close(archive)
    # end
end

@testset "SentinelLimiter" begin
    # examples from Wikipedia (https://en.wikipedia.org/wiki/Knuth%E2%80%93Morris%E2%80%93Pratt_algorithm)
    @test ZipStreams.SentinelLimiter(UInt8[1,2,3,4,1,2,4]).failure_function == [0,1,1,1,0,1,3,1]
    @test ZipStreams.SentinelLimiter(UInt8[1,2,1,3,1,2,1,3,4]).failure_function == [0,1,0,2,0,1,0,4,3,1]
    @test ZipStreams.SentinelLimiter(UInt8[1,2,1,3,1,2,1,3,1]).failure_function == [0,1,0,2,0,1,0,4,0,4]
    @test ZipStreams.SentinelLimiter(b"PARTICIPATE IN PARACHUTE").failure_function == [0,1,1,1,1,1,1,0,1,3,1,1,1,1,1,0,1,1,4,1,1,1,1,1,1]
end

# @testset "FixedSizeCodec" begin
#     example = b"Hello, Julia!"
#     inbuf = IOBuffer(example)

#     instream = NoopStream(inbuf)
    
#     @test read(TranscodingStream(ZipStreams.FixedSizeReadCodec(5), instream; stop_on_end = true), String) == "Hello"
#     @test read(TranscodingStream(ZipStreams.FixedSizeReadCodec(5), instream; stop_on_end = true), String) == ", Jul"
#     tstream = TranscodingStream(ZipStreams.FixedSizeReadCodec(5), instream; stop_on_end = true)
#     @test read(tstream, String) == "ia!"
#     @test eof(tstream)
#     @test eof(instream)
# end

# @testset "SentinelReadCodec" begin
#     example = b"Hello, qqq Julia! qqq Goodbye, qqq Julia!"
#     inbuf = IOBuffer(example)

#     instream = NoopStream(inbuf)

#     sentinel = collect(b"qqq ")
#     @test read(TranscodingStream(ZipStreams.SentinelReadCodec(sentinel), instream; stop_on_end = true), String) == "Hello, "
#     @test read(TranscodingStream(ZipStreams.SentinelReadCodec(sentinel), instream; stop_on_end = true), String) == ""

#     @test read(instream, 4) == b"qqq "

#     @test read(TranscodingStream(ZipStreams.SentinelReadCodec(sentinel), instream; stop_on_end = true), String) == "Julia! "
#     @test read(TranscodingStream(ZipStreams.SentinelReadCodec(sentinel), instream; stop_on_end = true), String) == ""
#     @test read(TranscodingStream(ZipStreams.SentinelReadCodec(sentinel; skip_first=true), instream; stop_on_end = true), String) == "qqq Goodbye, "
#     @test read(TranscodingStream(ZipStreams.SentinelReadCodec(sentinel), instream; stop_on_end = true), String) == "Julia!"

#     @test eof(instream)
# end