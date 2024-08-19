import Base: eof, isdir, seek, read, show, write

using Dates

"""
    iszipsignature_h(highbytes)

Check if the 2 bytes given are a valid second half of a 4-byte ZIP header
signature.
"""
function iszipsignature_h(highbytes::UInt16)
    return highbytes in (
        SIG_LOCAL_FILE_H,
        SIG_EXTRA_DATA_H,
        SIG_CENTRAL_DIRECTORY_H,
        SIG_DIGITAL_SIGNATURE_H,
        SIG_END_OF_CENTRAL_DIRECTORY_H,
        SIG_ZIP64_CENTRAL_DIRECTORY_LOCATOR_H.SIG_ZIP64_END_OF_CENTRAL_DIRECTORY_H,
    )
end


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
    extra_field_size::UInt16

    name::String

    descriptor_follows::Bool
    utf8::Bool
    zip64::Bool
end

# Info-ZIP project, see ftp://ftp.info-zip.org/pub/infozip/license.html
const COMPRESSION_INFO_FORMAT = String[
    "stor",
    "shrk",
    "re:1",
    "re:2",
    "re:3",
    "re:4",
    "impl",
    "tokn",
    "defl",
    "df64",
    "dcli",
    "bzp2",
    "lzma",
    "ters",
    "lz77",
    "wavp",
    "ppmd",
    "????",
]
function Base.show(io::IO, ::MIME"text/plain", zi::ZipFileInformation)
    # TODO: status bits: drwxahs or drwxrwxrwx
    # all: directory, readable, writable, executable
    # windows: archive, hidden, system
    # unix/mac: group r/w/x, user r/w/x
    if isdir(zi)
        print(io, "dir  ")
    else
        print(io, "file ")
    end
    # TODO: version used to store: DD.D
    # TODO: string stating file system type
    # original size: at least 8 digits wide
    @printf(io, "%8d ", zi.uncompressed_size)
    # TODO: text (t) or binary (b), encrypted=capitalized
    # print(io, "?")
    # TODO: extra data: none (-), extended local header only (l),
    #   extra field only (x), both (X)
    if zi.zip64
        print(io, "z64 ")
    else
        print(io, "--- ")
    end
    if zi.descriptor_follows
        print(io, "lhx ")
    else
        print(io, "--- ")
    end
    # compressed size: at least 8 digits wide
    @printf(io, "%8d ", zi.compressed_size)
    # compression type
    if zi.compression_method >= length(COMPRESSION_INFO_FORMAT)
        print(io, "???? ")
    else
        print(io, COMPRESSION_INFO_FORMAT[zi.compression_method+1], " ")
    end
    # last modified date and time
    print(io, Dates.format(zi.last_modified, dateformat"dd-uuu-yy HH:MM:SS "))

    # extra: CRC32
    @printf(io, "0x%08x ", zi.crc32)
    # name with directory info
    print(io, zi.name)
end

function Base.isdir(info::ZipFileInformation)
    return info.compressed_size == 0 && info.uncompressed_size == 0 && endswith(info.name, ZIP_PATH_DELIMITER)
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

# Expected size of the header in bytes
function Base.sizeof(header::LocalFileHeader)
    return 30 + sizeof(header.info.name) + header.info.extra_field_size
end

function _read_version_needed(io::IO)
    version_needed = readle(io, UInt16)
    if version_needed & 0xff > ZIP64_MINIMUM_VERSION
        @warn "Version needed exceeds ISO standard" version_needed
    end
    return version_needed
end

function _read_general_purpose_flags(io::IO)
    flags = readle(io, UInt16)
    if (
        flags &
        ~(MASK_COMPRESSION_OPTIONS | FLAG_FILE_SIZE_FOLLOWS | FLAG_LANGUAGE_ENCODING)
    ) != 0
        @warn "Unsupported general purpose flags detected" flags
    end
    return flags
end

