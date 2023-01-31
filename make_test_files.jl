using CodecZlib, TranscodingStreams, CRC32

# Bootstraps the creation of test ZIP files

const CONTENT = b"Hello, Julia!\n"
const FILENAME = "hello.txt"
const DIRNAME = "subdir"
const UNICODE_FILENAME = "hello👋.txt"
const FILE_COMMENT = "File comment"
const UNICODE_FILE_COMMENT = "File comment💾"
const ARCHIVE_COMMENT = "Archive comment"

const CONTENT_CRC32 = crc32(CONTENT)
const CONTENT_DEFLATED = transcode(DeflateCompressor, CONTENT)

# File name standard:
# (store|deflate)-(no)?dd-(no)?local64-(ibm|utf)-(no)?cd64-(no)?eocd64(-.*)?\.zip
# store|deflate: uses store/deflate for compression
# (no)?dd: uses local header/data descriptor for size and CRC information
# (no)?local64: uses standard/Zip64 in local header for size
# (ibm|utf): uses IBM/UTF-8 for file comment
# (no)?cd64: uses standard/Zip64 in central directory entry
# (no)?eocd64: uses standard/Zip64 End of Central Directory (EOCD) record
# Everything following the hyphen is a comment for ease of understanding.

const STORE = 0x0000 % UInt16
const DEFLATE = 0x0008 % UInt16
const NO_DD = 0x0000 % UInt16
const DD = 0x0008 % UInt16
const IBM_ENC = 0x0000 % UInt16
const UTF8_ENC = 0x0800 % UInt16

const COMPRESSION_OPTIONS = [
    "store" => STORE,
    "deflate" => DEFLATE,
]
const DATA_DESCRIPTOR_OPTIONS = [
    "nodd" => NO_DD,
    "dd" => DD,
]
const LOCAL_ZIP64_OPTIONS = [
    "nolocal64" => false,
    "local64" => true,
]
const UTF8_OPTIONS = [
    "ibm" => IBM_ENC,
    "utf" => UTF8_ENC,
]
const CD_ZIP64_OPTIONS = [
    "nocd64" => false,
    "cd64" => true,
]
const EOCD_ZIP64_OPTIONS = [
    "noeocd64" => false,
    "eocd64" => true,
]

const LOCAL_HEADER = 0x04034b50 % UInt32
const EX_VER = 45 % UInt16
const EPOCH_TIME = 0x0000
const EPOCH_DATE = 0x0021
const ZIP64_HEADER = 0x0001 % UInt16
const DATA_DESCRIPTOR_HEADER = 0x08074b50 % UInt32
const CENTRAL_DIRECTORY_HEADER = 0x02014b50 % UInt32
const ZIP64_EOCD_HEADER = 0x06064b50 % UInt32
const ZIP64_EOCDL_HEADER = 0x07064b50 % UInt32
const EOCD_HEADER = 0x06054b50 % UInt32

function write_local_header(
    io::IO,
    compress::Integer,
    dd::Integer,
    lz64::Bool,
    utf8::Integer;
    crc::UInt32=dd == NO_DD ? CONTENT_CRC32 : 0%UInt32,
    usize::Integer=dd == DD ? 0 : lz64 ? typemax(UInt32) : length(CONTENT),
    csize::Integer=dd == DD ? 0 : lz64 ? typemax(UInt32) : compress == 0 ? usize : length(CONTENT_DEFLATED),
    filename::String=utf8 == IBM_ENC ? FILENAME : UNICODE_FILENAME,
    )
    
    write(io, htol(LOCAL_HEADER))
    write(io, htol(EX_VER))
    bit_flag = (dd % UInt16 | utf8 % UInt16) % UInt16
    write(io, htol(bit_flag))
    write(io, htol(compress % UInt16))
    write(io, htol(EPOCH_TIME))
    write(io, htol(EPOCH_DATE))
    write(io, htol(crc))
    write(io, htol(csize%UInt32))
    write(io, htol(usize%UInt32))
    cufn = codeunits(filename)
    lfn = length(cufn) % UInt16
    write(io, htol(lfn))
    if lz64
        exlen = 20 % UInt16
    else
        exlen = 0 % UInt16
    end
    write(io, htol(exlen))
    write(io, cufn)
    if lz64
        write(io, htol(ZIP64_HEADER))
        len = 16 % UInt16
        write(io, htol(len))
        write(io, htol(usize % UInt64))
        write(io, htol(csize % UInt64))
    end
