import ZipStreams: crc32, bytes_in, bytes_out, CRC32Source, CRC32Sink

const EMPTY_CRC = UInt32(0)
const ZERO_CRC = UInt32(0xD202EF8D)
const FILE_CONTENT_CRC = UInt32(0xFE69594D)

@testset "Raw CRC32" begin
    @test crc32(UInt8[]) == EMPTY_CRC
    @test crc32(UInt8[0]) == ZERO_CRC
    @test crc32(codeunits(FILE_CONTENT)) == FILE_CONTENT_CRC
    @test crc32(FILE_CONTENT) == FILE_CONTENT_CRC

    s = rand(1:length(FILE_CONTENT)-1)
    words = codeunits.([FILE_CONTENT[1:s], FILE_CONTENT[s+1:end]])
    crc = foldl((l, r) -> crc32(r, l), words, init=EMPTY_CRC)
    @test crc32(codeunits(FILE_CONTENT)) == crc
end

@testset "CRC32 streams" begin
    @testset "CRC32Source" begin
        io = IOBuffer(codeunits(FILE_CONTENT); read=true, write=false)
        s = CRC32Source(io)
        @test crc32(s) == EMPTY_CRC
        @test bytes_in(s) == 0
        @test bytes_out(s) == 0
        @test isreadable(s) == true
        @test isreadonly(s) == true
        @test eof(s) == false
        @test read(s, String) == FILE_CONTENT
        @test crc32(s) == FILE_CONTENT_CRC
        @test bytes_in(s) == sizeof(FILE_CONTENT)
        @test bytes_out(s) == sizeof(FILE_CONTENT)
        @test eof(s) == true
    end

    @testset "CRC32Sink" begin
        io = IOBuffer(; read=false, write=true)
        s = CRC32Sink(io)
        @test crc32(s) == EMPTY_CRC
        @test bytes_in(s) == 0
        @test bytes_out(s) == 0
        @test isreadable(s) == false
        @test iswritable(s) == true
        @test eof(s) == true # no reading
        @test write(s, FILE_CONTENT) == sizeof(FILE_CONTENT)
        @test crc32(s) == FILE_CONTENT_CRC
        @test bytes_in(s) == sizeof(FILE_CONTENT)
        @test bytes_out(s) == sizeof(FILE_CONTENT)
        @test take!(io) == codeunits(FILE_CONTENT)
        close(s)
        @test iswritable(s) == false
    end
end