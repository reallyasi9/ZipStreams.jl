@testitem "validate complete archive" begin
    include("common.jl")

    # every combination of test_file_name should validate properly and not throw
    for (deflate, dd, local64, utf8, cd64, eocd64) in Iterators.product(false:true, false:true, false:true, false:true, false:true, false:true)
        archive_name = test_file_name(deflate, dd, local64, utf8, cd64, eocd64)
        @debug "testing archive $archive_name"
        zipsource(archive_name) do source
            @test is_valid(source)
            @test eof(source)
        end
    end
    for dd in false:true
        archive_name = test_file_name(true, dd, false, false, false, false, "multi")
        @debug "testing archive $archive_name"
        zipsource(archive_name) do source
            @test is_valid(source)
            @test eof(source)
        end
    end
end

@testitem "validate multiple files" begin
    include("common.jl")

    multi_file = test_file_name(true, true, false, false, false, false, "multi")

    zipsource(multi_file) do source
        for file in source
            @debug "testing file $(info(file).name) in archive $archive_name"
            @test is_valid(file)
            @test eof(file)
        end
    end
    zipsource(multi_file) do source
        @debug "testing all files in archive $archive_name at once"
        @test is_valid(source)
        @test eof(source)
    end
    zipsource(multi_file) do source
        @debug "testing partial file read in archive $archive_name"
        file = ZipStreams.next_file(source)
        read(file, UInt8)
        @test is_valid(file)
        @test eof(file)
    end
    zipsource(multi_file) do source
        @debug "testing partial file read, then full archive validation in archive $archive_name"
        file = ZipStreams.next_file(source)
        read(file, UInt8)
        @test is_valid(source) == false
    end

    # non-data descriptor files should work
    multi_non_dd = test_file_name(true, false, false ,false, false, false, "multi")
    zipsource(multi_non_dd) do source
        @debug "testing partial file read, then full archive validation in archive $archive_name"
        file = ZipStreams.next_file(source)
        read(file, UInt8)
        @test is_valid(source)
        @test eof(source)
    end
end

@testitem "pathological files" begin
    include("common.jl")

    pathological_dd_file = test_file_name(false, true, false, false, false, false, "pathological-dd")
    zipsource(pathological_dd_file) do source
        @test is_valid(source) == false
    end

    @debug "single file partial read followed by complete read"
    single_file = test_file_name(true, true, true, true, true, true)
    zipsource(single_file) do source
        f = next_file(source)
        read(f, UInt8)
        @test is_valid(f)
        @test eof(f)
        @test is_valid(source)
        @test eof(source)
    end

    @debug "bad local CRC-32"
    bad_crc_file = test_file_name(true, false, false, false, false, false, "local-bad-crc")
    zipsource(bad_crc_file) do source
        # file is bad
        f = next_file(source)
        @test is_valid(f) == false
    end
    zipsource(bad_crc_file) do source
        for file in source
            read(file)
        end
        # archive is bad
        @test is_valid(source) == false
    end

    @debug "local uncompressed size too large"
    bad_uncompressed_file = test_file_name(true, false, false, false, false, false, "local-usize-too-large")
    zipsource(bad_uncompressed_file) do source
        # file is bad
        f = next_file(source)
        @test is_valid(f) == false
    end
    zipsource(bad_uncompressed_file) do source
        for file in source
            read(file)
        end
        # archive is bad
        @test is_valid(source) == false
    end

    @debug "local uncompressed size too small"
    bad_uncompressed_file = test_file_name(true, false, false, false, false, false, "local-usize-too-small")
    zipsource(bad_uncompressed_file) do source
        # file is bad
        f = next_file(source)
        @test is_valid(f) == false
    end
    zipsource(bad_uncompressed_file) do source
        for file in source
            read(file)
        end
        # archive is bad
        @test is_valid(source) == false
    end

    @debug "local compressed size too large"
    bad_uncompressed_file = test_file_name(true, false, false, false, false, false, "local-csize-too-large")
    zipsource(bad_uncompressed_file) do source
        # file is bad
        f = next_file(source)
        @test is_valid(f) == false
    end
    zipsource(bad_uncompressed_file) do source
        for file in source
            read(file)
        end
        # archive is bad
        @test is_valid(source) == false
    end

    @debug "local compressed size too short"
    bad_uncompressed_file = test_file_name(true, false, false, false, false, false, "local-csize-too-small")
    zipsource(bad_uncompressed_file) do source
        # file is bad
        f = next_file(source)
        # bad compressed size results in a zlib error when reading the file
        @test_throws ErrorException read(f)
        # @test is_valid(f) == false
    end
    zipsource(bad_uncompressed_file) do source
        # note: this error breaks reading because the zlib codec does not read complete information
        for file in source
            @test_throws ErrorException read(file)
        end
        # archive is bad
        @test is_valid(source) == false
    end

    @debug "central bad CRC-32"
    bad_crc_file = test_file_name(true, false, false, false, false, false, "central-bad-crc")
    zipsource(bad_crc_file) do source
        f = next_file(source)
        # good file
        @test is_valid(f)
        # bad archive
        @test is_valid(source) == false
    end
    
    @debug "central missing header"
    missing_header = test_file_name(true, true, false, false, false, false, "missing-header-central")
    zipsource(missing_header) do source
        f = next_file(source)
        # good file
        @test is_valid(f)
        # bad archive
        @test is_valid(source) == false
    end
    
    @debug "central additional header"
    additional_header = test_file_name(true, true, false, false, false, false, "additional-header-central")
    zipsource(additional_header) do source
        f = next_file(source)
        # good file
        @test is_valid(f)
        # bad archive
        @test is_valid(source) == false
    end

    # TODO: EOCD checking
    # TODO: duplicate file name checking
    # TODO: out of order CD
end