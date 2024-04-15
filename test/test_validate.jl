import ZipStreams: zipsource, validate, next_file

@testset "validate" begin
    file_content = collect(b"Hello, Julia!\n")
    # every combination of test_file_name should validate properly and return file_content
    @testset "Complete archive" begin
        for (deflate, dd, local64, utf8, cd64, eocd64) in Iterators.product(false:true, false:true, false:true, false:true, false:true, false:true)
            archive_name = test_file_name(deflate, dd, local64, utf8, cd64, eocd64)
            @testset "$archive_name" begin
                zipsource(archive_name) do source
                    @test validate(source) == [file_content]
                end
            end
        end
        for dd in false:true
            archive_name = test_file_name(true, dd, false, false, false, false, "multi")
            @testset "$archive_name" begin
                zipsource(archive_name) do source
                    @test validate(source) == [file_content, file_content]
                end
            end
        end
    end
    @testset "Multi file" begin
        multi_file = test_file_name(true, true, false, false, false, false, "multi")
        n_files = 0
        @testset "One file at a time" begin
            zipsource(multi_file) do source
                for file in source
                    @test validate(file) == file_content
                    n_files += 1
                end
            end
        end
        @testset "All files at once" begin
            zipsource(multi_file) do source
                @test validate(source) == [file_content for _ in 1:n_files]
            end
        end
    end
    @testset "Pathological single" begin
        pathological_dd_file = test_file_name(false, true, false, false, false, false, "pathological-dd")
        zipsource(pathological_dd_file) do source
            @test validate(source) == [file_content]
        end
    end
    @testset "Single file partial read" begin
        single_file = test_file_name(true, true, true, true, true, true)
        zipsource(single_file) do source
            f = next_file(source)
            @test read(f, Char) == 'H'
            @test validate(f) == file_content[2:end]
            @test validate(source) == Vector{UInt8}[]
        end
    end
    @testset "Bad Local Headers" begin
        @testset "bad CRC-32" begin
            bad_crc_file = test_file_name(true, false, false, false, false, false, "local-bad-crc")
            zipsource(bad_crc_file) do source
                f = next_file(source)
                @test_throws ErrorException validate(f)
            end
            zipsource(bad_crc_file) do source
                f = next_file(source)
                @test read(f) == file_content
                @test validate(f) == UInt8[]
            end
        end
        @testset "uncompressed size too large" begin
            bad_uncompressed_file = test_file_name(true, false, false, false, false, false, "local-usize-too-large")
            zipsource(bad_uncompressed_file) do source
                f = next_file(source)
                @test validate(f) == file_content
                @test_throws ErrorException validate(source)
            end
        end
        @testset "uncompressed size too small" begin
            bad_uncompressed_file = test_file_name(true, false, false, false, false, false, "local-usize-too-small")
            zipsource(bad_uncompressed_file) do source
                f = next_file(source)
                @test validate(f) == file_content
                @test_throws ErrorException validate(source)
            end
        end
        @testset "compressed size too large" begin
            bad_compressed_file_short = test_file_name(true, false, false, false, false, false, "local-csize-too-large")
            zipsource(bad_compressed_file_short) do source
                f = next_file(source)
                # FIXME: validate here should throw.
                # FIXME: For efficiency, a non-DD compressed file trusts the codec to tell it when it is done.
                # No checkes are made to determine if the number of bytes read matches the number of bytes expected.
                @test_broken length(validate(f)) != length(file_content)
            end
        end
        @testset "compressed size too short" begin
            bad_compressed_file_long = test_file_name(true, false, false, false, false, false, "local-csize-too-small")
            zipsource(bad_compressed_file_long) do source
                f = next_file(source)
                @test_throws ErrorException validate(f)
            end
        end
    end
    @testset "Bad Central Directory Headers" begin
        @testset "bad CRC-32" begin
            bad_crc_file = test_file_name(true, false, false, false, false, false, "central-bad-crc")
            zipsource(bad_crc_file) do source
                f = next_file(source)
                @test validate(f) == file_content
                @test_throws ErrorException validate(source)
            end
        end
        @testset "missing header" begin
            missing_header = test_file_name(true, true, false, false, false, false, "missing-header-central")
            zipsource(missing_header) do source
                f = next_file(source)
                @test validate(f) == file_content
                # TODO: Should this be an EOFError?
                @test_throws ErrorException validate(source)
            end
        end
        @testset "additional header" begin
            additional_header = test_file_name(true, true, false, false, false, false, "additional-header-central")
            zipsource(additional_header) do source
                f = next_file(source)
                @test validate(f) == file_content
                @test_skip validate(source) # should throw, but EOCD record is not checked yet
            end
        end
    end
end