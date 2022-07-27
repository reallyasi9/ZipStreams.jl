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
    archive_decryption_header::EncryptionHeader
    extra_data::ExtraDataRecord
    directory::Vector{CentralDirectoryHeader}
    zip64_eod::Zip64EndOfCentralDirectoryRecord
    zip64_eod_locator::Zip64EndOfCentralDirectorLocator
    eod::EndOfCentralDirectoryRecord

    _file_lookup::Dict{String,Int}
end

"""
    ZipFile(io)

Open a standard IO object as a Zip file.
"""
function ZipFile(io::IO)
    seek_to_eocd_record!(io)
    eocd_record = EndOfCentralDirectoryRecord(io)
end

"""
    seek_to_eocd_record!(io)

Seeks the input IO to the End of Central Directory record.

Raises an exception if no EOCD record is found in the input.
"""
function seek_to_eocd_record!(io::IO)
    # read blocks of 4096 bytes (one IO block size)
    blocksize = 4096
    sig = bytearray(EndCentralDirectorySignature)
    overlap = sizeof(sig) - 1

    seekend(io)
    filesize = position(io)

    pos = max(filesize - blocksize, 0)
    cache = Array{UInt8}(undef, blocksize)
    while pos >= 0
        seek(io, pos)
        num_read = readbytes!(io, cache, blocksize)
        index = findfirst(sig, @inbounds @view cache[1:num_read])
        
        if !isnothing(index)
            seek(io, pos + first(index) - 1)
            return
        end

        # Add 4 bytes to overlap the previous read by the length of the signature
        if pos == 0
            break
        end

        pos = max(pos - blocksize + overlap, 0)
    end

    error("end of central directory record signature not found")
end

end # module