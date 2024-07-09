import ZipStreams: TruncatedSource, UnlimitedLimiter, FixedSizeLimiter, SentinelLimiter, crc32, writele, bytes_consumed

@testset "TruncatedSource" begin
    TRUNC_CONTENT = UInt8[1,2,3,4]
    TRUNC_SENTINEL = UInt8[254,237,190,239]
    CONTENT = vcat(TRUNC_CONTENT, TRUNC_SENTINEL, TRUNC_CONTENT)
    CONTENT_CRC = crc32(CONTENT)
    CONTENT_LEN = sizeof(CONTENT)
    BUFFER = IOBuffer()
    write(BUFFER, CONTENT)
    write(BUFFER, TRUNC_SENTINEL)
    writele(BUFFER, CONTENT_CRC)
    writele(BUFFER, CONTENT_LEN) # don't know how to do compressed lengths yet
    writele(BUFFER, CONTENT_LEN)
    seekstart(BUFFER)
    FULL_CONTENT = read(BUFFER)

    @testset "UnlimitedLimiter" begin
        seekstart(BUFFER)
        t = TruncatedSource(UnlimitedLimiter(), BUFFER)
        @test bytesavailable(t) == sizeof(FULL_CONTENT)
        @test bytes_consumed(t) == 0
        @test read(t) == FULL_CONTENT
        @test bytesavailable(t) == 0
        @test bytes_consumed(t) == sizeof(FULL_CONTENT)
        @test eof(t) == true
    end

    @testset "FixedSizeLimiter" begin
        seekstart(BUFFER)
        n = 10
        t = TruncatedSource(FixedSizeLimiter(n), BUFFER)
        @test bytesavailable(t) == n
        @test bytes_consumed(t) == 0
        a = read(t, 5)
        @test a == FULL_CONTENT[1:5]
        @test bytesavailable(t) == n-5
        @test bytes_consumed(t) == 5
        @test read(t) == FULL_CONTENT[6:n]
        @test bytesavailable(t) == 0
        @test bytes_consumed(t) == n
        @test eof(t) == true
    end

    @testset "SentinelLimiter" begin
        seekstart(BUFFER)
        t = TruncatedSource(SentinelLimiter(TRUNC_SENTINEL), BUFFER)
        @test bytesavailable(t) == sizeof(TRUNC_CONTENT) # first sentinel found
        @test bytes_consumed(t) == 0
        @test read(t, bytesavailable(t)) == TRUNC_CONTENT
        @test eof(t)
        # clear fake sentinel
        t.limiter.skip = true
        @test bytesavailable(t) == 8 # remainder of fake sentinel plus hidden content
        @test eof(t)
    end

    @testset "IO interface" begin
        @testset "Basic pass-through" begin
            seekstart(BUFFER)
            t = TruncatedSource(SentinelLimiter(TRUNC_SENTINEL), BUFFER)
            @test eof(t) == false
            @test isreadable(t) == true
            @test iswritable(t) == false
            @test_throws ErrorException seek(t, 0)
            while !eof(t)
                read(t)
            end
            @test_throws EOFError read(t)
        end

        @testset "skip" begin
            seekstart(BUFFER)
            t = TruncatedSource(SentinelLimiter(TRUNC_SENTINEL), BUFFER)
            skip(t, sizeof(TRUNC_CONTENT) * 2 + sizeof(TRUNC_SENTINEL)) # drops data on the floor.
            @test bytesavailable(t) == 0 # valid real sentinel found, proving limiter is notified properly
            @test eof(t) == true
        end

        @testset "readbytes!" begin
            seekstart(BUFFER)
            t = TruncatedSource(SentinelLimiter(TRUNC_SENTINEL), BUFFER)
            a = UInt8[] # zero size
            @test readbytes!(t, a, sizeof(TRUNC_CONTENT)-1) == sizeof(TRUNC_CONTENT)-1
            @test a == TRUNC_CONTENT[1:end-1]
            @test readbytes!(t, a, 1) == 1
            @test a[1] == TRUNC_CONTENT[end]

            # clear fake sentinel
            t.limiter.skip = true

            # bigly remainder
            resize!(a, 1000)
            n = readbytes!(t, a)
            @test n == sizeof(CONTENT) - sizeof(TRUNC_CONTENT)
            @test a[1:n] == vcat(TRUNC_SENTINEL, TRUNC_CONTENT)
            @test length(a) == 1000
            @test eof(t)
        end

        @testset "readavailable" begin
            seekstart(BUFFER)
            t = TruncatedSource(SentinelLimiter(TRUNC_SENTINEL), BUFFER)
            a = readavailable(t)
            @test a == TRUNC_CONTENT
            # a = readavailable(t)
            # @test a == UInt8[]
            # clear fake sentinel
            t.limiter.skip = true
            a = readavailable(t)
            @test a == vcat(TRUNC_SENTINEL, TRUNC_CONTENT)
            @test eof(t) == true
            @test readavailable(t) == UInt8[]
        end

        @testset "read" begin
            content = "Hello, Julia!\nGoodbye, Julia!"
            buf = IOBuffer(content)
            n = 13
            t = TruncatedSource(FixedSizeLimiter(n), buf)
            @test read(t, String) == content[1:n]

            seekstart(buf)
            t = TruncatedSource(FixedSizeLimiter(n), buf)
            @test read(t, UInt64) == first(reinterpret(UInt64, codeunits(content)[1:8]))

            seekstart(buf)
            t = TruncatedSource(FixedSizeLimiter(n), buf)
            @test read(t, UInt8) == UInt8(content[1])
        end

    end
end
