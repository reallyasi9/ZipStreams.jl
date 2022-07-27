"""
    readle(io, T)

Read and return a value of type T from io in little-endian format.
"""
readle(io::IO, ::Type{T}) where T = htol(read(io, T))

"""
    bytearray(i)

Reinterpret a value `i` as an appropriately sized array of bytes.

See: https://stackoverflow.com/a/70782597/5075720
"""
bytearray(i::T) where T = reinterpret(UInt8, [i])