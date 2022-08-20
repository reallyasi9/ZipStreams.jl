using BenchmarkTools
using HTTP
using ZipStreams
using ZipFile # for comparison

const SUITE = BenchmarkGroup()

function count_even(io::IO)
    n = 0
    while !eof(io)
        if read(io, UInt8) % 2 == 0
            n += 1
        end
    end
    n
end

function first_file_stream(f::F, fn::AbstractString) where {F<:Function}
    ZipStreams.open(fn) do zs
        (io, _) = iterate(zs)
        f(io)
    end
end

function first_file_reader(f::F, fn::AbstractString) where {F<:Function}
    zr = ZipFile.Reader(fn)
    f(first(zr.files))
    close(zr)
end

function all_files_stream(f::F, fn::AbstractString) where {F<:Function}
    ZipStreams.open(fn) do zs
        for io in zs
            f(io)
        end
    end
end

function all_files_reader(f::F, fn::AbstractString) where {F<:Function}
    zr = ZipFile.Reader(fn)
    for io in zr.files
        f(io)
    end
    close(zr)
end

function first_file_stream_url(f::F, url::AbstractString) where {F<:Function}
    HTTP.open(:GET, url) do http
        ZipStreams.open(http) do zs
            (io, _) = iterate(zs)
            f(io)
        end
    end
end

function first_file_reader_url(f::F, url::AbstractString) where {F<:Function}
    tmp = tempname()
    HTTP.download(url, tmp)
    zr = ZipFile.Reader(tmp)
    f(first(zr.files))
    close(zr)
end

function all_files_stream_url(f::F, url::AbstractString) where {F<:Function}
    HTTP.open(:GET, url) do http
        ZipStreams.open(http) do zs
            for io in zs
                f(io)
            end
        end
    end
end

function all_files_reader_url(f::F, url::AbstractString) where {F<:Function}
    tmp = tempname()
    HTTP.download(url, tmp)
    zr = ZipFile.Reader(tmp)
    for io in zr.files
        f(io)
    end
    close(zr)
end

const SINGLE_ZIP = joinpath(@__DIR__, "..", "test", "single.zip")
const MULTI_ZIP = joinpath(@__DIR__, "..", "test", "multi.zip")
const REMOTE_ZIP = "https://unicode.org/udhr/assemblies/udhr_txt.zip"

SUITE["single-zip"] = BenchmarkGroup()

SUITE["single-zip"]["first-file"] = BenchmarkGroup()
SUITE["single-zip"]["first-file"]["stream"] = @benchmarkable first_file_stream($count_even, $SINGLE_ZIP)
SUITE["single-zip"]["first-file"]["reader"] = @benchmarkable first_file_reader($count_even, $SINGLE_ZIP)

SUITE["single-zip"]["all-files"] = BenchmarkGroup()
SUITE["single-zip"]["all-files"]["stream"] = @benchmarkable all_files_stream($count_even, $SINGLE_ZIP)
SUITE["single-zip"]["all-files"]["reader"] = @benchmarkable all_files_reader($count_even, $SINGLE_ZIP)

SUITE["multi-zip"] = BenchmarkGroup()
SUITE["multi-zip"]["first-file"] = BenchmarkGroup()
SUITE["multi-zip"]["first-file"]["stream"] = @benchmarkable first_file_stream($count_even, $MULTI_ZIP)
SUITE["multi-zip"]["first-file"]["reader"] = @benchmarkable first_file_reader($count_even, $MULTI_ZIP)

SUITE["multi-zip"]["all-files"] = BenchmarkGroup()
SUITE["multi-zip"]["all-files"]["stream"] = @benchmarkable all_files_stream($count_even, $MULTI_ZIP)
SUITE["multi-zip"]["all-files"]["reader"] = @benchmarkable all_files_reader($count_even, $MULTI_ZIP)

SUITE["remote-zip"] = BenchmarkGroup()
SUITE["remote-zip"]["first-file"] = BenchmarkGroup()
SUITE["remote-zip"]["first-file"]["stream"] = @benchmarkable first_file_stream_url($count_even, $REMOTE_ZIP)
SUITE["remote-zip"]["first-file"]["reader"] = @benchmarkable first_file_reader_url($count_even, $REMOTE_ZIP)

SUITE["remote-zip"]["all-files"] = BenchmarkGroup()
SUITE["remote-zip"]["all-files"]["stream"] = @benchmarkable all_files_stream_url($count_even, $REMOTE_ZIP)
SUITE["remote-zip"]["all-files"]["reader"] = @benchmarkable all_files_reader_url($count_even, $REMOTE_ZIP)
