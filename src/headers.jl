using Dates

struct LocalFileHeader
    signature::UInt32
    version::UInt16
    flags::UInt16
    compression::UInt16
    modtime::UInt16
    moddate::UInt16
    crc32::UInt32
    compressed_size::UInt32
    uncompressed_size::UInt32
    file_name_length::UInt16
    extra_field_length::UInt16

    file_name::Vector{UInt8}
    extra_field::Vector{UInt8}
end

struct EncryptionHeader
    buffer::NTuple{12,UInt8}
end

struct DataDescriptor
    crc32::UInt32
    compressed_size::UInt32
    uncompressed_size::UInt32
end

abstract type AbstractExtraDataRecord end

struct EmptyExtraDataRecord <: AbstractExtraDataRecord
end

struct ExtraDataRecord <: AbstractExtraDataRecord
    signature::UInt16
    length::UInt16
    data::Vector{UInt8}
end

struct Zip64ExtraDataRecord <: AbstractExtraDataRecord
    signature::UInt16
    length::UInt16
    uncompressed_file_size::UInt64
    compressed_file_size::UInt64
    local_header_offset::UInt64
    # disk_number_start::UInt32 # ISO requires 0 or 1
end

struct CentralDirectoryHeader
    # signature::UInt32 # == CentralDirectoryHeaderSignature
    # version_made_by::UInt16 # doesn't matter, but cannot be inferred from data, >=45 needed for Zip64
    # version_needed::UInt16 # doesn't matter, but cannot be inferred from data, >=45 needed for Zip64
    # flags::UInt16 # unused
    compression_method::UInt16
    # modtime::UInt16 # Used to create moddatetime
    # moddate::UInt16 # Used to create moddatetime
    crc32::UInt32
    compressed_size::UInt32
    uncompressed_size::UInt32
    # file_name_length::UInt16 # Used to parse string
    # extra_field_length::UInt16 # Used to create vector
    # file_comment_length::UInt16 # used to parse string
    # disk_number_start::UInt16 # ISO requires 0 or 1
    # internal_attributes::UInt16 # Unused in modern systems? Cannot be inferred from data
    # external_attributes::UInt32 # TODO: use these 
    local_header_offset::UInt32

    file_name::String
    extra_fields::Vector{AbstractExtraDataRecord}
    file_comment::String
    moddatetime::DateTime
end

