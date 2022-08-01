using Dates
using StringEncodings

import Base: read

"""
    ExtraDataRecord

An in-memory representation of Extra Data records.

See: 4.4.28 and 4.5 of https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT.

# Notes
- The only type of extra data that matters for reading has signature 0x0001 (Zip64).

- Other extra data, like those associated with different file system types, are
not parsed (yet).

- The only valid lengths of Zip64 data records are 0, 8, 16, 24, or 28. The local
file header version must contain the compressed and uncompressed file size fields,
so those records can only be 16, 24, or 28 bytes.
"""
struct ExtraDataRecord
    signature::UInt16
    # length::UInt16 # Length of data part only, used to build vector
    data::Vector{UInt8}
end

function Base.read(io::IO, ::Type{ExtraDataRecord})
    signature = readle(io, UInt16)
    len = readle(io, UInt16)
    data = Array{UInt8}(undef, len)
    data_read = readbytes!(io, data, len)

    # Error checking
    signature == HEADER_ZIP64 && len ∉ [0, 8, 16, 24, 28] && error("Zip64 extra data can only have lengths of 16, 24, or 28 bytes, got $len")
    data_read != len && error("EOF encountered when reading extra data: expected $len, got $data_read")

    return ExtraDataRecord(
        signature,
        data,
    )
end

"""
    iszip64_record(r)

Determine if `r` is Zip64 Extra Data record.
"""
function iszip64_record(r::ExtraDataRecord)
    return r.signature == HEADER_ZIP64
end

"""
    has_uncompressed_file_size(r)

Determine if `r` has an uncompressed file size field.
"""
function has_uncompressed_file_size(r::ExtraDataRecord)
    return length(r.data) >= 8
end

"""
    uncompressed_file_size(r)

Get uncompressed file size field.
"""
function uncompressed_file_size(r::ExtraDataRecord)
    return bytesle2int(view(r.data, 1:8), UInt64)
end

"""
    has_compressed_file_size(r)

Determine if `r` has a compressed file size field.
"""
function has_compressed_file_size(r::ExtraDataRecord)
    return length(r.data) >= 16
end

"""
    compressed_file_size(r)

Get compressed file size field.
"""
function compressed_file_size(r::ExtraDataRecord)
    return bytesle2int(view(r.data, 9:16), UInt64)
end

"""
    has_offset(r)

Determine whether `r` has a valid offset field.
"""
function has_offset(r::ExtraDataRecord)
    return length(r.data) >= 24
end

"""
    offset(r)

Get offset field.
"""
function offset(r::ExtraDataRecord)
    return bytesle2int(view(r.data, 17:24), UInt64)
end

"""
    has_disk_number(r)

Determine whether `r` has a valid disk number field.
"""
function has_disk_number(r::ExtraDataRecord)
    return length(r.data) >= 28
end

"""
    disk_number(r)

Get disk number field.
"""
function disk_number(r::ExtraDataRecord)
    return bytesle2int(view(r.data, 25:28), UInt32)
end

struct LocalFileHeader
    # signature::UInt32 # == LocalFileHeaderSignature
    # version::UInt16 # ISO requires <=45
    flags::UInt16 # ISO requires only (zero-indexed) bits 1-3 and 11 be used, and that bit 11 must be set if any byte in the name or comment is > 0x7f
    compression::UInt16 # ISO requires STORE or DEFLATE
    # modtime::UInt16 # Parsed to DateTime
    # moddate::UInt16 # Parsed to DateTime
    crc32::UInt32 # Set to 0 if flags & 0x8
    compressed_size::UInt32 # Set to 0 if flags & 0x8
    uncompressed_size::UInt32 # Set to 0 if flags & 0x8
    # file_name_length::UInt16 # Parsed to String
    # extra_field_length::UInt16 # Parsed to extra data

    file_name::String
    extra_data::Vector{ExtraDataRecord}
end

# struct EncryptionHeader # Prohibited by ISO
#     buffer::NTuple{12,UInt8}
# end

struct DataDescriptor{T<:Unsigned} # Must be present if flags & 0x8
    crc32::UInt32
    compressed_size::T # 64 bits if Zip64, otherwise 32 bits
    uncompressed_size::T  # 64 bits if Zip64, otherwise 32 bits
end

