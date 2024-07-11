"""
    zip_files(out_filename, files; [keyword_args])
    zip_files(out_filename, dir; recurse_directories=false, [keyword_args])

Create an archive from files on disk.

The archive `out_filename` will be created using the `zipsink` method with the given keyword
arguments. `in_filename` can be a single path or a vector of multiple paths on disk. The
files will be written in the archive with paths matching the closest common relative path
between the current directory (`"."`) and the full path of the file, so if `archive_filename`
is "/a/b/archive.zip" and one of `files` is "/a/c/file", then the file will be witten
with the path "c/file".

If `dir` is a directory and `recurse_directories` is `true`, then all files and directories found when
traversing the directory will be added to the archive. If `recurse_directories` is `false` (the
default), then subdirectories of `dir` will not be traversed.

All files are written to the archive using the default arguments specified by
`open(zipsink, fn)`. See [`open(::ZipArchiveSink, ::AbstractString)`](@ref) for more information.

See [`zipsink`](@ref) for more information about the optional keyword arguments.
"""
function zip_files(archive_filename::AbstractString, input_filenames::AbstractVector{<:AbstractString}; kwargs...)
    zipsink(archive_filename; kwargs...) do sink
        for filename in input_filenames
            rpath = relpath(filename) # relative to . by default
            clean_path = strip_dots(rpath)
            if isdir(filename)
                mkpath(sink, clean_path)
            else
                open(filename, "r") do io
                    open(sink, clean_path; make_path=true) do fsink
                        write(fsink, io)
                    end
                end
            end
        end
    end
    return
end

recurse_all_files(path::AbstractString) = mapreduce(((root, dirs, files),) -> joinpath.(Ref(root), files), vcat, walkdir(path))

function zip_files(archive_filename::AbstractString, input_filename::AbstractString; recurse_directories::Bool=false, kwargs...)
    if isdir(input_filename)
        if recurse_directories
            files = recurse_all_files(input_filename)
        else
            files = filter(x -> !isdir(x), readdir(input_filename; join=true))
        end
    else
        files = [input_filename]
    end
    zip_files(archive_filename, files; kwargs...)
end

zip_file(archive_filename::AbstractString, input_filename::AbstractString; kwargs...) = zip_files(archive_filename, [input_filename]; kwargs...)

function strip_dots(path::AbstractString)
    first_non_dot_idx = 1
    # This takes filesystem paths and not ZIP archive paths, so use splitpath
    dirs = splitpath(path)
    first_non_dot_idx = findfirst(dir -> dir != "." && dir != "..", dirs)
    return join(dirs[first_non_dot_idx:end], ZIP_PATH_DELIMITER)
end

"""
    unzip_files(archive; output_path::AbstractString=".", make_path::Bool=false)
    unzip_files(archive, files; [keyword_args])

Unzip `files` from `archive`. If `files` is not given, extract all files.

This method opens the archive and iterates through the archived files, writing them to disk
to the directory tree rooted at `output_path`. If `make_path` is `true` and `output_path`
does not exist, it will be created.

See [`zipsource`](@ref) and [`next_file`](@ref) for more information about how the files are
read from the archive.
"""
function unzip_files(archive_filename::AbstractString, files::AbstractVector{<:AbstractString}=String[]; output_path::AbstractString=".", make_path::Bool=false)
    if make_path
        mkpath(output_path)
    end
    files_to_extract = Set(files)
    zipsource(archive_filename) do source
        for file in source
            if !isempty(files_to_extract) && file.info.name ∉ files_to_extract
                continue
            end
            dirs = split(file.info.name, ZIP_PATH_DELIMITER)[1:end-1]
            if !isempty(dirs)
                mkpath(joinpath(output_path, dirs...))
            end
            # io = open(joinpath(output_path, file.info.name), "w")
            # write(io, file)
            # close(io)
            open(joinpath(output_path, file.info.name), "w") do io
                write(io, file)
            end
        end
    end
    return
end

unzip_files(archive_filename::AbstractString, file::AbstractString; kwargs...) = unzip_files(archive_filename, [file]; kwargs...)
unzip_file(archive_filename::AbstractString, file::AbstractString; kwargs...) = unzip_files(archive_filename, [file]; kwargs...)