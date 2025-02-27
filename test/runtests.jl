using TestItemRunner

@testitem "Ambiguities" begin
    @test isempty(detect_ambiguities(Base, Core, ZipStreams))
end

# include("test_datetime.jl")
# include("test_crc32.jl")
# include("test_truncated_source.jl")
include("test_validate.jl")

# TODO: figure out how to test headers


@testitem "Empty input archive construction" begin
    buffer = IOBuffer()
    archive = zipsink(buffer)
    close(archive)
    @test true # must not fail to get here
end

@testitem "Write input archive files: single file, uncompressed" tags = [:sink] begin
    include("common.jl")

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

@testitem "Write input archive files: single file, compressed" tags = [:sink] begin
    include("common.jl")

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
@testitem "Write input archive files: single file, subdirectory (make_path=false, default)" tags =
    [:sink] begin
    buffer = IOBuffer()
    archive = zipsink(buffer)
    @test_throws ArgumentError open(archive, "subdir/hello.txt")
    @test_throws ArgumentError open(archive, "subdir/hello.txt"; make_path=false)
    close(archive)
end
@testitem "Write input archive files: single file, subdirectory (make_path=true)" tags =
    [:sink] begin
    include("common.jl")

    buffer = IOBuffer()
    archive = zipsink(buffer)
    f = open(archive, "subdir/hello.txt"; make_path=true)
    write(f, FILE_CONTENT)
    close(f)
    close(archive)
    @test true # must not fail to get here
end
@testitem "Write input archive files: write at once" tags = [:sink] begin
    include("common.jl")

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


@testitem "Empty archive next_file" tags = [:source] begin
    include("common.jl")

    for fn in (EMPTY_FILE, EMPTY_FILE_EOCD64)
        zipsource(EMPTY_FILE) do archive
            f = next_file(archive)
            @test isnothing(f)
        end
    end
end

@testitem "Simple archive next_file" tags = [:source] begin
    include("common.jl")

    for (deflate, dd, local64, utf8, cd64, eocd64) in Iterators.product(
        false:true,
        false:true,
        false:true,
        false:true,
        false:true,
        false:true,
    )
        archive_name = test_file_name(deflate, dd, local64, utf8, cd64, eocd64)
        fi = test_file_info(deflate, dd, local64, utf8)
        zipsource(archive_name) do archive
            f = next_file(archive)
            @test !isnothing(f)
            @test ZipStreams.is_consistent(info(f), fi; check_sizes=false)
            f = next_file(archive)
            @test isnothing(f)
        end
    end
end

@testitem "Multi archive next_file" tags = [:source] begin
    include("common.jl")

    multi_file = test_file_name(true, true, false, false, false, false, "multi")
    first_file_info = test_file_info(true, true, false, false)
    second_file_info = test_file_info(true, true, false, false, "subdir")
    zipsource(multi_file) do archive
        f = next_file(archive)
        @test !isnothing(f)
        @test ZipStreams.is_consistent(info(f), first_file_info; check_sizes=false)
        f = next_file(archive)
        @test !isnothing(f)
        @test ZipStreams.is_consistent(info(f), second_file_info; check_sizes=false)
        @test isnothing(next_file(archive))
    end
end

@testitem "Empty archive iterator" tags = [:source] begin
    include("common.jl")

    for fn in (EMPTY_FILE, EMPTY_FILE_EOCD64)
        zipsource(EMPTY_FILE) do archive
            for f in archive
                @test false # must not happen
            end
            @test isnothing(next_file(archive))
        end
    end
end

@testitem "Simple archive iterator" tags = [:source] begin
    include("common.jl")

    for (deflate, dd, local64, utf8, cd64, eocd64) in Iterators.product(
        false:true,
        false:true,
        false:true,
        false:true,
        false:true,
        false:true,
    )
        archive_name = test_file_name(deflate, dd, local64, utf8, cd64, eocd64)
        fi = test_file_info(deflate, dd, local64, utf8)

        zipsource(archive_name) do archive
            for f in archive
                @test ZipStreams.is_consistent(info(f), fi; check_sizes=false)
            end
            @test isnothing(next_file(archive))
        end

    end
