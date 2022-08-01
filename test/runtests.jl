using Dates
using Test
using ZipFiles

const EMPTY_FILE = joinpath(dirname(@__FILE__), "empty.zip")
const EOCD_FILE = joinpath(dirname(@__FILE__), "EOCD.zip")
const INFOZIP_FILE = joinpath(dirname(@__FILE__), "infozip.zip")
const ZIP64_FILE = joinpath(dirname(@__FILE__), "zip64.zip")
const ZIP64_2_FILE = joinpath(dirname(@__FILE__), "zip64-2.zip")

@test Any[] == detect_ambiguities(Base, Core, ZipFiles)

@testset "CRC32" begin
    @testset "Array" begin
        @test ZipFiles.crc32(UInt8[]) == 0x00000000
        @test ZipFiles.crc32(UInt8[0]) == 0xd202ef8d
        @test ZipFiles.crc32(UInt8[1, 2, 3, 4]) == 0xb63cfbcd

        @test ZipFiles.crc32(UInt8[5, 6, 7, 8], ZipFiles.crc32(UInt8[1, 2, 3, 4])) ==
            ZipFiles.crc32(UInt8[1, 2, 3, 4, 5, 6, 7, 8]) ==
            0x3fca88c5

        @test ZipFiles.crc32(UInt16[0x0201, 0x0403]) ==
            ZipFiles.crc32(UInt8[1, 2, 3, 4]) ==
            0xb63cfbcd
    end
    @testset "String" begin
        @test ZipFiles.crc32("") == 0x00000000
        @test ZipFiles.crc32("The quick brown fox jumps over the lazy dog") == 0x414fa339

        @test ZipFiles.crc32("Julia!", ZipFiles.crc32("Hello ")) ==
            ZipFiles.crc32("Hello Julia!") ==
            0x424b94c7
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
    s = ZipFiles.TruncatedInputStream(
        IOBuffer("The quick brown fox jumps over the lazy dog"), 15
    )
    @test !eof(s)
    @test bytesavailable(s) == 15

    @test read(s, String) == "The quick brown"
    @test eof(s)
    @test bytesavailable(s) == 0
    @test read(s) == UInt8[]

    s = ZipFiles.TruncatedInputStream(
        IOBuffer("The quick brown fox jumps over the lazy dog"), 100
    )
    @test bytesavailable(s) == 43

    @test read(s, String) == "The quick brown fox jumps over the lazy dog"
    @test eof(s)
    @test bytesavailable(s) == 0
    @test read(s) == UInt8[]
end

@testset "SentinelInputStream" begin
    s = ZipFiles.SentinelInputStream(
        IOBuffer(UInt8[0, 1, 2, 3, 4, 5, 6, 7, 8]), UInt8[4, 5, 6]
    )
    @test !eof(s)
    @test_broken bytesavailable(s) == 4
    @test read(s, UInt8) == 0x00
    @test read(s) == UInt8[1, 2, 3]
    @test eof(s)
    @test read(s) == UInt8[]
    @test_throws EOFError read(s, UInt8)

    s = ZipFiles.SentinelInputStream(
        IOBuffer("The quick brown fox jumps over the lazy dog"), " fox"
    )
    @test_broken bytesavailable(s) == 15
    @test read(s, String) == "The quick brown"
    @test eof(s)
end

