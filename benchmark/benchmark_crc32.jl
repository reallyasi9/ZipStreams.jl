using BenchmarkTools
using Random

using ZipStreams

include("common.jl")

SUITE["crc32"] = BenchmarkGroup()

test_array = rand(Xoshiro(42), UInt8, 10^5)

unsafe_crc32(arr::Vector{UInt8}) = @GC.preserve arr ZipStreams.unsafe_crc32(pointer(arr), length(arr) % UInt)
SUITE["crc32"]["unsafe_crc32"] = @benchmarkable unsafe_crc32($test_array)

SUITE["crc32"]["crc32_array"] = @benchmarkable ZipStreams.crc32($test_array)

test_codeunits = codeunits(String(test_array))
SUITE["crc32"]["crc32_codeunits"] = @benchmarkable ZipStreams.crc32($test_codeunits)