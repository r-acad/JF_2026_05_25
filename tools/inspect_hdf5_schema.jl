using HDF5
using Printf

function csv_escape(x)
    s = string(x)
    return "\"" * replace(s, "\"" => "\"\"") * "\""
end

function shape_string(ds)
    try
        return join(size(ds), "x")
    catch
        return ""
    end
end

function type_and_fields(ds)
    data = read(ds)
    t = eltype(data)
    fields = try
        join(string.(fieldnames(t)), ";")
    catch
        ""
    end
    return string(t), fields, length(data)
end

function dataset_preview(ds; nmax=3)
    data = read(ds)
    n = length(data)
    n == 0 && return "[]"
    rows = Any[]
    for i in 1:min(nmax, n)
        push!(rows, data[i])
    end
    return repr(rows)
end

function walk_schema(obj, path, rows, tree_lines; depth=0)
    for key in sort(collect(keys(obj)))
        child = obj[key]
        child_path = path == "/" ? "/" * key : path * "/" * key
        indent = repeat("  ", depth)
        if child isa HDF5.Dataset
            dtype, fields, nrows = type_and_fields(child)
            shape = shape_string(child)
            push!(rows, (child_path, shape, dtype, nrows, fields))
            push!(tree_lines, @sprintf("%s- %s  dataset shape=%s rows=%d", indent, child_path, shape, nrows))
        elseif child isa HDF5.Group
            push!(tree_lines, @sprintf("%s- %s/  group", indent, child_path))
            walk_schema(child, child_path, rows, tree_lines; depth=depth + 1)
        else
            push!(tree_lines, @sprintf("%s- %s  %s", indent, child_path, typeof(child)))
        end
    end
end

function inspect_file(h5_path::String, outdir::String)
    stem = splitext(basename(h5_path))[1]
    rows = Tuple{String,String,String,Int,String}[]
    tree_lines = String["# HDF5 Tree: $(basename(h5_path))", ""]
    previews = String["# Selected Dataset Preview: $(basename(h5_path))", ""]

    h5open(h5_path, "r") do f
        walk_schema(f, "/", rows, tree_lines)

        wanted = [
            "/NASTRAN/INPUT/DOMAINS",
            "/NASTRAN/RESULT/DOMAINS",
            "/NASTRAN/RESULT/SUMMARY/EIGENVALUE",
            "/NASTRAN/RESULT/NODAL/DISPLACEMENT",
            "/NASTRAN/RESULT/NODAL/EIGENVECTOR",
            "/INDEX/NASTRAN/RESULT/NODAL/DISPLACEMENT",
            "/INDEX/NASTRAN/RESULT/NODAL/EIGENVECTOR",
        ]
        for p in wanted
            if haskey(f, p)
                push!(previews, "## $p")
                push!(previews, "")
                push!(previews, "```text")
                push!(previews, dataset_preview(f[p]))
                push!(previews, "```")
                push!(previews, "")
            end
        end
    end

    tree_path = joinpath(outdir, stem * "_tree.md")
    csv_path = joinpath(outdir, stem * "_datasets.csv")
    preview_path = joinpath(outdir, stem * "_selected_previews.md")

    open(tree_path, "w") do io
        println(io, join(tree_lines, "\n"))
    end

    open(csv_path, "w") do io
        println(io, join(["path", "shape", "eltype", "rows", "fields"], ","))
        for (path, shape, dtype, nrows, fields) in rows
            println(io, join(csv_escape.([path, shape, dtype, nrows, fields]), ","))
        end
    end

    open(preview_path, "w") do io
        println(io, join(previews, "\n"))
    end

    return length(rows), tree_path, csv_path, preview_path
end

function main()
    if length(ARGS) < 1
        error("usage: julia --project=JFEM JFEM/tools/inspect_hdf5_schema.jl <folder-or-h5> [output_dir]")
    end

    input = abspath(ARGS[1])
    outdir = length(ARGS) >= 2 ? abspath(ARGS[2]) : joinpath(isdir(input) ? input : dirname(input), "_hdf5_schema_inspection")
    mkpath(outdir)

    h5_files = if isdir(input)
        sort(filter(p -> lowercase(splitext(p)[2]) in [".h5", ".hdf5"], readdir(input; join=true)))
    else
        [input]
    end

    summary = String["# HDF5 Schema Inspection Summary", ""]
    for h5_path in h5_files
        nrows, tree_path, csv_path, preview_path = inspect_file(h5_path, outdir)
        push!(summary, "- $(basename(h5_path)): $nrows datasets")
        push!(summary, "  - tree: $(basename(tree_path))")
        push!(summary, "  - datasets: $(basename(csv_path))")
        push!(summary, "  - previews: $(basename(preview_path))")
    end

    open(joinpath(outdir, "README.md"), "w") do io
        println(io, join(summary, "\n"))
    end

    println("Wrote HDF5 schema inspection to ", outdir)
end

main()