end

function write_data_descriptor(
    io::IO,
    compress::Integer,
    lz64::Bool; 
    crc::UInt32=CONTENT_CRC32,
    usize::Integer=length(CONTENT),
    csize::Integer=compress == 0 ? usize : length(CONTENT_DEFLATED),
    )

    write(io, htol(DATA_DESCRIPTOR_HEADER))
    write(io, htol(crc))
    if lz64
        write(io, csize % UInt64)
        write(io, usize % UInt64)
    else
        write(io, csize % UInt32)
        write(io, usize % UInt32)
    end
end

function write_central_directory(
    io::IO,
    compress::Integer,
    dd::Integer,
    cz64::Bool,
    utf8::Integer;
    crc::UInt32=CONTENT_CRC32,
    usize::Integer=cz64 ? typemax(UInt32) : length(CONTENT),
    csize::Integer=cz64 ? typemax(UInt32) : compress == STORE ? usize : length(CONTENT_DEFLATED),
    offset::Integer=cz64 ? typemax(UInt32) : 0,
    filename::String=utf8 == IBM_ENC ? FILENAME : UNICODE_FILENAME,
    comment::String=utf8 == IBM_ENC ? FILE_COMMENT : UNICODE_FILE_COMMENT,
    )

    write(io, htol(CENTRAL_DIRECTORY_HEADER))
    write(io, htol(EX_VER))
    write(io, htol(EX_VER))
    bit_flag = (dd % UInt16 | utf8 % UInt16) % UInt16
    write(io, htol(bit_flag))
    write(io, htol(compress % UInt16))
    write(io, htol(EPOCH_TIME))
    write(io, htol(EPOCH_DATE))
    write(io, htol(crc))
    write(io, htol(csize % UInt32))
    write(io, htol(usize % UInt32))
    cufn = codeunits(filename)
    lfn = length(cufn) % UInt16
    write(io, htol(lfn))
    if cz64
        exlen = 32 % UInt16
    else
        exlen = 0 % UInt16
    end
    write(io, htol(exlen))
    lcomment = length(comment) % UInt16
    write(io, htol(lcomment))
    write(io, 0 % UInt16)
    write(io, 0 % UInt16)
    write(io, 0 % UInt32)
    write(io, htol(offset % UInt32))
    write(io, cufn)
    if cz64
        write(io, htol(ZIP64_HEADER))
        len = 28 % UInt16
        write(io, htol(len))
        xusize = usize % UInt64
        xcsize = csize % UInt64
        xoffset = offset % UInt64
        write(io, htol(xusize))
        write(io, htol(xcsize))
        write(io, htol(xoffset))
        write(io, 0 % UInt32)
    end
    write(io, comment)
end

function write_eocd(io::IO, cd_start::Integer, ez64::Bool; number_of_entries::Integer=1, comment::String=ARCHIVE_COMMENT)
    eocd_loc = position(io) % UInt64
    if ez64
        write(io, htol(ZIP64_EOCD_HEADER))
        write(io, htol(44 % UInt64))
        write(io, htol(EX_VER))
        write(io, htol(EX_VER))
        write(io, 0 % UInt32)
        write(io, 0 % UInt32)
        write(io, htol(number_of_entries % UInt64))
        write(io, htol(number_of_entries % UInt64))
        write(io, htol((eocd_loc - cd_start % UInt64) % UInt64))
        write(io, htol(cd_start % UInt64))

        write(io, htol(ZIP64_EOCDL_HEADER))
        write(io, 0 % UInt32)
        write(io, htol(eocd_loc))
        write(io, htol(1 % UInt32))

        write(io, htol(EOCD_HEADER))
        write(io, 0xffff % UInt16)
        write(io, 0xffff % UInt16)
        write(io, 0xffff % UInt16)
        write(io, 0xffff % UInt16)
        write(io, 0xffffffff % UInt32)
        write(io, 0xffffffff % UInt32)
    else
        write(io, htol(EOCD_HEADER))
        write(io, 0 % UInt16)
        write(io, 0 % UInt16)
        write(io, htol(number_of_entries % UInt16))
        write(io, htol(number_of_entries % UInt16))
        write(io, htol((eocd_loc - cd_start % UInt32) % UInt32))
        write(io, htol(cd_start % UInt32))
    end

    cu = codeunits(comment)
    cl = length(cu)
    write(io, htol(cl % UInt16))
    write(io, cu)