function _read_compression_method(io::IO)
    compression_method = readle(io, UInt16)
    if compression_method ∉ (COMPRESSION_STORE, COMPRESSION_DEFLATE)
        error("unimplemented compression method $(compression_method)")
    end
    return compression_method
end

function _read_last_modified(io)
    modtime = readle(io, UInt16)
    moddate = readle(io, UInt16)
    return msdos2datetime(moddate, modtime)
end

function Base.read(io::IO, ::Type{LocalFileHeader})
    # Do we need this?
    #version_needed = _read_version_needed(io)
    skip(io, 2)
    flags = _read_general_purpose_flags(io)
    utf8 = (flags & FLAG_LANGUAGE_ENCODING) != 0
    descriptor_follows = (flags & FLAG_FILE_SIZE_FOLLOWS) != 0
    compression_method = _read_compression_method(io)
    last_modified = _read_last_modified(io)
    crc32 = readle(io, UInt32)
    compressed_size = UInt64(readle(io, UInt32))
    uncompressed_size = UInt64(readle(io, UInt32))
    filename_length = readle(io, UInt16)
    extrafield_length = readle(io, UInt16)
    
    encoding = utf8 ? enc"UTF-8" : enc"IBM437"
    filename = first(readstring(io, filename_length; encoding = encoding))

    extra_read = 0
    zip64 = false
    while extra_read < extrafield_length
        ex_signature = readle(io, UInt16)
        ex_length = readle(io, UInt16)
        extra_read += 4

        if ex_signature != HEADER_ZIP64
            # TODO: other header types?
            skip(io, ex_length)
            extra_read += ex_length
            continue
        end

        # MUST include BOTH original and compressed file size fields in local header per 4.5.3.
        # Can have any number of fields in central directory, but MUST be in the same fixed order.
        # The standard suggests the the uncompressed and compressed sizes SHOULD be 0xffffffff
        # if Zip64 is used, but don't have to be. For now, treat this as a warning.
        if uncompressed_size != typemax(UInt32)
            @warn "Zip64-encoded file does not signal uncompressed size: expected $(typemax(UInt32)), got $(uncompressed_size)"
        end
        uncompressed_size = readle(io, UInt64)
        if compressed_size != typemax(UInt32)
            @warn "Zip64-encoded file does not signal compressed size: expected $(typemax(UInt32)), got $(compressed_size)"
        end
        compressed_size = readle(io, UInt64)

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

    # If data descriptor is signaled, the fields crc-32, compressed size, and uncompressed
    # size are set to zero in the local header per 4.4.4. However, it appears that all
    # known implementations override 4.4.4 by setting file sizes to 0xffffffff if the file
    # is in ZIP64 format.
    # Warn if data descriptor is signaled but these values appear wrong.
    if descriptor_follows
        if crc32 != CRC32_INIT
            @warn "File using data descriptor does not signal CRC-32: expected $(string(CRC32_INIT; base=16)), got $(string(crc32; base=16))"
        end
        if !zip64
            if uncompressed_size != 0%UInt32
                @warn "File using data descriptor does not signal uncompressed size: expected $(string(0%UInt32; base=16)), got $(string(uncompressed_size; base=16))"
            end
            if compressed_size != 0%UInt32
                @warn "File using data descriptor does not signal CRC-32: expected $(string(0%UInt32; base=16)), got $(string(compressed_size; base=16))"
            end
        end # zip64==true case caught above
    end

    info = ZipFileInformation(
        compression_method,
        uncompressed_size,
        compressed_size,
        last_modified,
        crc32,
        extrafield_length,
        filename,
        descriptor_follows,
        utf8,
        zip64,
    )
    return LocalFileHeader(info)

end

