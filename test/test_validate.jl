import ZipStreams: zipsource, validate, next_file

@testset "validate" begin
    file_content = collect(b"Hello, Julia!\n")
    @testset "Single file" begin
        single_file = joinpath(ARTIFACT_DIR, "single.zip")
        zipsource(single_file) do source
            @test validate(source) == [file_content]
        end
    end
    @testset "Multi file" begin
        multi_file = joinpath(ARTIFACT_DIR, "multi.zip")
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
        pathological_dd_file = joinpath(ARTIFACT_DIR, "single-dd-pathological.zip")
        zipsource(pathological_dd_file) do source
            @test_throws ErrorException validate(source)
        end
    end
    @testset "Single file partial read" begin
        single_file = joinpath(ARTIFACT_DIR, "single.zip")
        zipsource(single_file) do source
            f = next_file(source)
            @test read(f, Char) == 'H'
            @test validate(f) == file_content[2:end]
            @test validate(source) == Vector{UInt8}[]
        end
    end
    @testset "Bad Local Headers" begin
        @testset "bad CRC-32" begin
            bad_crc_file = joinpath(ARTIFACT_DIR, "bad-crc32-local.zip")
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
        @testset "bad uncompressed size" begin
            bad_uncompressed_file = joinpath(ARTIFACT_DIR, "bad-uncompressed-size-local.zip")
            zipsource(bad_uncompressed_file) do source
                f = next_file(source)
                @test validate(f) == file_content
                @test_throws ErrorException validate(source)
            end
        end
        @testset "bad compressed size short" begin
            bad_compressed_file_short = joinpath(ARTIFACT_DIR, "bad-compressed-size-local-undersize.zip")
            zipsource(bad_compressed_file_short) do source
                f = next_file(source)
                @test_throws ErrorException validate(f)
            end
        end
        @testset "bad compressed size long" begin
            bad_compressed_file_long = joinpath(ARTIFACT_DIR, "bad-compressed-size-local-oversize.zip")
            zipsource(bad_compressed_file_long) do source
                f = next_file(source)
                @test validate(f) == file_content
                @test_throws EOFError validate(source)
            end
        end
    end
    @testset "Bad Central Directory Headers" begin
        @testset "bad CRC-32" begin
            bad_crc_file = joinpath(ARTIFACT_DIR, "bad-crc32-central.zip")
            zipsource(bad_crc_file) do source
                f = next_file(source)
                @test validate(f) == file_content
                @test_throws ErrorException validate(source)
            end
        end
        @testset "missing header" begin
            missing_header = joinpath(ARTIFACT_DIR, "missing-header-central.zip")
            zipsource(missing_header) do source
                f = next_file(source)
                @test validate(f) == file_content
                @test_throws EOFError validate(source)
            end
        end
        @testset "additional header" begin
            additional_header = joinpath(ARTIFACT_DIR, "additional-header-central.zip")
            zipsource(additional_header) do source
                f = next_file(source)
                @test validate(f) == file_content
                @test_broken validate(source) # should throw, but EOCD record is not checked yet
            end
        end
    end
end