end

for (compression, dd, lzip64, utf8, czip64, ezip64) in Iterators.product(COMPRESSION_OPTIONS, DATA_DESCRIPTOR_OPTIONS, LOCAL_ZIP64_OPTIONS, UTF8_OPTIONS, CD_ZIP64_OPTIONS, EOCD_ZIP64_OPTIONS)
    archive_name = join([compression[1], dd[1], lzip64[1], utf8[1], czip64[1], ezip64[1]], '-') * ".zip"

    open(archive_name, "w") do io
        write_local_header(io, compression[2], dd[2], lzip64[2], utf8[2])

        if compression[2] != 0
            write(io, CONTENT_DEFLATED)
        else
            write(io, CONTENT)
        end

        if dd[2] != 0
            write_data_descriptor(io, compression[2], lzip64[2])
        end

        cd_start = position(io)
        write_central_directory(io, compression[2], dd[2], czip64[2], utf8[2])

        write_eocd(io, cd_start, ezip64[2])
    end
end

# Multi-file with subdirectory
for (compression, dd) in Iterators.product(COMPRESSION_OPTIONS, DATA_DESCRIPTOR_OPTIONS)
    archive_name = join([compression[1], dd[1]], '-') * "-nolocal64-ibm-nocd64-noeocd64-multi.zip"

    open(archive_name, "w") do io
        # hello.txt
        offsets = zeros(UInt32, 3)
        offsets[1] = position(io)
        write_local_header(io, compression[2], dd[2], false, IBM_ENC)

        if compression[2] != 0
            write(io, CONTENT_DEFLATED)
        else
            write(io, CONTENT)
        end

        if dd[2] != 0
            write_data_descriptor(io, compression[2], false)
        end

        # subdir/
        offsets[2] = position(io)
        write_local_header(io, STORE, NO_DD, false, IBM_ENC; crc=0x00000000, usize=0, filename=DIRNAME * "/")

        # subdir/hello.txt
        offsets[3] = position(io)
        write_local_header(io, compression[2], dd[2], false, IBM_ENC; filename=join([DIRNAME, FILENAME], '/'))

        if compression[2] != 0
            write(io, CONTENT_DEFLATED)
        else
            write(io, CONTENT)
        end

        if dd[2] != 0
            write_data_descriptor(io, compression[2], false)
        end

        # central directory
        cd_start = position(io)
        write_central_directory(io, compression[2], dd[2], false, IBM_ENC; offset=offsets[1])
        write_central_directory(io, STORE, NO_DD, false, IBM_ENC; crc=0x00000000, usize=0, filename=DIRNAME * "/", offset=offsets[2])
        write_central_directory(io, compression[2], dd[2], false, IBM_ENC; filename=join([DIRNAME, FILENAME], '/'), offset=offsets[3])

        write_eocd(io, cd_start, false; number_of_entries=2%UInt64)
    end
end

# Empties
for ezip64 in EOCD_ZIP64_OPTIONS
    archive_name = ezip64[1] * "-empty.zip"

    open(archive_name, "w") do io
        write_eocd(io, 0, ezip64[2]; number_of_entries=0, comment="")
    end
end

# Broken files
# Additional header in central directory that does not reference a file
open("deflate-dd-nolocal64-ibm-nocd64-noeocd64-additional-header-central.zip", "w") do io
    write_local_header(io, DEFLATE, DD, false, IBM_ENC)
    write(io, CONTENT_DEFLATED)
    write_data_descriptor(io, DEFLATE, false)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, DD, false, IBM_ENC; offset=0, comment="")
    # second entry is an error
    write_central_directory(io, DEFLATE, DD, false, IBM_ENC; offset=0, comment="")
    write_eocd(io, cd_start, false; number_of_entries=2, comment="")