function Base.write(
        io::IO,
        header::LocalFileHeader;
        zip64::Union{Bool,Nothing}=nothing,
        utf8::Union{Bool,Nothing}=nothing
    )

    # signature: 4 bytes
    nb = writele(io, SIG_LOCAL_FILE)

    # version required to extract: 2 bytes
    dozip64 = (zip64 == true) || header.info.zip64
    if zip64 == false && (
        header.info.compressed_size >= typemax(UInt32) ||
        header.info.uncompressed_size >= typemax(UInt32)
    )
        error("file size too large for a standard Zip archive: uncompressed $(header.info.uncompressed_size), compressed $(header.info.compressed_size)")
    end
    if dozip64
        nb += writele(io, ZIP64_MINIMUM_VERSION)
    else
        nb += writele(io, DEFLATE_OR_FOLDER_MINIMUM_VERSION)
    end

    # general purpose flags: 2 bytes
    flags = UInt16(0)
    doutf8 = (utf8 == true) || header.info.utf8
    if doutf8
        flags |= FLAG_LANGUAGE_ENCODING
    end
    if header.info.descriptor_follows
        flags |= FLAG_FILE_SIZE_FOLLOWS
    end
    nb += writele(io, flags)

    # compression method: 2 bytes
    nb += writele(io, header.info.compression_method)

    # mod time: 2 bytes
    # mod date: 2 bytes
    (moddate, modtime) = datetime2msdos(header.info.last_modified)
    nb += writele(io, modtime)
    nb += writele(io, moddate)

    # crc-32: 4 bytes
    nb += writele(io, header.info.crc32)

    # compressed size: 4 bytes (maybe)
    # uncompressed size: 4 bytes (maybe)
    if dozip64
        nb += writele(io, typemax(UInt32))
        nb += writele(io, typemax(UInt32))
    else
        nb += writele(io, header.info.compressed_size % UInt32)
        nb += writele(io, header.info.uncompressed_size % UInt32)
    end

    # file name length: 2 bytes
    encoding = doutf8 ? enc"UTF-8" : enc"IBM437"
    filename_encoded = encode(header.info.name, encoding)
    nb += writele(io, length(filename_encoded) % UInt16)

    # extra field length: 2 bytes
    extra_length = dozip64 ? 20 : 0
    nb += writele(io, extra_length % UInt16)

    # file name: variable
    nb += writele(io, filename_encoded)

    # extra field: variable
    if dozip64
        # header: 2 bytes
        nb += writele(io, HEADER_ZIP64)
        # remaining length: 2 bytes
        nb += writele(io, 16 % UInt16)
        # original size: 8 bytes
        nb += writele(io, header.info.uncompressed_size)
        # compressed size: 8 bytes
        nb += writele(io, header.info.compressed_size)
    end

    return nb
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
    offset::UInt64
    comment::String
    directory::Bool
end

