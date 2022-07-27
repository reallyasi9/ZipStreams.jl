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
    header_offset::UInt64
    disk_number_start::UInt32
end

struct CentralDirectoryHeader
    signature::UInt32
    version_made_by::UInt16
    version_needed::UInt16
    flags::UInt16
    compression_method::UInt16
    modtime::UInt16
    moddate::UInt16
    crc32::UInt32
    compressed_size::UInt32
    uncompressed_size::UInt32
    file_name_length::UInt16
    extra_field_length::UInt16
    file_comment_length::UInt16
    disk_number_start::UInt16
    internal_attributes::UInt16
    external_attributes::UInt32
    local_header_offset::UInt32

    file_name::Vector{UInt8}
    extra_field::Vector{UInt8}
    file_comment::Vector{UInt8}
end

struct DigitalSignature
    signature::UInt32
    length::UInt16
    data::Vector{UInt8}
end

struct Zip64EndOfCentralDirectoryRecord
    signature::UInt32
    length::UInt64
    version_made_by::UInt16
    version_needed::UInt16
    disk_number::UInt32
    central_directory_disk::UInt32
    entries_this_disk::UInt64
    entries_total::UInt64
    central_directory_length::UInt64
    central_directory_offset::UInt64

    extensible_data::Vector{UInt8}
end

struct Zip64EndOfCentralDirectorLocator
    signature::UInt32
    end_of_central_directory_disk::UInt32
    end_of_central_directory_offset::UInt64
    total_disks::UInt32
end

struct EndOfCentralDirectoryRecord
    signature::UInt32
    disk_number::UInt16
    central_directory_disk::UInt16
    entries_this_disk::UInt16
    entries_total::UInt16
    central_directory_length::UInt32
    central_directory_offset::UInt32
    comment_length::UInt16
    comment::Vector{UInt8}
end

"""
    EndOfCentralDirectoryRecord(io)

Read from IO object and create an EoCD record from the data therein.

This is done element at a time because ZIP files are always stored little endian,
while the platform might not be.
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

    comment = Array{UInt8, 1}(undef, comment_length)
    comment_read_bytes = readbytes!(io, comment, comment_length)

    # error checking
    signature != Integer(EndCentralDirectorySignature) && error("incorrect signature of EoCD record: expected $(Integer(EndCentralDirectorySignature)), got $signature")
    disk_number != 0 && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected disk number 0, got $disk_number")
    central_directory_disk != 0 && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected central directory disk number 0, got $central_directory_disk")
    entries_this_disk != entries_total && error("ISO/IEC 21320-1 standard prohibits archives spanning multiple volumes: expected entries this disk ($entries_this_disk) to equal entries total ($entries_total)")
    comment_read_bytes != comment_length && error("EOF reached reading comment: expected to read $comment_length, only read $comment_read_bytes")

    return EndOfCentralDirectoryRecord(
        signature,
        disk_number,
        central_directory_disk,
        entries_this_disk,
        entries_total,
        central_directory_length,
        central_directory_offset,
        comment_length,
        comment
    )
end