"""
CentralDirectoryHeader(io)

Read from IO object and create an Central Directory Header record from the data therein.

This is done element at a time because ZIP files are always stored little endian,
while the platform might not natively use that storage format.
"""
function CentralDirectoryHeader(io::IO)
    signature = readle(io, UInt32)
    version_made_by = readle(io, UInt16) # doesn't matter, but cannot be inferred from data, >=45 needed for Zip64
    version_needed = readle(io, UInt16) # doesn't matter, but cannot be inferred from data, >=45 needed for Zip64
    flags = readle(io, UInt16) # used only for error checking
    compression_method = readle(io, UInt16)
    modtime = readle(io, UInt16) # Used to create moddatetime
    moddate = readle(io, UInt16) # Used to create moddatetime
    crc32 = readle(io, UInt32)
    compressed_size = readle(io, UInt32)
    uncompressed_size = readle(io, UInt32)
    file_name_length = readle(io, UInt16) # Used to parse string
    extra_field_length = readle(io, UInt16) # Used to create vector
    file_comment_length = readle(io, UInt16) # used to parse string
    disk_number_start = readle(io, UInt16) # ISO requires 0 or 1
    # internal_attributes = readle(io, UInt16) # Unused in modern systems? Cannot be inferred from data
    skip(io, 2)
    # external_attributes = readle(io, UInt32) # TODO: use these 
    skip(io, 4)
    local_header_offset = readle(io, UInt32)

    check_utf8 = (flags & Integer(LanguageEncoding)) != 0
    (file_name, file_name_read) = readstring(io, file_name_length; validate_utf8=check_utf8)

    extra_bytes = Array{UInt8}(undef, extra_field_length)
    extra_bytes_read = readbytes!(io, extra_bytes, extra_field_length)

    (file_comment, file_comment_read) = readstring(io, file_comment_length; validate_utf8=check_utf8)
    
    moddatetime = msdos2datetime(moddate, modtime)

    # Check errors
    signature != Integer(CentralDirectorySignature) && error("incorrect signature of Central Directory record: expected $(string(Integer(CentralDirectorySignature), base=16)), got $(string(signature, base=16))")
    warn_zip64 = version_made_by < 45 || version_needed < 45
    compression_method ∉ (Integer(Store), Integer(Deflate)) && error("ISO/IEC 21320-1 standard requires compression method $Store ($(string(Integer(Store), base=16))) or $Deflate ($(string(Integer(Deflate), base=16))), got $(string(compression_method, base=16))")
    if warn_zip64
        compressed_size == typemax(compressed_size) && @warn "version made by or needed is insufficient to use Zip64 extensions for compressed size" version_made_by version_needed
        uncompressed_size == typemax(uncompressed_size) && @warn "version made by or needed is insufficient to use Zip64 extensions for uncompressed size" version_made_by version_needed
        disk_number_start == typemax(disk_number_start) && @warn "version made by or needed is insufficient to use Zip64 extensions for disk number start" version_made_by version_needed
        local_header_offset == typemax(local_header_offset) && @warn "version made by or needed is insufficient to use Zip64 extensions for local header offset" version_made_by version_needed
    end
    file_name_read != file_name_length && error("EOF seen when reading file name: expected to read $file_name_length, read $file_name_read")
    extra_bytes_read != extra_field_length && error("EOF seen when reading extra data: expected to read $extra_field_length, read $extra_bytes_read")
    file_comment_read != file_comment_length && error("EOF seen when reading file comment: expected to read $file_comment_length, read $file_comment_read")

    # Parse extra fields


    return CentralDirectoryHeader(
        compression_method,
        crc32,
        compressed_size,
        uncompressed_size,
        local_header_offset,
        file_name,
        [],
        file_comment,
        moddatetime,
    )
end

struct DigitalSignature
    signature::UInt32
    length::UInt16
    data::Vector{UInt8}
end

struct Zip64EndOfCentralDirectoryRecord
    # signature::UInt32 # == Zip64EndCentralDirectorySignature
    # length::UInt64 # does not include the 12 bytes read up to this point! Warn if not ==44
    # version_made_by::UInt16 # doesn't matter, but cannot be inferred from data, warn if <45 else Zip64 does not make sense
    # version_needed::UInt16 # doesn't matter, but warn if <45 else Zip64 does not make sense.
    # disk_number::UInt32 # ISO requires 0 or 1
    # central_directory_disk::UInt32 # ISO requires 0 or 1
    # entries_this_disk::UInt64 # ISO requires equal to entries_total
    entries_total::UInt64
    central_directory_length::UInt64
    central_directory_offset::UInt64

    # extensible_data::Vector{UInt8} # Reserved for use: warn if not empty
end

"""
    Zip64EndOfCentralDirectoryRecord(io)

Read from IO object and create an EoCD64 record from the data therein.

This is done element at a time because ZIP files are always stored little endian,
while the platform might not natively use that storage format.
"""
function Zip64EndOfCentralDirectoryRecord(io::IO)
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

    signature != Integer(Zip64EndCentralDirectorySignature) && error("incorrect signature of EoCD64 record: expected $(string(Integer(Zip64EndCentralDirectorySignature), base=16)), got $(string(signature, base=16))")
    length > 44 && @warn "record length implies reserved extensible data field used: expected length 44, got $length"
    length < 44 && error("record length too short: expected length >=44, got $length")
    version_made_by < 45 && @warn "version made by is insufficient to create Zip64 records: expected version >= 45, got $version_made_by"
    version_needed < 45 && @warn "version needed to extract is insufficient to extract Zip64 records: expected version >= 45, got $version_needed"
    disk_number > 1 && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected disk number <=1, got $disk_number")
    central_directory_disk > 1 && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected central directory disk number <=1, got $central_directory_disk")
    entries_this_disk != entries_total && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected entries this disk ($entries_this_disk) to equal total entries ($entries_total)")
    
    return Zip64EndOfCentralDirectoryRecord(
        entries_total,
        central_directory_length,
        central_directory_offset,
    )