function Base.read(io::IO, ::Type{CentralDirectoryHeader})
    # TODO: version used to store?
    # version_store = readle(io, UInt16)
    # TODO: do we need to use this ever?
    # version_needed = _read_version_needed(io)
    skip(io, 4)
    flags = _read_general_purpose_flags(io)
    utf8 = (flags & FLAG_LANGUAGE_ENCODING) != 0
    descriptor_follows = (flags & FLAG_FILE_SIZE_FOLLOWS) != 0
    compression_method = _read_compression_method(io)
    last_modified = _read_last_modified(io)
    crc32 = readle(io, UInt32)
    compressed_size = UInt64(readle(io, UInt32))
    uncompressed_size = UInt64(readle(io, UInt32))
    filename_length = readle(io, UInt16)
    extrafield_length = readle(io, UInt16)
    comment_length = readle(io, UInt16)
    # NOTE: we don't use disk, just warn about it
    disk = readle(io, UInt16)
    if disk ∉ (0, 1)
        @warn "Archives spanning multiple disks are not supported" disk
    end
    # TODO: local file attribute information
    skip(io, 2)
    external_mode = readle(io, UInt32)
    isdir = (external_mode & (UNIX_IFDIR << 16)) != 0
    offset = UInt64(readle(io, UInt32))

    encoding = utf8 ? enc"UTF-8" : enc"IBM437"
    (filename, bytes_read) = readstring(io, filename_length; encoding = encoding)

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

        # Can have any number of fields in central directory, but MUST be in the same fixed order.
        nfields = min(ex_length ÷ 8, 3)
        # MUST have 0xffffffff for sizes in original record per 4.5.3.
        if nfields >= 1
            if uncompressed_size != typemax(UInt32)
                error(
                    "Zip64-encoded does not signal uncompressed size: expected $(typemax(UInt32)), got $(uncompressed_size)",
                )
            end
            uncompressed_size = readle(io, UInt64)
        end
        if nfields >= 2
            if compressed_size != typemax(UInt32)
                error(
                    "Zip64-encoded does not signal compressed size: expected $(typemax(UInt32)), got $(compressed_size)",
                )
            end
            compressed_size = readle(io, UInt64)
        end
        if nfields >= 3
            if offset != typemax(UInt32)
                error(
                    "Zip64-encoded does not signal offset: expected $(typemax(UInt32)), got $(offset)",
                )
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
        bytes_ignored = extrafield_length - extra_read
        @warn "Trailing data in extra fields will be ignored" bytes_ignored
        skip(io, bytes_ignored)
    end
    if extra_read > extrafield_length
        @warn "Number of bytes read from extra fields greater than size reported in header: data may be corrupted" extra_read header_reported_size=extrafield_length
    end

    (comment, bytes_read) = readstring(io, comment_length; encoding = encoding)
    if bytes_read != comment_length
        error("EOF when reading comment")
    end

    info = ZipFileInformation(
        compression_method,
        uncompressed_size,
        compressed_size,
        last_modified,
        crc32,
        extrafield_length,
        filename,
        descriptor_follows,
        utf8,
        zip64,
    )
    return CentralDirectoryHeader(info, offset, comment, isdir)
end

