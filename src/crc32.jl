import Zlib_jll: libz

# TODO: Waiting for the great CRC32.jl package to be added to the general manifest.
# Until then, use a similar interface.

# The CRC32.jl package is released at https://github.com/JuliaIO/CRC32.jl under the MIT
# license, the text of which is included here:
#
# MIT License
#
# Copyright (c) 2022 Steven G. Johnson and contributors
# Copyright (c) 2009-2022 Jeff Bezanson, Stefan Karpinski, Viral B. Shah, and other contributors (https://github.com/JuliaLang/julia/contributors) for Julia CRC32c standard library
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

const CRC32_INIT = UInt32(0)

# contiguous byte arrays compatible with C `unsigned char *` API of zlib
const ByteArray = Union{Array{UInt8},
                        Base.FastContiguousSubArray{UInt8,N,<:Array{UInt8}} where N,
                        Base.CodeUnits{UInt8, String},
                        Base.CodeUnits{UInt8, SubString{String}}}

# for easier calculations if we have direct access to the pointers and the length
unsafe_crc32(data::Ptr{UInt8}, n::Csize_t, crc::UInt32=CRC32_INIT) = ccall((:crc32, libz), Culong, (Culong, Ptr{Cchar}, Csize_t), crc, data, n) % UInt32
crc32(data::ByteArray, crc::UInt32=CRC32_INIT) = @GC.preserve data ccall((:crc32, libz), Culong, (Culong, Ptr{Cchar}, Csize_t), crc, pointer(data), length(data) % Csize_t) % UInt32
function crc32(data::AbstractString, crc::UInt32=CRC32_INIT) 
    a = codeunits(data) # might allocate
    @GC.preserve a ccall((:crc32, libz), Culong, (Culong, Ptr{Cchar}, Csize_t), crc, pointer(a), length(a) % Csize_t) % UInt32
end
crc32(io::IO, nb::Integer, crc::UInt32=CRC32_INIT) = _crc32(io, nb, crc)
crc32(io::IO, crc::UInt32=CRC32_INIT) = _crc32(io, crc)
crc32(io::IOStream, crc::UInt32=CRC32_INIT) = _crc32(io, crc)

function _crc32(io::IO, nb::Integer, crc::UInt32=CRC32_INIT)
    nb < 0 && throw(ArgumentError("number of bytes to checksum must be ≥ 0, got $nb"))
    # use block size 24576=8192*3, since that is the threshold for
    # 3-way parallel SIMD code in the underlying jl_crc32 C function.
    buf = Vector{UInt8}(undef, min(nb, 24576))
    while !eof(io) && nb > 24576
        n = readbytes!(io, buf)
        crc = unsafe_crc32(buf, n % Csize_t, crc)
        nb -= n
    end
    return unsafe_crc32(buf, readbytes!(io, buf, min(nb, length(buf))) % Csize_t, crc)
end

# optimized (copy-free) crc of IOBuffer (see similar crc32c function in base/iobuffer.jl)
const ByteBuffer = Base.GenericIOBuffer{<:ByteArray}
_crc32(buf::ByteBuffer, crc::UInt32=CRC32_INIT) = _crc32(buf, bytesavailable(buf), crc)
function _crc32(buf::ByteBuffer, nb::Integer, crc::UInt32=CRC32_INIT)
    nb < 0 && throw(ArgumentError("number of bytes to checksum must be ≥ 0, got $nb"))
    isreadable(buf) || throw(ArgumentError("read failed, IOBuffer is not readable"))
    nb = min(nb, bytesavailable(buf))
    crc = GC.@preserve buf unsafe_crc32(pointer(buf.data, buf.ptr), nb % Csize_t, crc)
    buf.ptr += nb
    return crc
end