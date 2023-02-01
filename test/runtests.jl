using TranscodingStreams
using Dates
using LazyArtifacts
using Random
using Test
using ZipStreams

@test Any[] == detect_ambiguities(Base, Core, ZipStreams)

include("common.jl")
include("test_datetime.jl")
include("test_crc32.jl")
include("test_limiters.jl")
include("test_truncated_source.jl")
include("test_validate.jl")

# TODO: figure out how to test headers

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
            @test header.info.compressed_size == sizeof(DEFLATED_FILE_BYTES)
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
            for fn in (EMPTY_FILE, EMPTY_FILE_EOCD64)
                @testset "$fn" begin
                    zipsource(EMPTY_FILE) do archive
                        f = next_file(archive)
                        @test isnothing(f)
                    end
                end
            end
        end

        @testset "Simple archive" begin
            for (deflate, dd, local64, utf8, cd64, eocd64) in Iterators.product(false:true, false:true, false:true, false:true, false:true, false:true)
                archive_name = test_file_name(deflate, dd, local64, utf8, cd64, eocd64)
                file_info = test_file_info(deflate, dd, local64, utf8)
                @testset "$archive_name" begin
                    zipsource(archive_name) do archive
                        f = next_file(archive)
                        @test !isnothing(f)
                        @test ZipStreams._is_consistent(f.info, file_info)
                        f = next_file(archive)
                        @test isnothing(f)
                    end
                end
            end
        end

        @testset "Multi archive" begin
            multi_file = test_file_name(true, true, false, false, false, false, "multi")
            first_file_info = test_file_info(true, true, false, false)
            second_file_info = test_file_info(true, true, false, false, "subdir")
            @testset "$multi_file" begin
                zipsource(multi_file) do archive
                    f = next_file(archive)
                    @test !isnothing(f)
                    @test ZipStreams._is_consistent(f.info, first_file_info)
                    f = next_file(archive)
                    @test !isnothing(f)
                    @test ZipStreams._is_consistent(f.info, second_file_info)
                    @test isnothing(next_file(archive))
                end
            end
        end
    end

    @testset "iterator" begin
        @testset "Empty archive" begin
            for fn in (EMPTY_FILE, EMPTY_FILE_EOCD64)
                @testset "$fn" begin
                    zipsource(EMPTY_FILE) do archive
                        for f in archive
                            @test false # must not happen
                        end
                        @test isnothing(next_file(archive))
                    end
                end
            end
        end

        @testset "Simple archive" begin
            for (deflate, dd, local64, utf8, cd64, eocd64) in Iterators.product(false:true, false:true, false:true, false:true, false:true, false:true)
                archive_name = test_file_name(deflate, dd, local64, utf8, cd64, eocd64)
                file_info = test_file_info(deflate, dd, local64, utf8)
                @testset "$archive_name" begin
                    zipsource(archive_name) do archive
                        for f in archive
                            ZipStreams._is_consistent(f.info, file_info)
                        end
                        @test isnothing(next_file(archive))
                    end
                end
            end
        end

        @testset "Multi archive" begin
            multi_file = test_file_name(true, true, false, false, false, false, "multi")
            file_infos = [
                test_file_info(true, true, false, false),
                test_file_info(true, true, false, false, "subdir"),
            ]
            @testset "$multi_file" begin
                zipsource(multi_file) do archive
                    for (i,f) in zip(file_infos, archive)
                        @test ZipStreams._is_consistent(f.info, i)
                    end
                    @test isnothing(next_file(archive))
                end
            end
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
    filename = test_file_name(true, true, false, false, false, false, "multi")
    zipsink(buffer) do sink
        open(filename, "r") do f
            open(sink, "test.zip") do zf
                @test write(zf, f) == filesize(f)
            end
        end
    end
end

@testset "Convenient extract and archive" begin
    @testset "Unzip with unzip_files" begin
        multi_file = test_file_name(true, true, false, false, false, false, "multi")
        @testset "One file in subdir" begin
            mktempdir() do tdir
                filename = "subdir/hello.txt"
                unzip_files(multi_file, filename; output_path=tdir, make_path=true)
                @test isfile(joinpath(tdir, filename))
                @test read(joinpath(tdir, filename), String) == FILE_CONTENT
            end
        end
        @testset "File list" begin
            mktempdir() do tdir
                filenames = ["hello.txt", "subdir/hello.txt"]
                unzip_files(multi_file, filenames; output_path=tdir, make_path=true)
                for filename in filenames
                    @test isfile(joinpath(tdir, filename))
                    @test read(joinpath(tdir, filename), String) == FILE_CONTENT
                end
            end
        end
        @testset "All files" begin
            mktempdir() do tdir
                filenames = ["hello.txt", "subdir/hello.txt"]
                unzip_files(multi_file; output_path=tdir, make_path=true)
                for filename in filenames
                    @test isfile(joinpath(tdir, filename))
                    @test read(joinpath(tdir, filename), String) == FILE_CONTENT
                end
            end
        end
    end
    @testset "Zip back up with zip_files" begin
        multi_file = test_file_name(true, true, false, false, false, false, "multi")
        mktempdir() do tdir
            unzip_files(multi_file; output_path=tdir, make_path=true)

            @testset "One file in subdir" begin
                mktemp() do path, io
                    filename = "subdir/hello.txt"
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
                    filenames = ["hello.txt", "subdir/hello.txt"]
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