function Base.write(
        io::IO,
        header::CentralDirectoryHeader;
        zip64::Union{Bool,Nothing}=nothing,
        utf8::Union{Bool,Nothing}=nothing,
    )
    nb = 0
    # signature: 4 bytes
    nb += writele(io, SIG_CENTRAL_DIRECTORY)

    # version made by: 2 bytes, always claim to be made by a UNIX system
    nb += writele(io, ZIP64_MINIMUM_VERSION | UNIX_VERSION)

    # version required to extract: 2 bytes
    dozip64 = (zip64 == true) || header.info.zip64
    if zip64 == false && (
        header.info.compressed_size >= typemax(UInt32) ||
        header.info.uncompressed_size >= typemax(UInt32) ||
        header.offset >= typemax(UInt32)
    )
        error("file size too large for a standard Zip archive: uncompressed $(header.info.uncompressed_size), compressed $(header.info.compressed_size), offset $(header.offset)")
    end
    if dozip64
        nb += writele(io, ZIP64_MINIMUM_VERSION)
    else
        nb += writele(io, DEFLATE_OR_FOLDER_MINIMUM_VERSION)
    end

    # general purpose flags: 2 bytes
    flags = UInt16(0)
    if header.info.descriptor_follows
        flags |= FLAG_FILE_SIZE_FOLLOWS
    end
    doutf8 = (utf8 == true) || header.info.utf8
    if doutf8
        flags |= FLAG_LANGUAGE_ENCODING
    end
    nb += writele(io, flags)

    # compression method: 2 bytes
    nb += writele(io, header.info.compression_method)

    # mod time: 2 bytes
    # mod date: 2 bytes
    (moddate, modtime) = datetime2msdos(header.info.last_modified)
    nb += writele(io, modtime)
    nb += writele(io, moddate)

    # crc-32: 4 bytes
    nb += writele(io, header.info.crc32)

    # compressed size: 4 bytes (maybe)
    # uncompressed size: 4 bytes (maybe)
    if dozip64
        nb += writele(io, typemax(UInt32))
        nb += writele(io, typemax(UInt32))
    else
        nb += writele(io, header.info.compressed_size % UInt32)
        nb += writele(io, header.info.uncompressed_size % UInt32)
    end

    # file name length: 2 bytes
    encoding = doutf8 ? enc"UTF-8" : enc"IBM437"
    filename_encoded = encode(header.info.name, encoding)
    nb += writele(io, length(filename_encoded) % UInt16)

    # extra field length: 2 bytes
    extra_length = dozip64 ? 28 : 0
    nb += writele(io, extra_length % UInt16)

    # comment length: 2 bytes
    comment_encoded = encode(header.comment, encoding)
    nb += writele(io, length(comment_encoded) % UInt16)

    # disk number where file starts: 2 bytes
    nb += writele(io, 0 % UInt16)

    # internal file attributes: 2 bytes
    # TODO

    nb += writele(io, 0 % UInt16)

    # external file attributes: 4 bytes
    # never claim to be a pipe
    external_mode = header.directory ? (UNIX_IFDIR | UNIX_IXUSR) : UNIX_IFREG
    external_mode |= UNIX_IRUSR | UNIX_IWUSR
    
    nb += writele(io, (external_mode << 16) % UInt32)

    # offset of header: 4 bytes
    if dozip64
        nb += writele(io, typemax(UInt32))
    else
        nb += writele(io, header.offset % UInt32)
    end

    # file name: variable
    nb += writele(io, filename_encoded)

    # extra field: variable
    if dozip64
        # header: 2 bytes
        nb += writele(io, HEADER_ZIP64)
        # remaining length: 2 bytes
        nb += writele(io, UInt16(24))
        # original size: 8 bytes
        nb += writele(io, header.info.uncompressed_size)
        # compressed size: 8 bytes
        nb += writele(io, header.info.compressed_size)
        # offset: 8 bytes
        nb += writele(io, header.offset)
    end

    # comment: variable
    nb += writele(io, comment_encoded)

    return nb
end

# Check if a CentralDirectoryHeader is consistent with a given LocalFileHeader's info
function is_consistent(lhs::ZipFileInformation, rhs::ZipFileInformation; check_sizes::Bool=true)
    # some fields have to always match
    rhs.compression_method == lhs.compression_method || return false
    # modified time may have been read in MS-DOS format, meaning the best resolution it can muster is 2 seconds
    floor(abs(rhs.last_modified - lhs.last_modified), Second) < Second(2) || return false
    rhs.name == lhs.name || return false
    rhs.utf8 == lhs.utf8 || return false
    
    # some fields are dependent on the data descriptor flag
    rhs.descriptor_follows == lhs.descriptor_follows || return false

    # these fields might not be set yet if consistency is being checked before read is complete
    if rhs.descriptor_follows && !check_sizes
        return true
    end
    rhs.uncompressed_size == lhs.uncompressed_size || return false
    rhs.compressed_size == lhs.compressed_size || return false
    rhs.crc32 == lhs.crc32 || return false
    
    # other fields don't matter
    return true
end

# deal with refs in either position
is_consistent(lhs::Ref, rhs::Ref; kwargs...) = is_consistent(lhs[], rhs[]; kwargs...)
is_consistent(lhs::Ref, rhs; kwargs...) = is_consistent(lhs[], rhs; kwargs...)
is_consistent(lhs, rhs::Ref; kwargs...) = is_consistent(lhs, rhs[]; kwargs...)