@testset "ZipStream" begin
    @testset "ZipFileInformation" begin
        tests = [
            (
                file=EMPTY_FILE,
                expected=ErrorException("unexpected local file header signature $(ZipFiles.SIG_END_OF_CENTRAL_DIRECTORY)"),
            ),
            (
                file=EOCD_FILE,
                expected=[
                    (
                        offset=0,
                        value=ZipFiles.ZipFileInformation(
                            ZipFiles.COMPRESSION_STORE,
                            8856,
                            8856,
                            DateTime(2020, 1, 17, 7, 54, 30),
                            0x9105cddb,
                            "TestA.xlsx",
                            false,
                            false,
                        ),
                    ),
                ]
            ),
            (
                file=INFOZIP_FILE,
                expected=[
                    (
                        offset=0,
                        value=ZipFiles.ZipFileInformation(
                            ZipFiles.COMPRESSION_STORE,
                            0,
                            0,
                            DateTime(2013, 7, 22, 18, 36, 32),
                            0x00000000,
                            "ziptest/",
                            false,
                            false,
                        ),
                    ),
                    (
                        offset=0x42,
                        value=ZipFiles.ZipFileInformation(
                            ZipFiles.COMPRESSION_DEFLATE,
                            60,
                            11,
                            DateTime(2013, 7, 22, 18, 36, 32),
                            0x9925b55b,
                            "ziptest/julia.txt",
                            false,
                            false,
                        ),
                    ),
                    (
                        offset=0x98,
                        value=ZipFiles.ZipFileInformation(
                            ZipFiles.COMPRESSION_STORE,
                            30,
                            30,
                            DateTime(2013, 7, 22, 18, 29, 58),
                            0xcb652a62,
                            "ziptest/info.txt",
                            false,
                            false,
                        ),
                    ),
                    (
                        offset=0x100,
                        value=ZipFiles.ZipFileInformation(
                            ZipFiles.COMPRESSION_STORE,
                            13,
                            13,
                            DateTime(2013, 7, 22, 18, 27, 42),
                            0x01d7afb4,
                            "ziptest/hello.txt",
                            false,
                            false,
                        ),
                    ),
                ],
            ),
        ]

        for test in tests
            open(test.file, "r") do f
                if typeof(test.expected) <: Exception
                    @test_throws test.expected read(f, ZipFiles.ZipFileInformation)
                else
                    for file in test.expected
                        seek(f, file.offset)
                        @test read(f, ZipFiles.ZipFileInformation) == file.value
                    end
                end
            end
        end
    end
end

# function findfile(dir, name)
#     for f in dir.files
#         if f.name == name
#             return f
#         end
#     end
#     nothing
# end

# function fileequals(f, s)
#     read(f, String) == s
# end

# # test a zip file that contains multiple copies of the EOCD hex signature
# dir = ZipFile.Reader(joinpath(dirname(@__FILE__),"EOCD.zip"))
# @test length(dir.files) == 1

# # test a zip file created using Info-Zip
# dir = ZipFile.Reader(joinpath(dirname(@__FILE__), "infozip.zip"))
# @test length(dir.files) == 4

# f = findfile(dir, "ziptest/")
# @test f.method == ZipFile.Store
# @test f.uncompressedsize == 0
# @test fileequals(f, "")

# f = findfile(dir, "ziptest/hello.txt")
# @test fileequals(f, "hello world!\n")

# f = findfile(dir, "ziptest/info.txt")
# @test fileequals(f, "Julia\nfor\ntechnical computing\n")

# f = findfile(dir, "ziptest/julia.txt")
# @test f.method == ZipFile.Deflate
# @test fileequals(f, repeat("Julia\n", 10))

# close(dir)

# # test zip64 files
# # Archives are taken from here: https://go.dev/src/archive/zip/reader_test.go
# dir = ZipFile.Reader(joinpath(dirname(@__FILE__), "zip64.zip"))
# @test length(dir.files) == 1
# f = findfile(dir, "README")
# @test f.uncompressedsize == 36
# @test fileequals(f, "This small file is in ZIP64 format.\n")
# close(dir)

# # a variant of the above file with different Extra fields
# dir = ZipFile.Reader(joinpath(dirname(@__FILE__), "zip64-2.zip"))
# @test length(dir.files) == 1
# f = findfile(dir, "README")
# @test f.uncompressedsize == 36
# @test fileequals(f, "This small file is in ZIP64 format.\n")
# close(dir)

# tmp = mktempdir()
# if Debug
#     println("temporary directory $tmp")
# end

