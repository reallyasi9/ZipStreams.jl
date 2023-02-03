using Dates
import ZipStreams: datetime2msdos, msdos2datetime

@testset "MSDOSDateTime" begin
    # round trip
    test_now = now()
    @test test_now - (test_now |> datetime2msdos |> msdos2datetime) < Second(2)

    # minimum datetime
    @test datetime2msdos(DateTime(1980, 1, 1, 0, 0, 0)) == (0x0021, 0x0000)
    @test msdos2datetime(0x0021, 0x0000) == DateTime(1980, 1, 1, 0, 0, 0)
    # equivalent in Julia
    @test datetime2msdos(DateTime(1979,12,31,24, 0, 0)) == (0x0021, 0x0000)
    # errors (separate minima for day and month)
    @test_throws InexactError datetime2msdos(DateTime(1979,12,31,23,59,59))
    @test_throws ArgumentError msdos2datetime(0x0040, 0x0000)
    @test_throws ArgumentError msdos2datetime(0x0001, 0x0000)

    # maximum datetime
    @test datetime2msdos(DateTime(2107,12,31,23,59,58)) == (0xff9f, 0xbf7d)
    @test msdos2datetime(0xff9f, 0xbf7d) == DateTime(2107,12,31,23,59,58)
    # errors (separate maxima for month/day, hour, minute, and second)
    @test_throws ArgumentError datetime2msdos(DateTime(2107,12,31,24, 0, 0))
    @test_throws ArgumentError msdos2datetime(0xffa0, 0x0000)
    @test_throws ArgumentError msdos2datetime(0xffa0, 0x0000)
    @test_throws ArgumentError msdos2datetime(0x0000, 0xc000)
    @test_throws ArgumentError msdos2datetime(0x0000, 0xbf80)
    @test_throws ArgumentError msdos2datetime(0x0000, 0xbf7e)
end