"""
    CentralDirectory

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
struct CentralDirectory
    # signature::UInt32 # == CentralDirectoryHeaderSignature
    # version_made_by::UInt16 # >=45 needed for Zip64
    # version_needed::UInt16 # ISO forbids > 45, >=45 needed for Zip64
    flags::UInt16 # ISO forbids all but bits 1, 2, 3, and 11
    compression_method::UInt16
    # modtime::UInt16 # Used to create moddatetime
    # moddate::UInt16 # Used to create moddatetime
    crc32::UInt32
    compressed_size::UInt32
    uncompressed_size::UInt32
    # file_name_length::UInt16 # Used to parse string
    # extra_field_length::UInt16 # Used to create vector
    # file_comment_length::UInt16 # used to parse string
    # disk_number_start::UInt16
    # internal_attributes::UInt16 # Unused in modern systems? Cannot be inferred from data
    # external_attributes::UInt32 # TODO: use these 
    local_header_offset::UInt32

    file_name::String
    extra_fields::Vector{ExtraDataRecord}
    file_comment::String
    moddatetime::DateTime
end

function Base.read(io::IO, ::Type{CentralDirectory})
    signature = readle(io, UInt32)
    version_made_by = readle(io, UInt16) # >=45 needed for Zip64
    version_needed = readle(io, UInt16) # ISO requires <=45, >=45 needed for Zip64
    flags = readle(io, UInt16) # ISO requires only bits 1, 2, 3, and 11 be used.
    compression_method = readle(io, UInt16) # ISO requires only 0 or 8
    modtime = readle(io, UInt16) # Used to create moddatetime
    moddate = readle(io, UInt16) # Used to create moddatetime
    crc32 = readle(io, UInt32)
    compressed_size = readle(io, UInt32) # If ==0xffffffff, check for Zip64 in extra data
    uncompressed_size = readle(io, UInt32) # If ==0xffffffff, check for Zip64 in extra data
    file_name_length = readle(io, UInt16) # Used to parse string
    extra_field_length = readle(io, UInt16) # Used to create vector
    file_comment_length = readle(io, UInt16) # used to parse string
    disk_number_start = readle(io, UInt16)
    # internal_attributes = readle(io, UInt16) # Unused in modern systems? Cannot be inferred from data
    skip(io, 2)
    # external_attributes = readle(io, UInt32) # TODO: use these 
    skip(io, 4)
    local_header_offset = readle(io, UInt32) # If ==0xffffffff, check for Zip64 in extra data

    encoding = (flags & FLAG_LANGUAGE_ENCODING) != 0 ? enc"UTF-8" : enc"IBM437"
    (file_name, file_name_read) = readstring(io, file_name_length; encoding=encoding)
    # Parse extra fields
    extra_bytes_read = 0
    extra_data = Vector{ExtraDataRecord}()
    while extra_bytes_read < extra_field_length
        r = read(io, ExtraDataRecord)
        push!(extra_data, r)
        extra_bytes_read += 4 + length(r.data)
    end
    (file_comment, file_comment_read) = readstring(io, file_comment_length; encoding=encoding)

    moddatetime = msdos2datetime(moddate, modtime)

    # Check errors
    signature != SIG_CENTRAL_DIRECTORY && error("incorrect signature of Central Directory record: expected $(string(SIG_CENTRAL_DIRECTORY, base=16)), got $(string(signature, base=16))")
    compression_method ∉ (COMPRESSION_STORE, COMPRESSION_DEFLATE) && error("ISO/IEC 21320-1 standard requires compression method $Store ($(string(COMPRESSION_STORE, base=16))) or $Deflate ($(string(COMPRESSION_DEFLATE, base=16))), got $(string(compression_method, base=16))")
    warn_zip64 = version_made_by < ZIP64_MINIMUM_VERSION || version_needed < ZIP64_MINIMUM_VERSION
    if warn_zip64
        compressed_size == typemax(compressed_size) && @warn "version made by or needed is insufficient to use Zip64 extensions for compressed size" version_made_by version_needed
        uncompressed_size == typemax(uncompressed_size) && @warn "version made by or needed is insufficient to use Zip64 extensions for uncompressed size" version_made_by version_needed
        disk_number_start == typemax(disk_number_start) && @warn "version made by or needed is insufficient to use Zip64 extensions for disk number start" version_made_by version_needed
        local_header_offset == typemax(local_header_offset) && @warn "version made by or needed is insufficient to use Zip64 extensions for local header offset" version_made_by version_needed
    end
    file_name_read != file_name_length && error("EOF seen when reading file name: expected to read $file_name_length, read $file_name_read")
    extra_bytes_read != extra_field_length && error("EOF seen when reading extra data: expected to read $extra_field_length, read $extra_bytes_read")
    file_comment_read != file_comment_length && error("EOF seen when reading file comment: expected to read $file_comment_length, read $file_comment_read")
    extra_bytes_read != extra_field_length && error("Too much extra field data read: expectred $extra_field_length, got $extra_bytes_read")
    length(unique(x -> x.signature, extra_data)) != length(extra_data) && error("Duplicate extra data fields")

    return CentralDirectory(
        flags,
        compression_method,
        crc32,
        compressed_size,
        uncompressed_size,
        local_header_offset,
        file_name,
        extra_data,
        file_comment,
        moddatetime,
    )
end

# Forbidden by ISO/IEC 21320-1
# struct DigitalSignature
#     signature::UInt32
#     length::UInt16
#     data::Vector{UInt8}
# end

"""
    Zip64EndOfCentralDirectoryRecord