end

# Missing header in central directory
open("deflate-dd-nolocal64-ibm-nocd64-noeocd64-missing-header-central.zip", "w") do io
    write_local_header(io, DEFLATE, DD, false, IBM_ENC)
    write(io, CONTENT_DEFLATED)
    write_data_descriptor(io, DEFLATE, false)
    write_local_header(io, DEFLATE, DD, false, IBM_ENC; filename="hello2.txt")
    write(io, CONTENT_DEFLATED)
    write_data_descriptor(io, DEFLATE, false)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, DD, false, IBM_ENC; offset=0, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Compressed size in local header too large
open("deflate-nodd-nolocal64-ibm-nocd64-noeocd64-local-csize-too-large.zip", "w") do io
    write_local_header(io, DEFLATE, NO_DD, false, IBM_ENC; csize=(length(CONTENT_DEFLATED) + 1))
    write(io, CONTENT_DEFLATED)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, NO_DD, false, IBM_ENC; offset=0, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Compressed size in local header too small
open("deflate-nodd-nolocal64-ibm-nocd64-noeocd64-local-csize-too-small.zip", "w") do io
    write_local_header(io, DEFLATE, NO_DD, false, IBM_ENC; csize=(length(CONTENT_DEFLATED) - 1))
    write(io, CONTENT_DEFLATED)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, NO_DD, false, IBM_ENC; offset=0, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Uncompressed size in local header too large
open("deflate-nodd-nolocal64-ibm-nocd64-noeocd64-local-usize-too-large.zip", "w") do io
    write_local_header(io, DEFLATE, NO_DD, false, IBM_ENC; usize=(length(CONTENT) + 1))
    write(io, CONTENT_DEFLATED)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, NO_DD, false, IBM_ENC; offset=0, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Uncompressed size in local header too small
open("deflate-nodd-nolocal64-ibm-nocd64-noeocd64-local-usize-too-small.zip", "w") do io
    write_local_header(io, DEFLATE, NO_DD, false, IBM_ENC; usize=(length(CONTENT) - 1))
    write(io, CONTENT_DEFLATED)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, NO_DD, false, IBM_ENC; offset=0, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Bad CRC in local header
open("deflate-nodd-nolocal64-ibm-nocd64-noeocd64-local-bad-crc.zip", "w") do io
    write_local_header(io, DEFLATE, NO_DD, false, IBM_ENC; crc=0xdeadbeef)
    write(io, CONTENT_DEFLATED)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, NO_DD, false, IBM_ENC; offset=0, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Compressed size in central header too large
open("deflate-nodd-nolocal64-ibm-nocd64-noeocd64-central-csize-too-large.zip", "w") do io
    write_local_header(io, DEFLATE, NO_DD, false, IBM_ENC)
    write(io, CONTENT_DEFLATED)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, NO_DD, false, IBM_ENC; offset=0, csize=(length(CONTENT_DEFLATED) + 1), comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Compressed size in central header too small
open("deflate-nodd-nolocal64-ibm-nocd64-noeocd64-central-csize-too-small.zip", "w") do io
    write_local_header(io, DEFLATE, NO_DD, false, IBM_ENC)
    write(io, CONTENT_DEFLATED)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, NO_DD, false, IBM_ENC; offset=0, csize=(length(CONTENT_DEFLATED) - 1), comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Uncompressed size in central header too large
open("deflate-nodd-nolocal64-ibm-nocd64-noeocd64-central-usize-too-large.zip", "w") do io
    write_local_header(io, DEFLATE, NO_DD, false, IBM_ENC)
    write(io, CONTENT_DEFLATED)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, NO_DD, false, IBM_ENC; offset=0, usize=(length(CONTENT) + 1), comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Uncompressed size in central header too small
