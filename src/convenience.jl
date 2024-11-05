"""
    zip_files(out_filename, files; [keyword_args])
    zip_files(out_filename, dir; recurse_directories=false, [keyword_args])

Create an archive from files on disk.

The archive `out_filename` will be created using the `zipsink` method with the keyword
arguments split as listed below. `in_filename` can be a single path or a vector of multiple
paths on disk. The files will be written in the archive with paths matching the closest
common relative path between the current directory (`"."`) and the full path of the file, so
if `archive_filename` is "/a/b/archive.zip" and one of `files` is "/a/c/file", then the file
will be witten with the path "c/file".

If `dir` is a directory and `recurse_directories` is `true`, then all files and directories
found when traversing the directory will be added to the archive. If `recurse_directories`
is `false` (the default), then subdirectories of `dir` will not be traversed.

All files are written to the archive using the default arguments specified by
`open(zipsink, fn; keyword_args..)`, with special keyword arguments split as described
below.

# Arguments
- `out_filename::AbstractString`: the output archive filename to create.
- `files::AbstractVector{<:AbstractString}`: a list of file paths to add to the newly
    created archive.
- `dir::AbstractString`: a path to a directory to add to the newly created archive.

# Keyword arguments
- `utf8::Bool = true`: use UTF-8 encoding for file names (if `false`, use IBM437).
- `archive_comment::AbstractString = ""`: archive comment string to add to the central
    directory, equivalent to passing the `comment` keyword to `zipsink`.
- `file_options::Dict{String, Any} = nothing`: if a file name added to the archive _exactly_
    matches (`==`) a key in `file_options`, then the value corresponding to that key will be
    splatted as keyword arguments for that file only, overriding keyword arguments passed as
    described below.
- All other keyword arguments: passed unmodified to the `open(sink, filename)` method.

See [`open(::ZipArchiveSink, ::AbstractString)`](@ref) and [`zipsink`](@ref) for more
information about the optional keyword arguments available for each method.
"""
function zip_files(archive_filename::AbstractString, input_filenames::AbstractVector{<:AbstractString}; utf8::Bool=true, archive_comment::AbstractString="", kwargs...)
    file_options, global_kwargs = TranscodingStreams.splitkwargs(kwargs, (:file_options,))
    zipsink(archive_filename; utf8=utf8, comment=archive_comment) do sink
        for filename in input_filenames
            # pull out file options and override global_kwargs, if possible
            file_kwargs = Dict{Symbol, Any}(pairs(global_kwargs))
            if !isempty(file_options) && filename in keys(file_options)
                push!(file_kwargs, pairs(file_options[filename])...)
            end
            # note: relpath treats path elements with different casing as different, even on case-insensitive filesystems
            # this can be a problem if, e.g., tempdir() and pwd() return path elements with different cases
            # so we have to make sure to normalize the paths
            rpath = relpath(normpath(realpath(filename)), normpath(pwd()))
            clean_path = strip_dots(rpath)
            if isdir(filename)
                mkpath(sink, clean_path)
            else
                open(filename, "r") do io
                    open(sink, clean_path; make_path=true, file_kwargs...) do fsink
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
            if !isempty(files_to_extract) && info(file).name ∉ files_to_extract
                continue
            end
            dirs = split(info(file).name, ZIP_PATH_DELIMITER)[1:end-1]
            if !isempty(dirs)
                mkpath(joinpath(output_path, dirs...))
            end
            open(joinpath(output_path, info(file).name), "w") do io
                write(io, file)
            end
        end
    end
    return
end

unzip_files(archive_filename::AbstractString, file::AbstractString; kwargs...) = unzip_files(archive_filename, [file]; kwargs...)
unzip_file(archive_filename::AbstractString, file::AbstractString; kwargs...) = unzip_files(archive_filename, [file]; kwargs...)