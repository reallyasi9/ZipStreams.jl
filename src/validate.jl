
"""
    validate(zf::ZipFileSource) -> Nothing

Validate that the contents read from an archived file match the information stored
in the Local File Header.

If the contents of the file do not match the information in the Local File Header, the
method will throw an error. The method checks that the compressed and uncompressed file
sizes match what is in the header and that the CRC-32 of the uncompressed data matches what
is reported in the header.

Validation will work even on files that have been partially read.
"""
function validate(zf::ZipFileSource)
    # read the remainder of the file
    read(zf)
    if !eof(zf)
        error("EOF not reached in file $(info(zf).name)")
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
        @debug "validation succeeded"
        return nothing
    end

    if bytes_in(zf) != i.compressed_size
        error("Compressed size check failed: expected $(i.compressed_size), got $(bytes_in(zf))")
    end
    if bytes_out(zf) != i.uncompressed_size
        error("Uncompressed size check failed: expected $(i.uncompressed_size), got $(bytes_out(zf))")
    end
    if zf.source.crc32 != i.crc32
        error("CRC-32 check failed: expected $(string(i.crc32; base=16)), got $(string(zf.source.crc32; base=16))")
    end
    @debug "validation succeeded"
    return nothing
end


"""
    validate(source::ZipArchiveSource) -> Nothing

Validate the files in the archive `source` against the Central Directory at the end of
the archive.

This method consumes _all_ the remaining data in the source stream of `source` and throws an
exception if the file information from the file headers read does not match the information
in the Central Directory. Files that have already been consumed prior to calling this method
will still be validated.

!!! warning "Files using descriptors"
    If a file stored within `source` uses a File Descriptor rather than storing the size of the file
    in the Local File Header, the file must be read to the end in order to properly record the
    lengths for checking against the Central Directory. Failure to read such a file to the end will
    result in an error being thrown when `validate` is called on the archive.

See also [`validate(::ZipFileSource)`](@ref).
"""
function validate(zs::ZipArchiveSource)
    # validate remaining files
    for file in zs
        validate(file)
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
                error("central directory contains multiple entries with the same offset: $(cd_info) would override $(headers_by_offset[cd_info.offset])")
            end
            if cd_info.info.name in keys(headers_by_name)
                error("central directory contains multiple entries with the same file name: $(cd_info) would override $(headers_by_name[cd_info.info.name])")
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
            error("file at offset $lf_offset not in central directory: $(lf_info_ref[])")
        end
        if lf_info_ref[].name in names_read
            error("multiple files with name $(lf_info_ref[].name) read")
        end
        cd_info = headers_by_offset[lf_offset]
        if !is_consistent(cd_info.info, lf_info_ref; check_sizes=true)
            error("discrepancy detected in file at offset $lf_offset: central directory reports $(cd_info.info), local file header reports $(lf_info_ref[])")
        end
        # delete headers from the central directory dict to check for duplicates or missing files
        delete!(headers_by_offset, lf_offset)
        push!(names_read, lf_info_ref[].name)
    end
    # Report if there are files we didn't read
    if !isempty(headers_by_offset)
        missing_file_infos = join(string.(values(sort(headers_by_offset))))
        error("files present in central directory but not read: $missing_file_infos")
    end
    # TODO: validate EOCD record(s)
    # Until then, just read to EOF
    read(zs)
    return nothing
end