end

@testitem "Multi archive iterator" tags = [:source] begin
    include("common.jl")

    multi_file = test_file_name(true, true, false, false, false, false, "multi")
    file_infos = [
        test_file_info(true, true, false, false),
        test_file_info(true, true, false, false, "subdir"),
    ]

    zipsource(multi_file) do archive
        for (i, f) in zip(file_infos, archive)
            @test ZipStreams.is_consistent(info(f), i; check_sizes=false)
        end
        @test isnothing(next_file(archive))
    end

end

@testitem "Mock stream IO" tags = [:utils] begin
    include("common.jl")

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
    # note that the source does not need to be closed

end

@testitem "Stream-to-Archive IO" tags = [:sink] begin
    include("common.jl")

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

@testitem "unzip_files one file in subdir" tags = [:utils] begin
    include("common.jl")

    multi_file = test_file_name(true, true, false, false, false, false, "multi")

    mktempdir(pwd()) do tdir
        filename = "subdir/hello.txt"
        unzip_files(multi_file, filename; output_path=tdir, make_path=true)
        @test isfile(joinpath(tdir, filename))
        @test read(joinpath(tdir, filename), String) == FILE_CONTENT
    end
end

@testitem "unzip_files file list" tags = [:utils] begin
    include("common.jl")

    multi_file = test_file_name(true, true, false, false, false, false, "multi")

    mktempdir(pwd()) do tdir
        filenames = ["hello.txt", "subdir/hello.txt"]
        unzip_files(multi_file, filenames; output_path=tdir, make_path=true)
        for filename in filenames
            @test isfile(joinpath(tdir, filename))
            @test read(joinpath(tdir, filename), String) == FILE_CONTENT
        end
    end
end

@testitem "unzip_files all files" tags = [:utils] begin
    include("common.jl")

    multi_file = test_file_name(true, true, false, false, false, false, "multi")

    mktempdir(pwd()) do tdir
        filenames = ["hello.txt", "subdir/hello.txt"]
        unzip_files(multi_file; output_path=tdir, make_path=true)
        for filename in filenames
            @test isfile(joinpath(tdir, filename))
            @test read(joinpath(tdir, filename), String) == FILE_CONTENT
        end
    end
end

@testitem "zip_files one file in subdir" tags = [:utils] begin
    include("common.jl")

    multi_file = test_file_name(true, true, false, false, false, false, "multi")

    mktempdir(pwd()) do tdir
        unzip_files(multi_file; output_path=tdir, make_path=true)

        mktemp(pwd()) do path, io
            filename = "subdir/hello.txt"
            zip_files(path, joinpath(tdir, filename))
            zipsource(path) do source
                f = next_file(source)
                expected_path = join([ZipStreams.strip_dots(relpath(normpath(realpath(tdir)), normpath(pwd()))), filename], ZipStreams.ZIP_PATH_DELIMITER)
                @test info(f).name == expected_path # zip_files _does_ recreate the path within the ZIP archive
                @test read(f, String) == FILE_CONTENT
            end
        end
    end
end

@testitem "zip_files file list" tags = [:utils] begin
    include("common.jl")

    multi_file = test_file_name(true, true, false, false, false, false, "multi")

    mktempdir(pwd()) do tdir
        unzip_files(multi_file; output_path=tdir, make_path=true)
        mktemp(pwd()) do path, io
            filenames = ["hello.txt", "subdir/hello.txt"]
            zip_files(path, joinpath.(Ref(tdir), filenames))
            zipsource(path) do source
                for (f, filename) in zip(source, filenames)
                    expected_path = join([ZipStreams.strip_dots(relpath(normpath(realpath(tdir)), normpath(pwd()))), filename], ZipStreams.ZIP_PATH_DELIMITER)
                    @test info(f).name == expected_path # zip_files _does_ recreate the path within the ZIP archive
                    @test read(f, String) == FILE_CONTENT
                end
            end
        end
    end
end

