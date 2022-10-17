using Printf

"""
    info([io::IO = stdout], zip)

Print information about a ZIP archive or file stream.
"""
function info(io::IO, za::ZipArchiveInputStream)
    print(io, "ZIP archive source stream data after reading ", human_readable_bytes(bytes_read(za)))
    if eof(za)
        print(io, " (EOF reached)")
    end
    print(io, ", number of entries")
    print(io, ": ", length(za.directory))
    if length(za.directory) > 0
        n_files = 0
        println(io)
        total_uc = 0
        total_c = 0
        for entry in za.directory
            info(io, entry)
            println(io)
            total_uc += entry.uncompressed_size
            total_c += entry.compressed_size
            if !isdir(entry)
                n_files += 1
            end
        end
        print(io, n_files, " file")
        if n_files != 1
            print(io, "s")
        end
        if total_uc > 0
            @printf(io, ", %s uncompressed, %s compressed: %5.1f%%", human_readable_bytes(total_uc), human_readable_bytes(total_c), (total_uc - total_c) * 100 / total_uc)
        end
    end
    return 
end

info(za::ZipArchiveInputStream) = info(stdout, za)

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
function info(io::IO, zi::ZipFileInformation)
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
info(zi::ZipFileInformation) = info(stdout, zi)
info(io::IO, zf::ZipFileInputStream) = info(io, zf.info)
info(zf::ZipFileInputStream) = info(stdout, zf)