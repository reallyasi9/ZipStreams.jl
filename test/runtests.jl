using TranscodingStreams
using Dates
using LazyArtifacts
using Random
using Test
using ZipStreams

include("common.jl")
include("test_crc32.jl")
include("test_limiters.jl")
include("test_truncated_source.jl")
include("test_validate.jl")

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
                @test_broken read(f, ZipStreams.LocalFileHeader).info == FILE_INFO
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

        # @testset "Simple archive" begin
        #     open(SINGLE_FILE, "r") do f
        #         skip(f, 0x3A)
        #         header = read(f, ZipStreams.CentralDirectoryHeader)
        #         @test header.info == FILE_INFO
        #         @test header.offset == 0
        #         @test header.comment == ""
        #     end
        # end

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
            @test_broken f.info == FILE_INFO
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
                @test_broken f.info == FILE_INFO
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
    @testset "Unzip with unzip_files" begin
        @testset "One file" begin
            mktempdir() do tdir
                filename = "subdir/hello2.txt"
                unzip_files(MULTI_FILE, filename; output_path=tdir, make_path=true)
                @test isfile(joinpath(tdir, filename))
                @test read(joinpath(tdir, filename), String) == FILE_CONTENT
            end
        end
        @testset "File list" begin
            mktempdir() do tdir
                filenames = ["hello1.txt", "subdir/hello3.txt"]
                unzip_files(MULTI_FILE, filenames; output_path=tdir, make_path=true)
                for filename in filenames
                    @test isfile(joinpath(tdir, filename))
                    @test read(joinpath(tdir, filename), String) == FILE_CONTENT
                end
            end
        end
        @testset "All files" begin
            mktempdir() do tdir
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
        end
    end
    @testset "Zip back up with zip_files" begin
        mktempdir() do tdir
            unzip_files(MULTI_FILE; output_path=tdir, make_path=true)

            @testset "One file" begin
                mktemp() do path, io
                    filename = "subdir/hello2.txt"
                    zip_files(path, joinpath(tdir, filename))
                    zipsource(path) do source
                        f = next_file(source)
                        expected_path = join([ZipStreams.strip_dots(relpath(tdir)), filename], ZipStreams.ZIP_PATH_DELIMITER)
                        @test f.info.name == expected_path # zip_files _does_ recreate the path within the ZIP archive
                        @test read(f, String) == FILE_CONTENT
                    end
                end
            end
            
            @testset "File list" begin
                mktemp() do path, io
                    filenames = ["hello1.txt", "subdir/hello3.txt"]
                    zip_files(path, joinpath.(Ref(tdir), filenames))
                    zipsource(path) do source
                        for (f, filename) in zip(source, filenames)
                            expected_path = join([ZipStreams.strip_dots(relpath(tdir)), filename], ZipStreams.ZIP_PATH_DELIMITER)
                            @test f.info.name == expected_path # zip_files _does_ recreate the path within the ZIP archive
                            @test read(f, String) == FILE_CONTENT
                        end
                    end
                end
            end
            
            @testset "All files" begin
                @testset "No recurse directories (default)" begin
                    mktemp() do path, io
                        zip_files(path, readdir(tdir; join=true))
        
                        expected = filter(x -> !isdir(x) && length(split(x.name, ZipStreams.ZIP_PATH_DELIMITER)) == 1, MULTI_INFO)
                        zipsource(path) do archive
                            for (f, info) in zip(archive, expected)
                                expected_path = join([ZipStreams.strip_dots(relpath(tdir)), info.name], ZipStreams.ZIP_PATH_DELIMITER)
                                @test f.info.name == expected_path
                                @test read(f, String) == FILE_CONTENT
                            end
                        end
                    end
                end
                @testset "Recurse directories" begin
                    mktemp() do path, io
                        zip_files(path, tdir; recurse_directories=true)
        
                        expected = filter(x -> !isdir(x) && length(split(x.name, ZipStreams.ZIP_PATH_DELIMITER)) == 1, MULTI_INFO)
                        zipsource(path) do archive
                            for (f, info) in zip(archive, expected)
                                expected_path = join([ZipStreams.strip_dots(relpath(tdir)), info.name], ZipStreams.ZIP_PATH_DELIMITER)
                                @test f.info.name == expected_path
                                @test read(f, String) == FILE_CONTENT
                            end
                        end
                    end
                end
            end
        end
    end
end

@testset "Round trip" begin
    buffer = IOBuffer()
    zipsink(buffer) do sink
        open(sink, "hello.txt") do file
            write(file, FILE_CONTENT)
        end
        open(sink, "subdir/hello_again.txt"; compression = :store, make_path = true) do file
            write(file, FILE_CONTENT)
        end
    end
    
    seekstart(buffer)

    zipsource(buffer) do source
        file = next_file(source)
        @test file.info.name == "hello.txt"
        @test file.info.descriptor_follows == true
        @test read(file, String) == FILE_CONTENT

        file = next_file(source)

        @test file.info.name == "subdir/hello_again.txt"
        @test file.info.descriptor_follows == true
        @test read(file, String) == FILE_CONTENT
    end
end
