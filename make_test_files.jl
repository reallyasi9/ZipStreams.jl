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
const COMPRESSION_OPTIONS = [
    "store" => 0x0000 % UInt16,
    "deflate" => 0x0008 % UInt16,
]
const DATA_DESCRIPTOR_OPTIONS = [
    "nodd" => 0x0000 % UInt16,
    "dd" => 0x0008 % UInt16,
]
const LOCAL_ZIP64_OPTIONS = [
    "nolocal64" => false,
    "local64" => true,
]
const UTF8_OPTIONS = [
    "ibm" => 0x0000 % UInt16,
    "utf" => 0x0800 % UInt16,
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

function write_local_header(io::IO, compress::UInt16, dd::UInt16, lz64::Bool, utf8::UInt16)
    write(io, htol(LOCAL_HEADER))
    write(io, htol(EX_VER))
    bit_flag = (dd | utf8) % UInt16
    write(io, htol(bit_flag))
    write(io, htol(compress))
    write(io, htol(EPOCH_TIME))
    write(io, htol(EPOCH_DATE))
    if dd != 0
        crc = 0 % UInt32
        usize = 0 % UInt32
        csize = 0 % UInt32
    else
        crc = CONTENT_CRC32
        if lz64
            usize = 0xffffffff % UInt32
            csize = 0xffffffff % UInt32
        else
            usize = length(CONTENT) % UInt32
            if compress != 0
                csize = length(CONTENT_DEFLATED) % UInt32
            else
                csize = usize
            end
        end
    end
    write(io, htol(crc))
    write(io, htol(csize))
    write(io, htol(usize))
    if utf8 != 0
        filename = codeunits(UNICODE_FILENAME)
    else
        filename = codeunits(FILENAME)
    end
    lfn = length(filename) % UInt16
    write(io, htol(lfn))
    if lz64
        exlen = 20 % UInt16
    else
        exlen = 0 % UInt16
    end
    write(io, htol(exlen))
    write(io, filename)
    if lz64
        write(io, htol(ZIP64_HEADER))
        len = 16 % UInt16
        write(io, htol(len))
        write(io, htol(usize % UInt64))
        write(io, htol(csize % UInt64))
    end
end

function write_data_descriptor(io::IO, compress::UInt16, lz64::Bool)
    write(io, htol(DATA_DESCRIPTOR_HEADER))
    write(io, htol(CONTENT_CRC32))
    usize = length(CONTENT)
    if compress != 0
        csize = length(CONTENT_DEFLATED)
    else
        csize = usize
    end
    if lz64
        write(io, csize % UInt64)
        write(io, usize % UInt64)
    else
        write(io, csize % UInt32)
        write(io, usize % UInt32)
    end
end

function write_central_directory(io::IO, compress::UInt16, dd::UInt16, cz64::Bool, utf8::UInt16)
    write(io, htol(CENTRAL_DIRECTORY_HEADER))
    write(io, htol(EX_VER))
    write(io, htol(EX_VER))
    bit_flag = (dd | utf8) % UInt16
    write(io, htol(bit_flag))
    write(io, htol(compress))
    write(io, htol(EPOCH_TIME))
    write(io, htol(EPOCH_DATE))
    write(io, htol(CONTENT_CRC32))
    if cz64
        usize = 0xffffffff % UInt32
        csize = 0xffffffff % UInt32
    else
        usize = length(CONTENT) % UInt32
        if compress != 0
            csize = length(CONTENT_DEFLATED) % UInt32
        else
            csize = usize
        end
    end
    write(io, htol(csize))
    write(io, htol(usize))
    if utf8 != 0
        filename = codeunits(UNICODE_FILENAME)
        comment = codeunits(UNICODE_FILE_COMMENT)
    else
        filename = codeunits(FILENAME)
        comment = codeunits(FILE_COMMENT)
    end
    lfn = length(filename) % UInt16
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
    if cz64
        write(io, 0xffffffff % UInt32)
    else
        write(io, 0 % UInt32)
    end
    write(io, filename)
    if cz64
        write(io, htol(ZIP64_HEADER))
        len = 28 % UInt16
        write(io, htol(len))
        xusize = length(CONTENT) % UInt64
        if compress != 0
            xcsize = length(CONTENT_DEFLATED) % UInt64
        else
            xcsize = xusize
        end
        write(io, htol(xusize))
        write(io, htol(xcsize))
        write(io, 0 % UInt64)
        write(io, 0 % UInt32)
    end
    write(io, comment)
end

function write_eocd(io::IO, cd_start::Int, ez64::Bool)
    eocd_loc = position(io) % UInt64
    if ez64
        write(io, htol(ZIP64_EOCD_HEADER))
        write(io, htol(44 % UInt64))
        write(io, htol(EX_VER))
        write(io, htol(EX_VER))
        write(io, 0 % UInt32)
        write(io, 0 % UInt32)
        write(io, htol(1 % UInt64))
        write(io, htol(1 % UInt64))
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
        write(io, htol(1 % UInt16))
        write(io, htol(1 % UInt16))
        write(io, htol((eocd_loc - cd_start % UInt32) % UInt32))
        write(io, htol(cd_start % UInt32))
    end

    comment = codeunits(ARCHIVE_COMMENT)
    cl = length(comment)
    write(io, htol(cl % UInt16))
    write(io, comment)
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