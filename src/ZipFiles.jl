"""
A Julia package for reading/writing ZIP archive files

This package provides support for reading and writing ZIP archives in Julia.
Install it via the Julia package manager using ``Pkg.add("ZipFiles")``.

The ZIP file format is described in
http://www.pkware.com/documents/casestudies/APPNOTE.TXT

# Example
The example below writes a new ZIP file and then reads back the contents.
```
julia> using ZipFiles
```
"""
module ZipFiles

import Base: read, read!, eof, write, flush, close, mtime, position, show, unsafe_write
using Printf

using CodecZlib
using TranscodingStreams

include("io.jl")
include("constants.jl")
include("headers.jl")

struct FileData{C<:TranscodingStreams.Codec,S<:IO} <: IO
    header::LocalFileHeader
    encryption_header::EncryptionHeader

    data::TranscodingStream{C,S}

    data_descriptor::DataDescriptor
end

"""
    ZipFile

For a full definition, see https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT.
"""
struct ZipFile
    files::Vector{FileData}

    _file_lookup::Dict{String,Int}
end

"""
    ZipFile(io)

Open a standard IO object as a Zip file.
"""
function ZipFile(io::IO)
    directory = read_directory(io)
end

function read_directory_info(io::IO)
    # Zip files store their directory information at the end
    seekend(io)
    seekbackward(io, EndCentralDirectorySignature)

    eocd_pos = position(io)
    eocd_record = EndOfCentralDirectoryRecord(io)

    central_directory_info = (
        entries_total = UInt64(eocd_record.entries_total),
        central_directory_length = UInt64(eocd_record.central_directory_length),
        central_directory_offset = UInt64(eocd_record.central_directory_offset),
    )

    eocd_zip64_fields = zip64fields(eocd_record)
    if !isempty(eocd_zip64_fields)
        @debug "Zip64 format detected in EoCD record"
        seek(io, eocd_pos - 20)
        eocd64_loc_record = Zip64EndOfCentralDirectoryLocator(io)

        seek(io, eocd64_loc_record.end_of_central_directory_offset)
        eocd64_record = Zip64EndOfCentralDirectoryRecord(io)

        central_directory_info = (
            entries_total = eocd64_record.entries_total,
            central_directory_length = eocd64_record.central_directory_length,
            central_directory_offset = eocd64_record.central_directory_offset,
        )
    end

    return central_directory_info
end

function read_directory(io::IO)
    directory_info = read_directory_info(io)

    directory = Array{CentralDirectoryHeader}(undef, directory_info.entries_total)
    seek(io, directory_info.central_directory_offset)
    for i in 1:directory_info.entries_total
        directory[i] = CentralDirectoryHeader(io)
    end
    
    return directory
end

"""
    seekbackward(io, signature)

Seeks the input IO to the given signature backward from the current position.

Seeking backward through a stream requires that the stream be seekable. It is
almost never efficient to seek backward through an IO stream because of how
modern computer hardware is designed: hardware caches typically assume streams
will be iterated forward. To attempt to speed up backward seeking, this function
will seek backward in steps of 4096 bytes (one IO block in modern hardware), then
seek forward through that to find the last instance of the signature.

Raises an exception if no signature is found in the input. Note that the function
name follows the convention of the IO methods in `Base`: that the function by its
nature modifies the input argument, even though the function does not end in an
exclaimation point.
"""
function seekbackward(io::IO, signature::UInt32)
    # read blocks of 4096 bytes (one IO block size)
    blocksize = 4096
    sig = bytearray(signature)
    # make sure that the reads overlap enough to find the signature
    overlap = sizeof(sig) - 1
    endpos = position(io)

    pos = max(endpos - blocksize, 0)
    cache = Array{UInt8}(undef, blocksize)
    while pos >= 0
        seek(io, pos)
        num_read = readbytes!(io, cache, blocksize)
        index = findlast(sig, @inbounds @view cache[1:num_read])
        
        if !isnothing(index)
            seek(io, pos + first(index) - 1)
            return
        end

        if pos == 0
            break
        end

        pos = max(pos - blocksize + overlap, 0)
    end

    error("signature $(string(signature, base=16)) not found")
end

seekbackward(io::IO, signature::Signature) = seekbackward(io, Integer(signature))

end # module