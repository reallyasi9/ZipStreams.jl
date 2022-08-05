import Base: read, eof, seek

using CodecZlib
using Dates
using TranscodingStreams

"""
    ZipFileInformation

This is an immutable struct representing file information in a Zip archive.

Each file has information stored in two places in a Zip archive: once in a header
preceeding each file stored in the archive, and once again in a "central
directory" at the end of the archive. The format of the information in the two
locations is nearly identicaly, with key differences in record lengths and orders
that prevents a completely shared means of parsing the two.

`ZipFileInformation` structs can be parsed from a Zip archive using the
`Base.read` method for either a `LocalFileHeader` or `CentralDirectoryHeader`
object. The `ZipFileInformation` struct will be present in those structs as the
`info` field.
"""
struct ZipFileInformation
    compression_method::UInt16
    uncompressed_size::UInt64
    compressed_size::UInt64
    last_modified::DateTime
    crc32::UInt32
    offset::UInt64

    name::String
    comment::String

    descriptor_follows::Bool
    utf8::Bool
    zip64::Bool
end

function Base.read(io::IO, ::Type{ZipFileInformation}, signature::UInt32)
    offset = UInt64(position(io)) # NOTE: if central_directory, will be replaced later

    sig = readle(io, UInt32)
    if sig != signature
        error("unexpected signature $(sig), expected $(signature)")
    end
    central_directory = sig == SIG_CENTRAL_DIRECTORY

    version_needed = readle(io, UInt16)
    if version_needed & 0xff > ZIP64_MINIMUM_VERSION
        @warn "Version needed exceeds ISO standard" version_needed
    end

    flags = readle(io, UInt16)
    if (flags & ~(MASK_COMPRESSION_OPTIONS | FLAG_FILE_SIZE_FOLLOWS | FLAG_LANGUAGE_ENCODING)) != 0
        @warn "Unsupported general purpose flags detected" flags
    end
    utf8 = (flags & FLAG_LANGUAGE_ENCODING) != 0
    descriptor_follows = (flags & FLAG_FILE_SIZE_FOLLOWS) != 0
    if descriptor_follows && central_directory
        error("file size signature not allowed to follow central directory record")
    end

    compression_method = readle(io, UInt16)
    if compression_method ∉ (COMPRESSION_STORE, COMPRESSION_DEFLATE)
        error("unimplemented compression method $(compression_method)")
    end

    modtime = readle(io, UInt16)
    moddate = readle(io, UInt16)
    last_modified = msdos2datetime(moddate, modtime)

    crc32 = readle(io, UInt32)
    compressed_size = UInt64(readle(io, UInt32))
    uncompressed_size = UInt64(readle(io, UInt32))

    filename_length = readle(io, UInt16)
    extrafield_length = readle(io, UInt16)

    # This is where the central directory and the local header differ.
    comment_length = UInt16(0)
    if central_directory
        comment_length = readle(io, UInt16)
        
        disk = readle(io, UInt16)
        if disk ∉ (0,1)
            @warn "Archives spanning multiple disks are not supported" disk
        end

        # ignore attributes--don't know what to do with them just yet
        skip(io, 6)

        offset = UInt64(readle(io, UInt32))
    end

    encoding = utf8 ? enc"UTF-8" : enc"IBM437"
    (filename, bytes_read) = readstring(io, filename_length; encoding=encoding)
    if bytes_read != filename_length
        error("EOF when reading file name")
    end

    extra_read = 0
    zip64 = false
    while extra_read < extrafield_length
        ex_signature = readle(io, UInt16)
        ex_length = readle(io, UInt16)
        extra_read += 4

        if ex_signature != HEADER_ZIP64
            skip(io, ex_length)
            extra_read += ex_length
            continue
        end

        # MUST include BOTH original and compressed file size fields in local header per 4.5.3.
        # Can have any number of fields in central directory, but MUST be in the same fixed order.
        nfields = central_directory ? min(ex_length ÷ 8, 3) : 2
        # MUST have 0xffffffff for sizes in original record per 4.5.3.
        if nfields >= 1
            if uncompressed_size != typemax(UInt32)
                error("Zip64-encoded does not signal uncompressed size: expected $(typemax(UInt32)), got $(uncompressed_size)")
            end
            uncompressed_size = readle(io, UInt64)
        end
        if nfields >= 2
            if compressed_size != typemax(UInt32)
                error("Zip64-encoded does not signal compressed size: expected $(typemax(UInt32)), got $(compressed_size)")
            end
            compressed_size = readle(io, UInt64)
        end
        if nfields >= 3
            if offset != typemax(UInt32)
                error("Zip64-encoded does not signal offset: expected $(typemax(UInt32)), got $(offset)")
            end
            offset = readle(io, UInt64)
        end

        zip64 = true
        extra_read += ex_length
        # NOTE: this is an assumption. Nothing in the spec says there can't be 
        # more than one Zip64 header, nor what to do if such a case is found.
        break
    end

    # Skip past additional extra data that went unused
    if extra_read < extrafield_length
        skip(io, extrafield_length - extra_read)
    end

    # comment_length will be zero here if not central directory
    (comment, bytes_read) = readstring(io, comment_length; encoding=encoding)
    if bytes_read != comment_length
        error("EOF when reading comment")
    end

    return ZipFileInformation(
        compression_method,
        uncompressed_size,
        compressed_size,
        last_modified,
        crc32,
        offset,
        filename,
        comment,
        descriptor_follows,
        utf8,
        zip64,
    )