open("deflate-nodd-nolocal64-ibm-nocd64-noeocd64-central-usize-too-small.zip", "w") do io
    write_local_header(io, DEFLATE, NO_DD, false, IBM_ENC)
    write(io, CONTENT_DEFLATED)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, NO_DD, false, IBM_ENC; offset=0, usize=(length(CONTENT) - 1), comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Bad CRC in central header
open("deflate-nodd-nolocal64-ibm-nocd64-noeocd64-central-bad-crc.zip", "w") do io
    write_local_header(io, DEFLATE, NO_DD, false, IBM_ENC)
    write(io, CONTENT_DEFLATED)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, NO_DD, false, IBM_ENC; offset=0, crc=0xdeadbeef, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Compressed size in data descriptor too large
open("deflate-dd-nolocal64-ibm-nocd64-noeocd64-dd-csize-too-large.zip", "w") do io
    write_local_header(io, DEFLATE, DD, false, IBM_ENC)
    write(io, CONTENT_DEFLATED)
    write_data_descriptor(io, DEFLATE, false; csize=(length(CONTENT_DEFLATED) + 1))
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, DD, false, IBM_ENC; offset=0, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Compressed size in data descriptor too small
open("deflate-dd-nolocal64-ibm-nocd64-noeocd64-dd-csize-too-small.zip", "w") do io
    write_local_header(io, DEFLATE, DD, false, IBM_ENC)
    write(io, CONTENT_DEFLATED)
    write_data_descriptor(io, DEFLATE, false; csize=(length(CONTENT_DEFLATED) - 1))
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, DD, false, IBM_ENC; offset=0, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Uncompressed size in data descriptor too large
open("deflate-dd-nolocal64-ibm-nocd64-noeocd64-dd-usize-too-large.zip", "w") do io
    write_local_header(io, DEFLATE, DD, false, IBM_ENC)
    write(io, CONTENT_DEFLATED)
    write_data_descriptor(io, DEFLATE, false; usize=(length(CONTENT) + 1))
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, DD, false, IBM_ENC; offset=0, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Uncompressed size in data descriptor too small
open("deflate-dd-nolocal64-ibm-nocd64-noeocd64-dd-usize-too-small.zip", "w") do io
    write_local_header(io, DEFLATE, DD, false, IBM_ENC)
    write(io, CONTENT_DEFLATED)
    write_data_descriptor(io, DEFLATE, false; usize=(length(CONTENT) - 1))
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, DD, false, IBM_ENC; offset=0, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Bad CRC in data descriptor
open("deflate-dd-nolocal64-ibm-nocd64-noeocd64-dd-bad-crc.zip", "w") do io
    write_local_header(io, DEFLATE, DD, false, IBM_ENC)
    write(io, CONTENT_DEFLATED)
    write_data_descriptor(io, DEFLATE, false; crc=0xdeadbeef)
    # central directory
    cd_start = position(io)
    write_central_directory(io, DEFLATE, DD, false, IBM_ENC; offset=0, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end

# Pathological data descriptor: hidden data!
open("store-dd-nolocal64-ibm-nocd64-noeocd64-pathological-dd.zip", "w") do io
    # The content has appended what looks like a valid data descriptor for the data up to that point,
    # but additional content continues afterward.
    # The correct lengths and CRC are written in the proper data descriptor that follows and
    # in the central directory.
    content = vcat(
        CONTENT,
        reinterpret(UInt8, [htol(DATA_DESCRIPTOR_HEADER)]),
        reinterpret(UInt8, [htol(CONTENT_CRC32)]),
        reinterpret(UInt8, [htol(length(CONTENT) % UInt32)]),
        reinterpret(UInt8, [htol(length(CONTENT) % UInt32)]),
        CONTENT,
    )
    crc = crc32(content)
    csize = sizeof(content)
    usize = csize

    write_local_header(io, STORE, DD, false, IBM_ENC)
    write(io, content)
    write_data_descriptor(io, STORE, false; crc=crc, usize=usize, csize=csize)
    # central directory
    cd_start = position(io)
    write_central_directory(io, STORE, DD, false, IBM_ENC; offset=0, crc=crc, usize=usize, csize=csize, comment="")
    write_eocd(io, cd_start, false; number_of_entries=1, comment="")
end