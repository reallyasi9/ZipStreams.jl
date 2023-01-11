using Test
using ZipStreams

include("common.jl")

const EMPTY_CRC = UInt32(0)
const ZERO_CRC = UInt32(0xD202EF8D)
const FILE_CONTENT_CRC = UInt32(0xFE69594D)

@testset "Raw CRC32" begin
    @test ZipStreams.crc32(UInt8[]) == EMPTY_CRC
    @test ZipStreams.crc32(UInt8[0]) == ZERO_CRC
    @test ZipStreams.crc32(codeunits(FILE_CONTENT)) == FILE_CONTENT_CRC

    s = rand(1:length(FILE_CONTENT)-1)
    words = codeunits.([FILE_CONTENT[1:s], FILE_CONTENT[s+1:end]])
    crc = foldl((l, r) -> ZipStreams.crc32(r, l), words, init=EMPTY_CRC)
    @test ZipStreams.crc32(codeunits(FILE_CONTENT)) == crc
end

@testset "CRC32 streams" begin
    @testset "CRC32Source" begin
        io = IOBuffer(codeunits(FILE_CONTENT); read=true, write=false)
        s = ZipStreams.CRC32Source(io)
        @test ZipStreams.crc32(s) == EMPTY_CRC
        @test ZipStreams.bytes_in(s) == 0
        @test ZipStreams.bytes_out(s) == 0
        @test isreadable(s) == true
        @test isreadonly(s) == true
        @test eof(s) == false
        @test read(s, String) == FILE_CONTENT
        @test ZipStreams.crc32(s) == FILE_CONTENT_CRC
        @test ZipStreams.bytes_in(s) == sizeof(FILE_CONTENT)
        @test ZipStreams.bytes_out(s) == sizeof(FILE_CONTENT)
        @test eof(s) == true
    end

    @testset "CRC32Sink" begin
        io = IOBuffer(; read=false, write=true)
        s = ZipStreams.CRC32Sink(io)
        @test ZipStreams.crc32(s) == EMPTY_CRC
        @test ZipStreams.bytes_in(s) == 0
        @test ZipStreams.bytes_out(s) == 0
        @test isreadable(s) == false
        @test iswritable(s) == true
        @test eof(s) == true # no reading
        @test write(s, FILE_CONTENT) == sizeof(FILE_CONTENT)
        @test ZipStreams.crc32(s) == FILE_CONTENT_CRC
        @test ZipStreams.bytes_in(s) == sizeof(FILE_CONTENT)
        @test ZipStreams.bytes_out(s) == sizeof(FILE_CONTENT)
        @test take!(io) == codeunits(FILE_CONTENT)
        close(s)
        @test iswritable(s) == false
    end
end