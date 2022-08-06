using BenchmarkTools
using Random
using ZipFiles

const SUITE = BenchmarkGroup()

function signature_at_location(arr, sig, loc)
    cpy = copy(arr)
    cpy[loc:loc+length(sig)-1] .= sig
    buf = IOBuffer(cpy)
    seekend(buf)
end
const rng = Xoshiro(42)
const test_io = UInt8.(rand(rng, 'a':'z', 1_000_000))
const signature = UInt8.(['X'])

SUITE["seek_backward_to"] = BenchmarkGroup()
SUITE["seek_backward_to"]["ending"] = @benchmarkable ZipFiles.seek_backward_to(x, $signature) setup=(x = $(signature_at_location(test_io, signature, 1_000_000)))
SUITE["seek_backward_to"]["middle"] = @benchmarkable ZipFiles.seek_backward_to(x, $signature) setup=(x = $(signature_at_location(test_io, signature, 500_000)))
SUITE["seek_backward_to"]["beginning"] = @benchmarkable ZipFiles.seek_backward_to(x, $signature) setup=(x = $(signature_at_location(test_io, signature, 1)))
SUITE["seek_backward_to"]["random"] = @benchmarkable ZipFiles.seek_backward_to(x, $signature) setup=(x = $(signature_at_location(test_io, signature, rand(rng, 1:length(test_io)))))