@testitem "zip_files with file options" tags = [:utils] begin
    include("common.jl")

    multi_file = test_file_name(true, true, false, false, false, false, "multi")

    mktempdir(pwd()) do tdir
        unzip_files(multi_file; output_path=tdir, make_path=true)
        mktemp(pwd()) do path, io
            filenames = ["hello.txt", "subdir/hello.txt"]
            test_filename = joinpath(tdir, "hello.txt")
            file_kwargs = Dict(test_filename => (compression=:deflate, level=1))
            zip_files(path, joinpath.(Ref(tdir), filenames); compression=:store)
            zipsource(path) do source
                for (f, filename) in zip(source, filenames)
                    if filename == test_filename
                        @test info(f).compression_method == 0x0008 # deflate
                    else
                        @test info(f).compression_method == 0x0000 # store
                    end
                end
            end
        end
    end
end

@testitem "zip_files entire directory, no recurse (default)" tags = [:utils] begin
    include("common.jl")

    multi_file = test_file_name(true, true, false, false, false, false, "multi")

    mktempdir(pwd()) do tdir
        unzip_files(multi_file; output_path=tdir, make_path=true)
        mktemp(pwd()) do path, io
            filenames = ["hello.txt"]
            zip_files(path, tdir)
            zipsource(path) do archive
                for (f, filename) in zip(archive, filenames)
                    expected_path = join([ZipStreams.strip_dots(relpath(normpath(realpath(tdir)), normpath(pwd()))), filename], ZipStreams.ZIP_PATH_DELIMITER)
                    @test info(f).name == expected_path
                    @test read(f, String) == FILE_CONTENT
                end
            end
        end
    end
end

@testitem "zip_files entire directory, recurse" tags = [:utils] begin
    include("common.jl")

    multi_file = test_file_name(true, true, false, false, false, false, "multi")

    mktempdir(pwd()) do tdir
        unzip_files(multi_file; output_path=tdir, make_path=true)
        mktemp(pwd()) do path, io
            filenames = ["hello.txt", "subdir/hello.txt"]
            zip_files(path, tdir; recurse_directories=true)
            zipsource(path) do archive
                for (f, filename) in zip(archive, filenames)
                    expected_path = join([ZipStreams.strip_dots(relpath(normpath(realpath(tdir)), normpath(pwd()))), filename], ZipStreams.ZIP_PATH_DELIMITER)
                    @test info(f).name == expected_path
                    @test read(f, String) == FILE_CONTENT
                end
            end
        end
    end
end

@testitem "Round trip" tags = [:sink, :source] begin
    include("common.jl")

    buffer = IOBuffer()
    zipsink(buffer) do sink
        open(sink, "hello.txt") do file
            write(file, FILE_CONTENT)
        end
        open(sink, "subdir/hello_again.txt"; compression=:store, make_path=true) do file
            write(file, FILE_CONTENT)
        end
    end

    seekstart(buffer)

    zipsource(buffer) do source
        file = next_file(source)
        @test info(file).name == "hello.txt"
        @test info(file).descriptor_follows == true
        @test read(file, String) == FILE_CONTENT

        file = next_file(source)

        @test info(file).name == "subdir/hello_again.txt"
        @test info(file).descriptor_follows == true
        @test read(file, String) == FILE_CONTENT
    end
end

@testitem "Canterbury Corpus streaming round trips" tags = [:sink, :source] begin
    include("common.jl")

    cc_path = artifact"CanterburyCorpus"
    cc_files = readdir(cc_path; sort=true, join=true)
    buffer = IOBuffer()
    zipsink(buffer) do sink
        for fn in cc_files
            @debug "writing" sink fn basename(fn)
            open(sink, basename(fn)) do file
                open(fn, "r") do io
                    nb = write(file, io)
                    @debug "wrote" nb
                end
            end
        end
    end

    seekstart(buffer)

    zipsource(buffer) do source
        for fn in cc_files
            file = next_file(source)
            @debug "reading" source info(file).name fn
            @test info(file).name == basename(fn)

            truth = read(fn)
            content = read(file)
            @debug "testing" length(truth) length(content)
            @test content == truth
        end
    end
end

# @test "Canterbury Corpus compression levels" begin

# end

@run_package_tests verbose = true