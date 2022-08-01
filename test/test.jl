using Test
using ZipFiles

const EMPTY_FILE = joinpath(dirname(@__FILE__), "empty.zip")
const EOCD_FILE = joinpath(dirname(@__FILE__), "EOCD.zip")
const INFOZIP_FILE = joinpath(dirname(@__FILE__), "infozip.zip")
const ZIP64_FILE = joinpath(dirname(@__FILE__), "zip64.zip")
const ZIP64_2_FILE = joinpath(dirname(@__FILE__), "zip64-2.zip")

@test Any[] == detect_ambiguities(Base, Core, ZipFiles)

@testset "Headers" begin
    @testset "End of Central Directory" begin
        tests = [
            (
                file=EMPTY_FILE,
                expected=ZipFiles.EndOfCentralDirectoryRecord(0, 0, 0, 0, ""),
            ),
            (
                file=EOCD_FILE,
                expected=ZipFiles.EndOfCentralDirectoryRecord(
                    0, 0x0001, 0x00000038, 0x000022c0, ""
                ),
            ),
            (
                file=INFOZIP_FILE,
                expected=ZipFiles.EndOfCentralDirectoryRecord(
                    0, 0x0004, 0x00000152, 0x00000158, ""
                ),
            ),
            (
                file=ZIP64_FILE,
                expected=ZipFiles.EndOfCentralDirectoryRecord(
                    0, 0xffff, 0xffffffff, 0xffffffff, ""
                ),
            ),
            (
                file=ZIP64_2_FILE,
                expected=ZipFiles.EndOfCentralDirectoryRecord(
                    0, 0xffff, 0xffffffff, 0xffffffff, ""
                ),
            ),
        ]
        for testdata in tests
            open(testdata.file, "r") do f
                seekend(f)
                ZipFiles.seekbackward(f, ZipFiles.EndCentralDirectorySignature)
                eocd = read(f, ZipFiles.EndOfCentralDirectoryRecord)
                @test eocd == testdata.expected
            end
        end
    end

    @testset "Zip64 End of Central Directory Locator" begin
        exception = ErrorException(
            "signature $(string(ZipFiles.SIG_ZIP64_CENTRAL_DIRECTORY_LOCATOR, base=16)) not found",
        )
        tests = [
            (file=EMPTY_FILE, expected=exception),
            (file=EOCD_FILE, expected=exception),
            (file=INFOZIP_FILE, expected=exception),
            (
                file=ZIP64_FILE,
                expected=ZipFiles.Zip64EndOfCentralDirectoryLocator(0x00, 0x90),
            ),
            (
                file=ZIP64_2_FILE,
                expected=ZipFiles.Zip64EndOfCentralDirectoryLocator(0x00, 0xA8),
            ),
        ]
        for testdata in tests
            open(testdata.file, "r") do f
                seekend(f)
                if typeof(testdata.expected) <: Exception
                    @test_throws testdata.expected ZipFiles.seekbackward(
                        f, ZipFiles.Zip64EndCentralLocatorSignature
                    )
                else
                    ZipFiles.seekbackward(f, ZipFiles.Zip64EndCentralLocatorSignature)
                    eocd64l = read(f, ZipFiles.Zip64EndOfCentralDirectoryLocator)
                    @test eocd64l == testdata.expected
                end
            end
        end
    end

    @testset "Zip64 End of Central Directory" begin
        exception = ErrorException(
            "signature $(string(ZipFiles.SIG_ZIP64_END_OF_CENTRAL_DIRECTORY, base=16)) not found",
        )
        tests = [
            (file=EMPTY_FILE, expected=exception),
            (file=EOCD_FILE, expected=exception),
            (file=INFOZIP_FILE, expected=exception),
            (
                file=ZIP64_FILE,
                expected=ZipFiles.Zip64EndOfCentralDirectoryRecord(
                    0x00, 0x01, 0x48, 0x48
                ),
            ),
            (
                file=ZIP64_2_FILE,
                expected=ZipFiles.Zip64EndOfCentralDirectoryRecord(
                    0x00, 0x01, 0x60, 0x48
                ),
            ),
        ]
        for testdata in tests
            open(testdata.file, "r") do f
                seekend(f)
                if typeof(testdata.expected) <: Exception
                    @test_throws testdata.expected ZipFiles.seekbackward(
                        f, ZipFiles.Zip64EndCentralDirectorySignature
                    )
                else
                    ZipFiles.seekbackward(f, ZipFiles.Zip64EndCentralDirectorySignature)
                    eocd64 = read(f, ZipFiles.Zip64EndOfCentralDirectoryRecord)
                    @test eocd64 == testdata.expected
                end
            end
        end
    end

end;