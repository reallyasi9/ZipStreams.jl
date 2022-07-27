using Test
using ZipFiles

const INFOZIP_FILE = joinpath(dirname(@__FILE__), "infozip.zip")

@test Any[] == detect_ambiguities(Base, Core, ZipFiles)

@testset "Headers" begin
    
    open(INFOZIP_FILE, "r") do f
        ZipFiles.seek_to_eocd_record!(f)
        eocd = ZipFiles.EndOfCentralDirectoryRecord(f)
        @test eocd.signature == Integer(ZipFiles.EndCentralDirectorySignature)
        @test eocd.disk_number == 0
        @test eocd.central_directory_disk == 0
        @test eocd.entries_this_disk == 4
        @test eocd.entries_total == 4
        @test eocd.central_directory_length == 338
        @test eocd.central_directory_offset == 344
        @test eocd.comment_length == 0
        @test isempty(eocd.comment)
    end

end;