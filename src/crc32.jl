const CRC32_INIT = 0x00000000

function crc32(data::Ptr{UInt8}, n::UInt, crc::UInt32=CRC32_INIT)
    return ccall((:crc32, "libz"), Culong, (Culong, Ptr{Cchar}, Cuint), crc, data, n) % UInt32
end

crc32(data::Vector{UInt8}, crc::UInt32=CRC32_INIT) = GC.@preserve data crc32(pointer(data), UInt(length(data)), crc)
crc32(data::Vector, crc::UInt32=CRC32_INIT) = GC.@preserve data crc32(pointer(reinterpret(UInt8, data)), UInt(sizeof(data)), crc)
crc32(s::String, crc::UInt32=CRC32_INIT) = crc32(Vector{UInt8}(s), crc)
