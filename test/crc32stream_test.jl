using Test
using ZipFiles

@testset "CRC32" begin
    @testset "Array" begin
        @test ZipFiles.crc32(UInt8[]) == 0x00000000
        @test ZipFiles.crc32(UInt8[0]) == 0xd202ef8d
        @test ZipFiles.crc32(UInt8[1, 2, 3, 4]) == 0xb63cfbcd

        @test ZipFiles.crc32(UInt8[5, 6, 7, 8], ZipFiles.crc32(UInt8[1, 2, 3, 4])) == ZipFiles.crc32(UInt8[1, 2, 3, 4, 5, 6, 7, 8]) == 0x3fca88c5
    end
    @testset "String" begin
        @test ZipFiles.crc32("") == 0x00000000
        @test ZipFiles.crc32("The quick brown fox jumps over the lazy dog") == 0x414fa339

        @test ZipFiles.crc32("Julia!", ZipFiles.crc32("Hello ")) == ZipFiles.crc32("Hello Julia!") == 0x424b94c7
    end
end

@testset "CRC32InputStream" begin
    s = ZipFiles.CRC32InputStream(IOBuffer(UInt8[0]))
    @test s.crc32 == 0x00000000
    @test s.bytes_read == 0
    @test !eof(s)
    @test bytesavailable(s) == 1

    read(s)
    @test s.crc32 == 0xd202ef8d
    @test s.bytes_read == 1
    @test eof(s)
    @test bytesavailable(s) == 0
    
    @test isempty(read(s))

    s = ZipFiles.CRC32InputStream(IOBuffer(UInt8[1, 2, 3, 4, 5, 6, 7, 8]))
    @test read(s, 4) == UInt8[1, 2, 3, 4]
    @test s.crc32 == 0xb63cfbcd
    @test s.bytes_read == 4
    @test !eof(s)
    @test bytesavailable(s) == 4

    @test read(s, 4) == UInt8[5, 6, 7, 8]
    @test s.crc32 == 0x3fca88c5
    @test s.bytes_read == 8
    @test eof(s)
    @test bytesavailable(s) == 0
end

@testset "TruncatedInputStream" begin
    s = ZipFiles.TruncatedInputStream(IOBuffer("The quick brown fox jumps over the lazy dog"), 15)
    @test !eof(s)
    @test bytesavailable(s) == 15

    @test read(s, String) == "The quick brown"
    @test eof(s)
    @test bytesavailable(s) == 0
    @test read(s) == UInt8[]

    s = ZipFiles.TruncatedInputStream(IOBuffer("The quick brown fox jumps over the lazy dog"), 100)
    @test bytesavailable(s) == 43

    @test read(s, String) == "The quick brown fox jumps over the lazy dog"
    @test eof(s)
    @test bytesavailable(s) == 0
    @test read(s) == UInt8[]
end

@testset "SentinelInputStream" begin
    s = ZipFiles.SentinelInputStream(IOBuffer(UInt8[0, 1, 2, 3, 4, 5, 6, 7, 8]), UInt8[4, 5, 6])
    @test !eof(s)
    @test_broken bytesavailable(s) == 4
    @test read(s, UInt8) == 0x00
    @test read(s) == UInt8[1, 2, 3]
    @test eof(s)
    @test read(s) == UInt8[]
    @test_throws EOFError read(s, UInt8)

    s = ZipFiles.SentinelInputStream(IOBuffer("The quick brown fox jumps over the lazy dog"), " fox")
    @test_broken bytesavailable(s) == 15
    @test read(s, String) == "The quick brown"
    @test eof(s)
end