end

struct Zip64EndOfCentralDirectoryLocator
    # signature::UInt32 # == Zip64EndCentralLocatorSignature
    # end_of_central_directory_disk::UInt32 # ISO requires 0 or 1
    end_of_central_directory_offset::UInt64
    # total_disks::UInt32 # ISO requires 0 or 1
end

"""
    Zip64EndOfCentralDirectoryLocator(io)

Read from IO object and create an EoCD64 locator record from the data therein.

This is done element at a time because ZIP files are always stored little endian,
while the platform might not natively use that storage format.
"""
function Zip64EndOfCentralDirectoryLocator(io::IO)
    signature = readle(io, UInt32)
    end_of_central_directory_disk = readle(io, UInt32)
    end_of_central_directory_offset = readle(io, UInt64)
    total_disks = readle(io, UInt32)

    signature != Integer(Zip64EndCentralLocatorSignature) && error("incorrect signature of EoCD64 locator record: expected $(string(Integer(Zip64EndCentralLocatorSignature), base=16)), got $(string(signature, base=16))")
    end_of_central_directory_disk > 1 && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected end of central directory disk number <=1, got $end_of_central_directory_disk")
    total_disks > 1 && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected total disks <=1, got $total_disks")

    return Zip64EndOfCentralDirectoryLocator(end_of_central_directory_offset)
end

struct EndOfCentralDirectoryRecord
    # signature::UInt32 # == EndCentralDirectorySignature
    # disk_number::UInt16 # ISO requires 0 or 1
    # central_directory_disk::UInt16 # ISO requires 0 or 1
    # entries_this_disk::UInt16 # ISO requires same as entries_total
    entries_total::UInt16
    central_directory_length::UInt32
    central_directory_offset::UInt32
    # comment_length::UInt16 # stored as string, below
    comment::String # actually Vector{UInt8}
end

"""
    EndOfCentralDirectoryRecord(io)

Read from IO object and create an EoCD record from the data therein.

This is done element at a time because ZIP files are always stored little endian,
while the platform might not natively use that storage format.
"""
function EndOfCentralDirectoryRecord(io::IO)
    signature = readle(io, UInt32)
    disk_number = readle(io, UInt16)
    central_directory_disk = readle(io, UInt16)
    entries_this_disk = readle(io, UInt16)
    entries_total = readle(io, UInt16)
    central_directory_length = readle(io, UInt32)
    central_directory_offset = readle(io, UInt32)
    comment_length = readle(io, UInt16)
    (comment, comment_read_bytes) = readstring(io, comment_length) #TODO: check UTF-8

    # error checking
    signature != Integer(EndCentralDirectorySignature) && error("incorrect signature of EoCD record: expected $(string(Integer(EndCentralDirectorySignature), base=16)), got $(string(signature, base=16))")
    disk_number > 1 && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected disk number <=1, got $disk_number")
    central_directory_disk > 1 && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected central directory disk number <=1, got $central_directory_disk")
    entries_this_disk != entries_total && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected entries this disk ($entries_this_disk) to equal entries total ($entries_total)")
    comment_read_bytes != comment_length && error("EOF reached reading comment: expected to read $comment_length, only read $comment_read_bytes")

    return EndOfCentralDirectoryRecord(
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