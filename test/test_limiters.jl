import ZipStreams: UnlimitedLimiter, FixedSizeLimiter, SentinelLimiter, bytes_remaining, bytes_consumed, consume!

@testset "UnlimitedLimiter" begin
    buf = IOBuffer(b"Fake content so buffer is not at EOF")
    l = UnlimitedLimiter()
    @test bytes_remaining(l, buf) == typemax(Int)
    @test bytes_consumed(l) == 0
    consume!(l, codeunits(FILE_CONTENT))
    @test bytes_remaining(l, buf) == typemax(Int)
    @test bytes_consumed(l) == sizeof(FILE_CONTENT)
    read(buf)
    @test bytes_remaining(l, buf) == 0
end

@testset "FixedSizeLimiter" begin
    buf = IOBuffer()
    n = 100
    l = FixedSizeLimiter(n)
    @test bytes_remaining(l, buf) == n
    @test bytes_consumed(l) == 0
    consume!(l, codeunits(FILE_CONTENT))
    @test bytes_remaining(l, buf) == n - sizeof(FILE_CONTENT)
    @test bytes_consumed(l) == sizeof(FILE_CONTENT)
    consume!(l, rand(UInt8, n + 1)) # guarantee one more than the remaining bytes
    @test bytes_remaining(l, buf) == 0
    @test bytes_consumed(l) == n
end

const ORIG_CONTENT = UInt8[1,2,3,4]
const SENTINEL = UInt8[222,173,190,239]

@testset "SentinelLimiter" begin
    # one fake sentinel
    content = vcat(ORIG_CONTENT, SENTINEL, ORIG_CONTENT)
    crc = ZipStreams.crc32(content)
    content_len = sizeof(content) % UInt64
    # remember that the CRC and number of bytes are le!
    buf = IOBuffer()
    write(buf, vcat(content, SENTINEL))
    ZipStreams.writele(buf, crc)
    ZipStreams.writele(buf, content_len) # TODO: don't know how to do compressed reads yet
    ZipStreams.writele(buf, content_len)
    seekstart(buf)

    l = SentinelLimiter(SENTINEL)
    @test bytes_remaining(l, buf) == sizeof(ORIG_CONTENT) # to first sentinel
    @test bytes_consumed(l) == 0
    a = read(buf, sizeof(ORIG_CONTENT))
    consume!(l, a)
    @test a == ORIG_CONTENT
    @test bytes_remaining(l, buf) == 1 # one more byte to clear fake sentinel
    @test bytes_consumed(l) == sizeof(ORIG_CONTENT)
    a = read(buf, 1)
    consume!(l, a)
    @test a[1] == SENTINEL[1]
    @test bytes_remaining(l, buf) == sizeof(SENTINEL) + sizeof(ORIG_CONTENT) - 1
    @test bytes_consumed(l) == sizeof(ORIG_CONTENT) + 1
    a = read(buf, bytes_remaining(l, buf))
    consume!(l, a)
    @test bytes_remaining(l, buf) == 0 # sentinel matches
    @test bytes_consumed(l) == content_len

    @testset "failure function construction" begin
        @test SentinelLimiter(b"ABCDABD").failure_function == [-1,0,0,0,-1,0,2,0] .+ 1
        @test SentinelLimiter(b"ABACABABC").failure_function == [-1,0,-1,1,-1,0,-1,3,2,0] .+ 1
        @test SentinelLimiter(b"ABACABABA").failure_function == [-1,0,-1,1,-1,0,-1,3,-1,3] .+ 1
        @test SentinelLimiter(b"PARTICIPATE IN PARACHUTE").failure_function == [-1,0,0,0,0,0,0,-1,0,2,0,0,0,0,0,-1,0,0,3,0,0,0,0,0,0] .+ 1
    end
end