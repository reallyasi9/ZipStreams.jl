import Base: close, iterate, IteratorSize, IteratorEltype, eltype, SizeUnknown, HasEltype

"""
    ZipArchiveOutputStream

A lazy, readable, and somewhat writable representation of a Zip archive.

Zip archive files are optimized for reading from the beginning of the archive
_and_ appending to the end of the archive. Because information about what files
are stored in the archive are recorded at the end of the file, a Zip archive
technically cannot be validated unless the entire file is present, making
reading a Zip archive sequentially from a stream of data technically not
standards-compliant. However, one can build the Central Directory information
while streaming the data and check validity later (if ever) for faster reading
and processing of a Zip archive.

ZipArchiveOutputStream objects are IO objects, allowing you to read data from the
archive byte-by-byte. Because this is usually not useful, ZipArchiveInputStream
objects can also be iterated to produce IO-like ZipFile objects (in archive order)
and can be addressed with Filesystem-like methods to access particular files.

# Examples
"""
mutable struct ZipArchiveOutputStream{S<:IO} <: IO
    source::S

    directory::Vector{CentralDirectoryHeader}
    name_lookup::Dict{String,Int}
end