An in-memory representation of the Zip64 End of Central Directory (EoCD)
record.

See: 4.3.14 of https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT.

# Notes
- ISO/IEC 21320-1 requires disk spanning _not_ be used, implying the disk
containing the central directory be the same as the disk number. The disk number
itself is arbitrary. This also implies that the number of entries on this disk
must be equal to the number of entries total.

- APPNOTE specifies version 45 as the minimum version for reading and writing
Zip64 files. ISO/IEC 21320-1 requires that the version number be no greater than
45. The specification is not clear whether applications are allowed to lie about
what version number was used to create the file, but ISO/IEC 21320-1 is clear
that the maximum value for version needed to extract is 45.

- APPNOTE 4.4.2 states that the upper byte of version made by can be ignored
("Software _can_ use this information..."). The specification not clear whether
the upper byte of version needed to extract can be treated the same way. This
implementation ignores the upper byte.
"""
struct Zip64EndOfCentralDirectoryRecord
    # signature::UInt32 # == Zip64EndCentralDirectorySignature
    # length::UInt64 # does not include the 12 bytes read up to this point! Warn if not ==44
    # version_made_by::UInt16 # Zip64 requires >=45
    # version_needed::UInt16 # ISO requires <=45, Zip64 requires >=45
    disk_number::UInt32 # ISO requires ==central_directory_disk, warn if !=1
    # central_directory_disk::UInt32 # ISO requires ==disk_number
    # entries_this_disk::UInt64 # ISO requires ==entries_total
    entries_total::UInt64
    central_directory_length::UInt64
    central_directory_offset::UInt64

    # extensible_data::Vector{UInt8} # Reserved for use: warn if not empty
end

function Base.read(io::IO, ::Type{Zip64EndOfCentralDirectoryRecord})
    signature = readle(io, UInt32)
    length = readle(io, UInt64)
    version_made_by = readle(io, UInt16)
    version_needed = readle(io, UInt16)
    disk_number = readle(io, UInt32)
    central_directory_disk = readle(io, UInt32)
    entries_this_disk = readle(io, UInt64)
    entries_total = readle(io, UInt64)
    central_directory_length = readle(io, UInt64)
    central_directory_offset = readle(io, UInt64)
    
    # ed_length = length - 44
    # extensible_data = Array{UInt8}(undef, ed_length)
    # ed_read = readbytes!(io, extensible_data, ed_length)

    signature != SIG_ZIP64_END_OF_CENTRAL_DIRECTORY && error("incorrect signature of EoCD64 record: expected $(string(SIG_ZIP64_END_OF_CENTRAL_DIRECTORY, base=16)), got $(string(signature, base=16))")
    length > 44 && @warn "record length implies reserved extensible data field used: expected length 44, got $length"
    length < 44 && error("record length too short: expected length >=44, got $length")
    version_made_by & 0xff < 45 && @warn "version made by is insufficient to create Zip64 records: expected version >= 45, got $version_made_by"
    version_needed & 0xff < 45 && @warn "version needed is insufficient to extract Zip64 records: expected version >= 45, got $version_needed"
    version_needed & 0xff > 45 && error("ISO/IEC 21320-1 standard requires version needed be <=45, got $version_needed")
    central_directory_disk != disk_number && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected central directory disk number ($central_directory_disk) to equal disk number ($disk_number)")
    entries_this_disk != entries_total && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected entries this disk ($entries_this_disk) to equal total entries ($entries_total)")
    
    return Zip64EndOfCentralDirectoryRecord(
        disk_number,
        entries_total,
        central_directory_length,
        central_directory_offset,
    )
end

"""
    Zip64EndOfCentralDirectoryLocator