function _write_zip64_eocd_record(io::IO, entries::UInt64, nbytes::UInt64, offset::UInt64)
    nb = writele(io, SIG_ZIP64_END_OF_CENTRAL_DIRECTORY)
    # remaining bytes in header: 8 bytes
    nb += writele(io, 44 % UInt64)
    # version made by: 2 bytes
    nb += writele(io, ZIP64_MINIMUM_VERSION)
    # version needed: 2 bytes
    nb += writele(io, ZIP64_MINIMUM_VERSION)
    # number of this disk: 4 bytes
    nb += writele(io, 0 % UInt32)
    # number of disk with central directory: 4 bytes
    nb += writele(io, 0 % UInt32)
    # total entries in central directory on this disk: 8 bytes
    nb += writele(io, entries)
    # total entries in central directory: 8 bytes
    nb += writele(io, entries)
    # size of central directory: 8 bytes
    nb += writele(io, nbytes)
    # offset to start of central directory: 8 bytes
    nb += writele(io, offset)
    # no extra data

    return nb
end

function _write_zip64_eocd_locator(io::IO, offset::UInt64)
    nb = writele(io, SIG_ZIP64_CENTRAL_DIRECTORY_LOCATOR)
    # number of disk with Zip64 EoCD: 4 bytes
    nb += writele(io, 0 % UInt32)
    # offset of Zip64 EoCD: 8 bytes
    nb += writele(io, offset)
    # total number of disks: 4 bytes
    nb += writele(io, 1 % UInt32) # might get me in trouble...

    return nb
end

function _write_eocd_record(
    io::IO,
    entries::UInt16,
    nbytes::UInt32,
    offset::UInt32,
    comment::AbstractString,
)
    nb = writele(io, SIG_END_OF_CENTRAL_DIRECTORY)
    # number of this disk: 2 bytes
    nb += writele(io, 0 % UInt16)
    # number of disk with start of CD: 2 bytes
    nb += writele(io, 0 % UInt16)
    # total entries in the CD on this disk: 2 bytes
    nb += writele(io, entries)
    # total entries in the CD: 2 bytes
    nb += writele(io, entries)
    # size of CD: 4 bytes
    nb += writele(io, nbytes)
    # offset to CD: 4 bytes
    nb += writele(io, offset)

    # NOTE: archive comments must only be IBM437. No UTF-8 capabilities in the EoCD.
    comment_encoded = encode(comment, enc"IBM437")
    # comment length: 2 bytes
    nb += writele(io, length(comment_encoded) % UInt16)
    # comment: variable
    nb += write(io, comment_encoded)

    return nb
end

function write_directory(
    io::IO,
    directory::AbstractVector{CentralDirectoryHeader};
    startpos::Union{Integer,Nothing}=nothing,
    comment::AbstractString="",
    zip64::Union{Bool,Nothing}=nothing,
    utf8::Union{Bool,Nothing}=nothing,
    zip64_eocd::Union{Bool,Nothing}=nothing,
)
    # write the Central Directory headers
    beg = isnothing(startpos) ? position(io) % UInt64 : startpos % UInt64
    nb = 0
    dozip64 = false
    for header in directory
        nb += write(io, header; zip64=zip64, utf8=utf8)
        dozip64 |= header.info.zip64
    end
    
    pos = beg + nb

    # write the EoCD, using Zip64 standard as necessary
    n_entries = length(directory) % UInt64
    dozip64 |= (nb >= typemax(UInt32) || beg >= typemax(UInt32) || pos >= typemax(UInt32) || n_entries >= typemax(UInt16))
    if dozip64 && zip64_eocd == false
        error("header requires Zip64 EOCD: length $(nb), beg $(beg), endpos $(pos), entries $(n_entries)")
    end
    # override if forced
    dozip64 |= (zip64_eocd == true)
    if dozip64
        nb += _write_zip64_eocd_record(io, n_entries, nb % UInt64, beg % UInt64)
        nb += _write_zip64_eocd_locator(io, pos % UInt64)
        nb += _write_eocd_record(io, typemax(UInt16), typemax(UInt32), typemax(UInt32), comment)
    else
        nb += _write_eocd_record(io, n_entries % UInt16, nb % UInt32, beg % UInt32, comment)
    end

    return nb
end