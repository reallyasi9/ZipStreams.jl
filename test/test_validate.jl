import ZipStreams: zipsource, validate, next_file

include("common.jl")

@testset "validate" begin
    single_file = joinpath(ARTIFACT_DIR, "single.zip")
    multi_file = joinpath(ARTIFACT_DIR, "multi.zip")
    pathological_dd_file = joinpath(ARTIFACT_DIR, "single-dd-pathological.zip")
    file_content = collect(b"Hello, Julia!\n")
    @testset "Single file" begin
        zipsource(single_file) do source
            @test validate(source) == [file_content]
        end
    end
    @testset "Multi file" begin
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
        zipsource(pathological_dd_file) do source
            @test_throws ErrorException validate(source)
        end
    end
    @testset "Single file partial read" begin
        zipsource(single_file) do source
            f = next_file(source)
            @test read(f, Char) == 'H'
            @test validate(f) == file_content[2:end]
            @test validate(source) == Vector{UInt8}[]
        end
    end
end