# # write an empty zip file
# dir = ZipFile.Writer("$tmp/empty.zip")
# close(dir)
# dir = ZipFile.Reader("$tmp/empty.zip")
# @test length(dir.files) == 0


# # write and then read back a zip file
# zipdata = [
#     ("hello.txt", "hello world!\n", ZipFile.Store),
#     ("info.txt", "Julia\nfor\ntechnical computing\n", ZipFile.Store),
#     ("julia.txt", "julia\n"^10, ZipFile.Deflate),
#     ("empty1.txt", "", ZipFile.Store),
#     ("empty2.txt", "", ZipFile.Deflate),
# ]
# # 2013-08-16	9:42:24
# modtime = time(Libc.TmStruct(24, 42, 9, 16, 7, 2013-1900, 0, 0, -1))

# dir = ZipFile.Writer("$tmp/hello.zip")
# @test length(string(dir)) > 0
# for (name, data, meth) in zipdata
#     local f = ZipFile.addfile(dir, name; method=meth, mtime=modtime)
#     @test length(string(f)) > 0
#     write(f, data)
# end
# close(dir)

# dir = ZipFile.Reader("$tmp/hello.zip")
# @test length(string(dir)) > 0
# for (name, data, meth) in zipdata
#     local f = findfile(dir, name)
#     @test length(string(f)) > 0
#     @test f.method == meth
#     @test abs(mtime(f) - modtime) < 2
#     @test fileequals(f, data)
# end
# close(dir)


# s1 = "this is an example sentence"
# s2 = ". hello world.\n"
# filename = "$tmp/multi.zip"
# dir = ZipFile.Writer(filename)
# f = ZipFile.addfile(dir, "data"; method=ZipFile.Deflate)
# write(f, s1)
# write(f, s2)
# close(dir)
# dir = ZipFile.Reader(filename)
# @test String(read!(dir.files[1], Array{UInt8}(undef, length(s1)))) == s1
# @test String(read!(dir.files[1], Array{UInt8}(undef, length(s2)))) == s2
# @test eof(dir.files[1])
# @test_throws ArgumentError seek(dir.files[1], 1)
# # Can seek back to start
# seek(dir.files[1], 0)
# # Test readavailable()
# @test String(readavailable(dir.files[1])) == s1*s2
# close(dir)


# data = Any[
#     UInt8(20),
#     Int(42),
#     float(3.14),
#     "julia",
#     rand(5),
#     rand(3, 4),
#     view(rand(10,10), 2:8,2:4),
# ]
# filename = "$tmp/multi2.zip"
# dir = ZipFile.Writer(filename)
# f = ZipFile.addfile(dir, "data"; method=ZipFile.Deflate)
# @test_throws ErrorException read!(f, Array{UInt8}(undef, 1))
# for x in data
#     write(f, x)
# end
# close(dir)

# dir = ZipFile.Reader(filename)
# @test_throws ErrorException write(dir.files[1], UInt8(20))
# for x in data
#     if isa(x, String)
#         @test x == String(read!(dir.files[1], Array{UInt8}(undef, length(x))))
#     elseif isa(x, Array)
#         y = similar(x)
#         y[:] .= 0
#         @test x == read!(dir.files[1], y)
#         @test x == y
#     elseif isa(x, SubArray)
#         continue # Base knows how to write, but not read
#     else
#         @test x == read(dir.files[1], typeof(x))
#     end
# end
# close(dir)

# filename = "$tmp/flush.zip"
# dir = ZipFile.Writer(filename)
# f = ZipFile.addfile(dir, "1")
# write(f, "data-1")
# flush(dir)
# r = ZipFile.Reader(filename)
# @test read(r.files[1], String) == "data-1"
# close(r)
# f = ZipFile.addfile(dir, "2")
# write(f, "data-2")
# flush(dir)
# r = ZipFile.Reader(filename)
# @test read(r.files[1], String) == "data-1"
# @test read(r.files[2], String) == "data-2"
# close(r)
# close(dir)


# if !Debug
#     rm(tmp, recursive=true)
# end

# println("done")
