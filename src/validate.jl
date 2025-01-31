
"""
    is_valid!([sink::IO,] zf::ZipFileSource) -> Bool

Validate that the contents read from an archived file match the information stored
in the Local File Header, optionally writing remaining file information to a sink.

If the contents of the file do not match the information in the Local File Header, the
method will describe the detected error using `@error` logging. The method checks that the
compressed and uncompressed file sizes match what is in the header and that the CRC-32 of the
uncompressed data matches what is reported in the header. Validation will work even on files that
have been partially read.

The exclaimation mark in the function name is a warning to the user that the function destructively
reads bytes from the `ZipFileSource`. If `sink` is provided, the remaining unread bytes from `zf`
will be extracted into `sink`.

Because data cannot be written to a `ZipFileSource`, repeated calls to `is_valid!` will return
the same result each time, but will only extract data to `sink` on the first call.
"""
function is_valid!(sink::IO, zf::ZipFileSource)
    if !isnothing(zf._valid)
        return zf._valid
    end
    good = true
    # read the remainder of the file
    write(sink, zf)
    if !eof(zf)
        good = false
        @error "EOF not reached"
    end

    i = zf.info[]
    if i.descriptor_follows
        # If we are at EOF and we have a data descriptor, we have guaranteed that everything
        # in the data descriptor checks out.
        # Replace the data in the file info so it checks out with the central dictionary
        T = i.zip64 ? UInt64 : UInt32
        (crc, c_bytes, u_bytes, _) = read_data_descriptor(T, zf)
        zf.info[] = ZipFileInformation(
            i.compression_method,
            u_bytes,
            c_bytes,
            i.last_modified,
            crc,
            i.extra_field_size,
            i.name,
            i.descriptor_follows,
            i.utf8,
            i.zip64,
        )
        # cache result
        zf._valid = good
        return good
    end

    if bytes_in(zf) != i.compressed_size
        @error "Compressed size check failed" local_header=i.compressed_size read=bytes_in(zf)
        good = false
    end
    if bytes_out(zf) != i.uncompressed_size
        @error "Uncompressed size check failed" local_header=i.uncompressed_size read=bytes_out(zf)
        good = false
    end
    if zf.source.crc32 != i.crc32
        @error "CRC-32 check failed" local_header=string(i.crc32; base=16) read=string(zf.source.crc32; base=16)
        good = false
    end
    # cache result
    zf._valid = good
    return good
end

is_valid!(zf::ZipFileSource) = is_valid!(devnull, zf)


"""
    is_valid!([sink::IO,] source::ZipArchiveSource) -> Bool

Validate the files in the archive `source` against the Central Directory at the end of
the archive.

The exclaimation mark in the function name is a warning to the user that this method consumes _all_
the remaining data from `source`. and returns `false` if the file information from the file headers
read does not match the information in the Central Directory. Files that have already been consumed
prior to calling this method will still be validated, but the local headers of those files will
_not_ be validated against the local data that has already been consumed.

The exclaimation mark in the function name is a warning to the user that the function destructively
reads bytes from the `ZipArchiveSource`. If `sink` is provided, the remaining unread bytes from
`source` will be extracted and the data from the remaining files will be written as concatenated
bytes into `sink`.

Because data cannot be written to a `ZipArchiveSource`, repeated calls to `is_valid!` will return
the same result each time, but will only extract data to `sink` on the first call.

!!! warning "Files using descriptors"
    If a file stored within `source` uses a File Descriptor rather than storing the size of the file
    in the Local File Header, the file must be read to the end in order to properly record the
    lengths for checking against the Central Directory. Failure to read such a file to the end will
    result in `is_valid` returning `false` when called on the archive.

See also [`is_valid!(::ZipFileSource)`](@ref).
"""
function is_valid!(sink::IO, zs::ZipArchiveSource)
    if !isnothing(zs._valid)
        return zs._valid
    end
    good = true
    # validate remaining files
    for file in zs
        good &= is_valid!(sink, file)
    end

    # Guaranteed to be after the last local header found.
    # Read off the directory contents and check what was found.
    # Central directory entries are not necessary in the same order as the files in the
    # archive, so we need to match on name and offset
    headers_by_name = Dict{String, CentralDirectoryHeader}()
    headers_by_offset = Dict{UInt64, CentralDirectoryHeader}()
    
    # read headers until we're done
    bytes_read = SIG_CENTRAL_DIRECTORY
    while !eof(zs.source) && bytes_read == SIG_CENTRAL_DIRECTORY
        try
            cd_info = read(zs.source, CentralDirectoryHeader)
            if cd_info.offset in keys(headers_by_offset)
                good = false
                @error "Central directory contains multiple entries with the same offset" offset=cd_info.offset first_header=headers_by_offset[cd_info.offset] second_header=cd_info
            end
            if cd_info.info.name in keys(headers_by_name)
                good = false
                @error "Central directory contains multiple entries with the same file name" file_name=cd_info.info.name first_header=headers_by_name[cd_info.info.name] second_header=cd_info
            end
            headers_by_offset[cd_info.offset] = cd_info
            headers_by_name[cd_info.info.name] = cd_info
        catch e
            if typeof(e) == EOFError
                # assume this is the end of the directory
                break
            else
                throw(e)
            end
        end
        bytes_read = readle(zs.source, UInt32)
    end

    # need to check for repeated names in the local headers
    names_read = Set{String}()
    for (lf_offset, lf_info_ref) in zip(zs.offsets, zs.directory)
        if lf_offset ∉ keys(headers_by_offset)
            good = false
            @error "File not found in central directory" offset=lf_offset local_header=lf_info_ref[]
        else
            cd_info = headers_by_offset[lf_offset]
            if !is_consistent(cd_info.info, lf_info_ref; check_sizes=true)
                good = false
                @error "Local file header is inconsistent with central directory header" offset=lf_offset central_directory_header=cd_info.info local_file_header=lf_info_ref[]
            end
            # delete headers from the central directory dict to check for duplicates or missing files
            delete!(headers_by_offset, lf_offset)
        end
        if lf_info_ref[].name in names_read
            good = false
            @error "Multiple files have the same name" name=lf_info_ref[].name local_header=lf_info_ref[]
        end
        push!(names_read, lf_info_ref[].name)
    end
    # Report if there are files we didn't read
    if !isempty(headers_by_offset)
        good = false
        @error "Central directory headers present that do not match local headers" missing_headers=values(sort(headers_by_offset))
    end
    # TODO: validate EOCD record(s)
    # Until then, just read to EOF and dump on the floor
    write(devnull, zs)
    # cache result
    zs._valid = good
    return good
end

is_valid!(zs::ZipArchiveSource) = is_valid!(devnull, zs)
