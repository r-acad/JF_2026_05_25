# Run from the repository root with --project=.; this command does not solve a
# model. Both JSON files contain a root array or an object with "eigenvalues".
using OpenJFEM, JSON

function compare_spectra_main(args)
    length(args) >= 3 || error("Usage: julia --project=. utils/julia_tools/compare_spectra.jl reference.json candidate.json comparison.json [--relative-tolerance=0.005] [--absolute-tolerance=0] [--zero-tolerance=0] [--lower=value] [--upper=value]")
    reference_path,candidate_path,output_path = abspath.(args[1:3])
    output_path in (reference_path,candidate_path) && error("The comparison output must not overwrite an input")
    isfile(output_path) && error("Comparison output already exists; choose a new path")
    options = Dict{Symbol,Float64}()
    names = Dict("relative-tolerance"=>:relative_tolerance,"absolute-tolerance"=>:absolute_tolerance,
        "zero-tolerance"=>:zero_tolerance,"lower"=>:lower,"upper"=>:upper)
    for arg in args[4:end]
        m = match(r"^--([a-z-]+)=(.+)$",arg)
        m !== nothing && haskey(names,m[1]) || error("Unknown option: $arg")
        key = names[m[1]]
        haskey(options,key) && error("Repeated option: $(m[1])")
        options[key] = parse(Float64,m[2])
    end
    function roots(path)
        data = JSON.parsefile(path)
        values = data isa AbstractVector ? data : get(data,"eigenvalues",nothing)
        values isa AbstractVector || error("$path must contain a root array or an eigenvalues array")
        values
    end
    report = compare_eigenvalue_spectra(roots(reference_path),roots(candidate_path);options...)
    report["reference_file"] = reference_path
    report["candidate_file"] = candidate_path
    open(output_path,"w") do io
        JSON.print(io,report,2)
        println(io)
    end
    println(report["status"], ": ",length(report["within_tolerance_matches"]),
        " matched within tolerance; ", report["eligible_reference_count"]," reference / ",
        report["eligible_candidate_count"]," candidate roots. Report: ",output_path)
    report["pass"] ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(compare_spectra_main(ARGS))
end