An in-memory representation of the Zip64 End of Central Directory (EoCD)
locator record.

See: 4.3.15 of https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT.

# Notes
- ISO/IEC 21320-1 requires disk spanning _not_ be used, implying the total number
of disks be equal to 1. The disk number is arbitrary.
"""
struct Zip64EndOfCentralDirectoryLocator
    # signature::UInt32 # ==Zip64EndCentralLocatorSignature
    disk_number::UInt32
    offset::UInt64
    # total_disks::UInt32 # ISO requires ==1
end

function Base.read(io::IO, ::Type{Zip64EndOfCentralDirectoryLocator})
    signature = readle(io, UInt32)
    disk_number = readle(io, UInt32)
    offset = readle(io, UInt64)
    total_disks = readle(io, UInt32)

    signature != SIG_ZIP64_CENTRAL_DIRECTORY_LOCATOR && error("incorrect signature of EoCD64 locator record: expected $(string(SIG_ZIP64_CENTRAL_DIRECTORY_LOCATOR, base=16)), got $(string(signature, base=16))")
    total_disks != 1 && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected total disks equal to 1, got $total_disks")

    return Zip64EndOfCentralDirectoryLocator(disk_number, offset)
end

"""
    EndOfCentralDirectoryRecord

An in-memory representation of the End of Central Directory (EoCD) record.

See: 4.3.16 of https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT.

# Notes
- ISO/IEC 21320-1 requires disk spanning _not_ be used, implying the disk number
equal the disk number where the central directory begins and the entries this
disk equal the total entries.

- The standard only allows .ZIP archive comments in IBM Code Page 437 encoding.

- It is recommended ("SHOULD NOT") that directory records not exceed 65,535 bytes
in length, but no such recommendation is made of the EoCD record, even though it
is variable length. Its theoretical maximum length is 22 + 65,535 = 65,557 bytes,
but nothing in the specification requires that the archive end after the comment
field.
"""
struct EndOfCentralDirectoryRecord
    # signature::UInt32 # == EndCentralDirectorySignature
    disk_number::UInt16 # ISO requires ==central_directory_disk
    # central_directory_disk::UInt16 # ISO requires ==disk_number
    # entries_this_disk::UInt16 # ISO requires same as entries_total
    entries_total::UInt16
    central_directory_length::UInt32
    central_directory_offset::UInt32
    # comment_length::UInt16 # parsed as String
    comment::String # actually Vector{UInt8}
end

function Base.read(io::IO, ::Type{EndOfCentralDirectoryRecord})
    signature = readle(io, UInt32)
    disk_number = readle(io, UInt16)
    central_directory_disk = readle(io, UInt16)
    entries_this_disk = readle(io, UInt16)
    entries_total = readle(io, UInt16)
    central_directory_length = readle(io, UInt32)
    central_directory_offset = readle(io, UInt32)
    comment_length = readle(io, UInt16)
    (comment, comment_read_bytes) = readstring(io, comment_length)

    # error checking
    signature != SIG_END_OF_CENTRAL_DIRECTORY && error("incorrect signature of EoCD record: expected $(string(SIG_END_OF_CENTRAL_DIRECTORY, base=16)), got $(string(signature, base=16))")
    disk_number != central_directory_disk && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected disk number ($disk_number) to equal disk number of start of central directory ($central_directory_disk)")
    entries_this_disk != entries_total && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected entries this disk ($entries_this_disk) to equal entries total ($entries_total)")
    comment_read_bytes != comment_length && error("EOF reached reading comment: expected to read $comment_length, only read $comment_read_bytes")


    return EndOfCentralDirectoryRecord(
        disk_number,
        entries_total,
        central_directory_length,
        central_directory_offset,
        comment,
    )
end

"""
    zip64fields(eocd_record)

Finds which fields in the record are potentially stored in a ZIP64 header.
"""
function zip64fields(eocd_record::EndOfCentralDirectoryRecord)
    zip64 = Vector{Symbol}()
    for field in [:entries_total, :central_directory_length, :central_directory_offset]
        val = getfield(eocd_record, field)
        if val == typemax(val)
            push!(zip64, field)
        end
    end
    return zip64
end