end

"""
    LocalFileHeader

An in-memory representation of the information contained in a Zip file local
header.

See: 4.3.7 of https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
"""
struct LocalFileHeader
    info::ZipFileInformation
end

function Base.read(io::IO, ::Type{LocalFileHeader})
    info = read(io, ZipFileInformation, SIG_LOCAL_FILE)
    return LocalFileHeader(info)
end

"""
    CentralDirectoryHeader

An in-memory representation of the Zip64 Central Directory (CD) record.

See: 4.3.12 of https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT.

# Notes
- ISO/IEC 21320-1 requires disk spanning _not_ be used. However, the disk number
itself is arbitrary.

- APPNOTE specifies version 45 as the minimum version for reading and writing
Zip64 files. ISO/IEC 21320-1 requires that the version number be no greater than
45. The specification is not clear whether applications are allowed to lie about
what version number was used to create the file, but ISO/IEC 21320-1 is clear
that the maximum value for version needed to extract is 45.

- APPNOTE 4.4.2 states that the upper byte of version made by can be ignored
("Software _can_ use this information..."). The specification not clear whether
the upper byte of version needed to extract can be treated the same way. This
implementation ignores the upper byte.

- ISO/IEC 21320-1 requires only certain bits of the general purpose bit flags
are allowed to be set.

- ISO/IEC 21320-1 allows only two types of compression: Store (0) and Deflate
(8).

- Internal and external file attributes are presently not used and set to zero
when writing.

- The specification is not clear whether the presence of Zip64 extra data within
the Central Directory requires that the Zip64 EoCD and Zip64 EoCD locator be
present in the archive (and vice versa). This implementation assumes that the
two different Zip64 data records are independent; however, if any file within
the archive is larger than 2^32-1 bytes or begins past an offset of 2^32-1,
both types of Zip64 data records will be present in the archive due to
requiring a 64-bit field to represent either the file size or file offset, and
the specification that the Central Directory occur after all file data in the
archive.

- The specification is not clear about what to do in the case where there are
multiple extra data records of the same kind. This implementation treats this
case as an error.
"""
struct CentralDirectoryHeader
    info::ZipFileInformation
end

function Base.read(io::IO, ::Type{CentralDirectoryHeader})
    info = read(io, ZipFileInformation, SIG_CENTRAL_DIRECTORY)
    return CentralDirectoryHeader(info)
end

"""
    seek_to_directory(io)

Seek `io` to the first Central Directory record.

If `io` does not have the ability to seek, bytes will be read from `io` using
`read(io)` until the first CD record is found. If seekable, `io` will start at the
end and read backward, which might be more efficient for large files.
"""
function seek_to_directory(io::IO)
    try
        _seek_to_directory_backward(io)
    catch 
        _seek_to_directory_forward(io)
    end
end

# Seeks backward until it finds the directory signature.
# If it detects that Zip64 is needed, it seeks backward again to read the propper
# start of the central directory.
# If it finds the end of central directory record the first time and does not
# detect a Zip64 record, this will seek backward as few as 2 times.
function _seek_to_directory_backward(io::IO)
    # with no comment, the EoCD record will be the last 22 bytes. Try that first.
    seekend(io)
    skip(io, -22)
    try
        # All Zip archives are written in LE format.
        sig = reinterpret(UIt8, [htol(SIG_END_OF_CENTRAL_DIRECTORY)])
        seek_backward_to(io, sig)
    catch
        # No record: seek to the end and return
        seekend(io)
        return
    end
    if eof(io)
        # No record: we're done
        return
    end

    mark(io)
    skip(io, 16) # move to offset
    start_of_cd = UInt64(readle(io, UInt32))
    # Check if Zip64 record not necessary
    if start_of_cd != typemax(UInt32)
        seek(io, start_of_cd)
        unmark(io)
        return
    end

    # Zip64 required
    reset(io)
    skip(io, -20) # beginning of zip64 EoCD locator
    sig = readle(io, UInt32)
    if sig != SIG_ZIP64_CENTRAL_DIRECTORY_LOCATOR
        error("Zip64 end of central directory locator required: expected signature $(SIG_ZIP64_CENTRAL_DIRECTORY_LOCATOR) at position $(position(io)-sizeof(SIG_ZIP64_CENTRAL_DIRECTORY_LOCATOR)), got $(sig)")
    end
    skip(io, 4) # skip disk number
    offset = readle(io, UInt64) # beginning of zip64 EoCD

    seek(io, offset)
    sig = readle(io, UInt32)
    if sig != SIG_ZIP64_END_OF_CENTRAL_DIRECTORY
        error("Zip64 end of central directory required: expected signature $(SIG_ZIP64_END_OF_CENTRAL_DIRECTORY) at position $(position(io)-sizeof(SIG_ZIP64_END_OF_CENTRAL_DIRECTORY)), got $(sig)")
    end
    skip(io, 42) # skip to offset
    start_of_cd = readle(io, UInt64)
    seek(io, start_of_cd)
    return
end

function _seek_to_directory_forward(io::IO)
    # Just seek until the signature is found. Too easy!
    # Just remember that this also consumes the bytes of the header, so move back!
    sentinel = reinterpret(UInt8, [htol(SIG_CENTRAL_DIRECTORY)])
    readuntil(io, sentinel)
    if !eof(io)
        skip(io, -sizeof(SIG_CENTRAL_DIRECTORY))
    end
    return
end

