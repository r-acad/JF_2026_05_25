# run_public_suite.jl
#
# Top-level driver for the OpenJFEM public validation suite.
#
# Walks public_suite.yaml, resolves each case's reference value(s),
# (optionally) runs OpenJFEM on each deck, compares JFEM output to the
# reference, and emits two artifacts in this folder:
#     comparison.csv  -- one row per (case, quantity)
#     comparison.md   -- paper-ready summary grouped by family
#
# Usage (from this folder):
#     julia --project=.. run_public_suite.jl                # full run
#     julia --project=.. run_public_suite.jl --verbose      # extra detail
#     julia --project=.. run_public_suite.jl --family classical
#     julia --project=.. run_public_suite.jl --dry-run      # references only,
#                                                           # no JFEM call
#     julia --project=.. run_public_suite.jl --skip-jfem    # alias of --dry-run
#     julia --project=.. run_public_suite.jl --dry-run --no-write

using YAML
using Printf
using Dates
using JSON

const SUITE_ROOT     = @__DIR__
const MANIFEST_PATH  = joinpath(SUITE_ROOT, "public_suite.yaml")
const ANALYTICAL_DIR = joinpath(SUITE_ROOT, "analytical")
const REFERENCES_DIR = joinpath(SUITE_ROOT, "references")
const OUTPUT_CSV     = joinpath(SUITE_ROOT, "comparison.csv")
const OUTPUT_MD      = joinpath(SUITE_ROOT, "comparison.md")

# ---------- argument parsing -------------------------------------------------

mutable struct Opts
    verbose::Bool
    family::Union{Nothing,String}
    skip_jfem::Bool   # if true, references are resolved and a placeholder row
                     # is emitted, but JFEM is not invoked
    write_outputs::Bool
end

function parse_args(args)
    opts = Opts(false, nothing, false, true)
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--verbose"
            opts.verbose = true
        elseif a == "--dry-run" || a == "--skip-jfem"
            opts.skip_jfem = true
        elseif a == "--family"
            i += 1
            i > length(args) && error("--family requires a value")
            opts.family = args[i]
        elseif a == "--no-write"
            opts.write_outputs = false
        else
            error("unknown argument: $a")
        end
        i += 1
    end
    opts
end

# ---------- reference resolution ---------------------------------------------

function load_analytical_module(name::AbstractString)
    path = joinpath(ANALYTICAL_DIR, name * ".jl")
    isfile(path) || error("analytical module not found: $path")
    mod = Module(Symbol("Analytical_" * name))
    Base.include(mod, path)
    mod
end

function resolve_reference(ref::Dict, case_id::AbstractString, opts::Opts)
    kind = get(ref, "kind", nothing)
    if kind === nothing
        error("case $case_id: reference.kind is required")
    end

    if kind == "analytical"
        mod_name = ref["module"]
        fn_name  = ref["fn"]
        mod = load_analytical_module(mod_name)
        # The module (and fn) are defined at runtime via Base.include, so both
        # binding lookup and calling cross the world-age boundary on Julia 1.12.
        fn = Base.invokelatest(getfield, mod, Symbol(fn_name))
        val = Base.invokelatest(fn)
        return (value=Float64(val), source="analytical:$(mod_name).$(fn_name)")
    elseif kind == "csv"
        path = joinpath(REFERENCES_DIR, ref["path"])
        col  = ref["column"]
        row_match = String(get(ref, "row_id", case_id))
        rows = readlines(path)
        header = split(rows[1], ',')
        ix = findfirst(==(col), header)
        ix === nothing && error("case $case_id: column $col not in $path")
        for r in rows[2:end]
            cols = split(r, ',')
            cols[1] == row_match || continue
            return (value=parse(Float64, cols[ix]),
                    source="csv:$(ref["path"])#$row_match.$col")
        end
        error("case $case_id: row '$row_match' not found in $(ref["path"])")
    else
        error("case $case_id: unknown reference kind '$kind'")
    end
end

# ---------- JFEM execution ---------------------------------------------------

const _OPENJFEM_MODULE = Ref{Any}(nothing)

function openjfem_module()
    if _OPENJFEM_MODULE[] === nothing
        Base.invokelatest(Core.eval, @__MODULE__, :(using OpenJFEM))
        _OPENJFEM_MODULE[] = Base.invokelatest(getfield, @__MODULE__, :OpenJFEM)
    end
    return _OPENJFEM_MODULE[]
end

# Run one deck through OpenJFEM (JSON output, no binary/report) into a temp dir
# and return a state dict the extractor can read. `--skip-jfem` still short-
# circuits to a "skipped" sentinel so references can be resolved offline.
function run_jfem(case::Dict, opts::Opts)
    if opts.skip_jfem
        return Dict("status" => "skipped",
                    "note"   => "JFEM run skipped (--skip-jfem)")
    end
    deck = joinpath(SUITE_ROOT, case["bdf"])
    isfile(deck) || return Dict("status" => "error",
                                "note" => "deck not found: $deck")
    out = mktempdir(; prefix = "jfem_suite_")
    try
        jfem = openjfem_module()
        redirect_stdout(devnull) do
            redirect_stderr(devnull) do
                Base.invokelatest(jfem.main, deck; output_dir = out,
                                  export_jfem_binary = false,
                                  export_json = true,
                                  export_report = false)
            end
        end
    catch e
        return Dict("status" => "error",
                    "note" => "JFEM run failed: $(sprint(showerror, e))")
    end
    # Load whichever per-SOL results JSON was produced.
    jsons = filter(f -> endswith(f, ".JU.JSON") || endswith(f, ".BUCKLING.JSON") ||
                        endswith(f, ".NONLINEAR.JSON"), readdir(out; join = true))
    isempty(jsons) && return Dict("status" => "error",
                                  "note" => "no results JSON written")
    data = try
        JSON.parsefile(jsons[1])
    catch e
        return Dict("status" => "error", "note" => "JSON parse failed: $(sprint(showerror, e))")
    end
    return Dict("status" => "ok", "data" => data, "out_dir" => out)
end

# Map dof index 1..6 to the displacement-object field name.
const _DOF_FIELD = Dict(1 => "t1", 2 => "t2", 3 => "t3", 4 => "r1", 5 => "r2", 6 => "r3")

# Extract the scalar JFEM value for one quantity from the loaded results data.
# Returns (value::Union{Float64,Nothing}, note::String).
function extract_quantity(data::AbstractDict, q::AbstractDict)
    kind = get(q, "kind", "")
    sel  = get(q, "selector", Dict())
    if kind == "eigenvalue"
        evs = get(data, "eigenvalues", nothing)
        evs === nothing && return (nothing, "no eigenvalues in JFEM output")
        mode = Int(get(sel, "mode", 1))
        # SOL105 buckling factors: compare on the smallest-magnitude positive root
        # is handled by the solver's ordering; here mode index is 1-based into the
        # reported list. Use |value| so a sign convention does not mask parity
        # (documented: buckling load factors are positive multipliers).
        vals = Float64.(evs)
        mode <= length(vals) || return (nothing, "mode $mode > $(length(vals)) returned")
        return (vals[mode], "")
    elseif kind == "displacement" || kind == "static_preload_displacement"
        # `displacement`               -> the SOL 101 displacement vector.
        # `static_preload_displacement`-> the SOL 105 STATSUB preload field,
        #    which the buckling export emits under `static_displacements`. It
        #    is a well-posed same-deck quantity on a case whose buckling
        #    eigenvalue the reference solver cannot extract reliably; see
        #    README.md, "Tabulated commercial-solver values".
        key = kind == "displacement" ? "displacements" : "static_displacements"
        disps = get(data, key, nothing)
        disps === nothing && return (nothing, "no $key in JFEM output")
        node = Int(get(sel, "node", 0))
        dof  = Int(get(sel, "dof", 1))
        field = get(_DOF_FIELD, dof, nothing)
        field === nothing && return (nothing, "bad dof $dof")
        for d in disps
            if Int(get(d, "grid_id", -1)) == node
                return (Float64(get(d, field, 0.0)), "")
            end
        end
        return (nothing, "node $node not found in $key")
    else
        return (nothing, "unsupported quantity kind '$kind'")
    end
end

# ---------- comparison and emit ---------------------------------------------

struct ResultRow
    case_id::String
    family::String
    sol::Int
    quantity::String
    jfem::Union{Nothing,Float64}
    reference::Union{Nothing,Float64}
    ref_source::String
    abs_err::Union{Nothing,Float64}
    rel_err::Union{Nothing,Float64}
    tol_rel::Union{Nothing,Float64}
    verdict::String
    # Parity block: an independent second reference measuring agreement with
    # an established solver on the SAME deck and mesh. Empty / nothing when the
    # quantity declares no `parity`. Never feeds `verdict`.
    parity_ref::Union{Nothing,Float64}
    parity_source::String
    parity_rel_err::Union{Nothing,Float64}
    parity_tol::Union{Nothing,Float64}
    parity_verdict::String
    note::String
end

# Convenience for the placeholder rows that carry no comparison at all.
ResultRow(case_id, family, sol, quantity, jfem, reference, ref_source,
          abs_err, rel_err, tol_rel, verdict, note) =
    ResultRow(case_id, family, sol, quantity, jfem, reference, ref_source,
              abs_err, rel_err, tol_rel, verdict,
              nothing, "", nothing, nothing, "", note)

function build_row(case::Dict, q::Dict, jfem_state::Dict, opts::Opts)
    case_id = case["id"]
    family  = case["family"]
    sol     = case["sol"]
    qname   = q["name"]
    tol     = get(q, "tol_rel", nothing)
    ref     = get(q, "reference", nothing)

    # Extract the JFEM value FIRST so it is always recorded - even if the
    # reference fails to resolve. This makes the suite a genuine regression net:
    # a value change is visible (and diffable) regardless of reference state.
    jfem_val = nothing
    note     = ""
    verdict  = "PENDING"
    status   = get(jfem_state, "status", "")
    if status == "skipped"
        note    = get(jfem_state, "note", "")
        verdict = "JFEM_SKIPPED"
    elseif status == "error"
        note    = get(jfem_state, "note", "")
        verdict = "ERROR_JFEM"
    elseif status == "ok"
        jv, jnote = extract_quantity(jfem_state["data"], q)
        jfem_val = jv
        if jv === nothing
            note    = jnote
            verdict = "ERROR_EXTRACT"
        end
    end

    # Resolve the reference (may fail independently of JFEM execution).
    ref_val, ref_src = (nothing, "")
    if ref !== nothing
        try
            r = resolve_reference(ref, case_id, opts)
            ref_val = r.value
            ref_src = r.source
        catch e
            # Keep the JFEM value; flag the reference as unresolved.
            if verdict in ("PENDING",)
                verdict = "ERROR_REF"
            end
            note = isempty(note) ? "reference resolution failed: $(sprint(showerror, e))" :
                   note * " | ref failed: $(sprint(showerror, e))"
        end
    end

    # Compare on |value| for eigenvalues (buckling factors are positive
    # multipliers; a solver sign convention should not mask magnitude parity).
    # Some classical displacement references are explicitly reported as
    # magnitudes; those cases opt in with compare_abs.
    use_abs_compare = get(q, "kind", "") == "eigenvalue" || Bool(get(q, "compare_abs", false))
    cmp_jfem = (jfem_val !== nothing && use_abs_compare) ? abs(jfem_val) : jfem_val
    cmp_ref  = (ref_val !== nothing && use_abs_compare) ? abs(ref_val) : ref_val
    abs_err = (cmp_jfem !== nothing && cmp_ref !== nothing) ? abs(cmp_jfem - cmp_ref) : nothing
    rel_err = (abs_err !== nothing && cmp_ref !== nothing && abs(cmp_ref) > 1e-30) ?
              abs_err / abs(cmp_ref) : nothing
    if jfem_val !== nothing && tol !== nothing && rel_err !== nothing
        verdict = rel_err <= tol ? "PASS" : "FAIL"
    end

    # ---- parity: independent second reference, scored independently --------
    # A parity gap is a formulation difference (same deck, same mesh, so the
    # discretisation error cancels); an accuracy gap is not. Keeping the two
    # apart is the point, so a parity failure NEVER touches `verdict`, and a
    # parity reference that will not resolve degrades to an empty column
    # instead of failing the row.
    parity      = get(q, "parity", nothing)
    parity_val  = nothing
    parity_src  = ""
    parity_tol  = parity === nothing ? nothing : get(parity, "tol_rel", nothing)
    parity_rel  = nothing
    parity_verd = ""
    if parity !== nothing
        try
            p = resolve_reference(parity, case_id, opts)
            parity_val = p.value
            parity_src = p.source
        catch e
            parity_verd = "ERROR_PARITY_REF"
            note = isempty(note) ? "parity reference resolution failed: $(sprint(showerror, e))" :
                   note * " | parity ref failed: $(sprint(showerror, e))"
        end
        cmp_par = (parity_val !== nothing && use_abs_compare) ? abs(parity_val) : parity_val
        if cmp_jfem !== nothing && cmp_par !== nothing && abs(cmp_par) > 1e-30
            parity_rel = abs(cmp_jfem - cmp_par) / abs(cmp_par)
            if parity_tol !== nothing
                parity_verd = parity_rel <= parity_tol ? "PARITY_PASS" : "PARITY_FAIL"
            end
        elseif isempty(parity_verd)
            parity_verd = jfem_val === nothing ? "PARITY_NO_JFEM" : "PARITY_PENDING"
        end
    end

    return ResultRow(case_id, family, sol, qname,
                     jfem_val, ref_val, ref_src,
                     abs_err, rel_err, tol,
                     verdict,
                     parity_val, parity_src, parity_rel, parity_tol, parity_verd,
                     note)
end

function emit_csv(rows::Vector{ResultRow})
    csvcell(x) = begin
        s = string(x)
        if occursin(",", s) || occursin("\"", s) || occursin("\n", s) || occursin("\r", s)
            return "\"" * replace(s, "\"" => "\"\"") * "\""
        end
        return s
    end
    open(OUTPUT_CSV, "w") do io
        println(io, "case_id,family,sol,quantity,jfem,reference,ref_source,abs_err,rel_err,tol_rel,verdict," *
                    "parity_ref,parity_source,parity_rel_err,parity_tol_rel,parity_verdict,note")
        for r in rows
            fnum(x) = x === nothing ? "" : @sprintf("%.12g", x)
            println(io, join(csvcell.([r.case_id, r.family, string(r.sol), r.quantity,
                                       fnum(r.jfem), fnum(r.reference), r.ref_source,
                                       fnum(r.abs_err), fnum(r.rel_err), fnum(r.tol_rel),
                                       r.verdict,
                                       fnum(r.parity_ref), r.parity_source,
                                       fnum(r.parity_rel_err), fnum(r.parity_tol),
                                       r.parity_verdict,
                                       r.note]), ","))
        end
    end
end

function emit_md(rows::Vector{ResultRow})
    families = unique(r.family for r in rows)
    open(OUTPUT_MD, "w") do io
        println(io, "# OpenJFEM Public Validation Suite -- Comparison Report")
        println(io)
        println(io, "Generated: ", Dates.now())
        println(io)
        n = length(rows)
        npass = count(r -> r.verdict == "PASS", rows)
        nfail = count(r -> r.verdict == "FAIL", rows)
        nskip = count(r -> r.verdict == "JFEM_SKIPPED", rows)
        nerr  = count(r -> startswith(r.verdict, "ERROR"), rows)
        nppass = count(r -> r.parity_verdict == "PARITY_PASS", rows)
        npfail = count(r -> r.parity_verdict == "PARITY_FAIL", rows)
        nprow  = count(r -> r.parity_ref !== nothing, rows)
        println(io, "Summary: $n quantity rows ($npass PASS, $nfail FAIL, $nskip JFEM_SKIPPED, $nerr ERROR_REF)")
        println(io)
        println(io, "Parity: $nprow of $n rows carry a reference-solver parity target ($nppass PARITY_PASS, $npfail PARITY_FAIL)")
        println(io)
        println(io, "Accuracy (`reference`, `rel_err`, `verdict`) asks whether OpenJFEM is close to the")
        println(io, "published or closed-form value for the problem. Parity (`parity_*`) asks whether it")
        println(io, "reproduces what an established solver produces on the SAME deck and mesh, where the")
        println(io, "discretisation error is common to both sides and cancels. They are independent: a")
        println(io, "parity result never changes the accuracy verdict, and vice versa.")
        println(io)
        for fam in families
            println(io, "## Family: $fam")
            println(io)
            println(io, "| case_id | quantity | reference | JFEM | rel_err | tol | verdict | parity ref | parity rel_err | parity tol | parity |")
            println(io, "| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |")
            for r in rows
                r.family == fam || continue
                fnum(x) = x === nothing ? "" : @sprintf("%.6g", x)
                println(io, "| $(r.case_id) | $(r.quantity) | $(fnum(r.reference)) | $(fnum(r.jfem)) | $(fnum(r.rel_err)) | $(fnum(r.tol_rel)) | $(r.verdict) | $(fnum(r.parity_ref)) | $(fnum(r.parity_rel_err)) | $(fnum(r.parity_tol)) | $(r.parity_verdict) |")
            end
            println(io)
        end
        if nskip > 0
            println(io, "_Note: JFEM_SKIPPED rows indicate the reference is resolved but JFEM was not invoked on this run (`--dry-run` / `--skip-jfem`). Re-run without those flags to populate the JFEM column._")
        end
        if nprow < n
            println(io, "_Note: rows with an empty parity column declare no `parity` block in `public_suite.yaml` -- no reference-solver value has been verified for that quantity. An empty parity cell means unmeasured, not passing._")
        end
    end
end

# ---------- main -------------------------------------------------------------

function main(args)
    opts = parse_args(args)
    isfile(MANIFEST_PATH) || error("manifest not found: $MANIFEST_PATH")
    cases = YAML.load_file(MANIFEST_PATH)

    rows = ResultRow[]
    for case in cases
        if opts.family !== nothing && case["family"] != opts.family
            continue
        end
        case_id = case["id"]
        opts.verbose && println("==> $case_id")

        # Skip cases that are pending_fetch or deferred (no quantities defined).
        case_status = get(case, "status", nothing)
        if case_status in ("pending_fetch", "deferred")
            verdict = case_status == "pending_fetch" ? "PENDING_FETCH" : "DEFERRED"
            note = case_status == "pending_fetch" ?
                "case material not yet present; see family README" :
                get(case, "notes", "case deferred; see family README")
            push!(rows, ResultRow(case_id, case["family"], case["sol"], "(none)",
                                  nothing, nothing, "",
                                  nothing, nothing, nothing,
                                  verdict, note))
            continue
        end

        jfem_state = run_jfem(case, opts)
        for q in get(case, "quantities", [])
            push!(rows, build_row(case, q, jfem_state, opts))
        end
    end

    if opts.write_outputs
        emit_csv(rows)
        emit_md(rows)
        println("\nWrote $(length(rows)) rows to:")
        println("  $OUTPUT_CSV")
        println("  $OUTPUT_MD")
    else
        n = length(rows)
        npass = count(r -> r.verdict == "PASS", rows)
        nfail = count(r -> r.verdict == "FAIL", rows)
        nskip = count(r -> r.verdict == "JFEM_SKIPPED", rows)
        nerr  = count(r -> startswith(r.verdict, "ERROR"), rows)
        nppass = count(r -> r.parity_verdict == "PARITY_PASS", rows)
        npfail = count(r -> r.parity_verdict == "PARITY_FAIL", rows)
        nprow  = count(r -> r.parity_ref !== nothing, rows)
        println("\nChecked $n rows without writing outputs ($npass PASS, $nfail FAIL, $nskip JFEM_SKIPPED, $nerr ERROR)")
        println("Parity targets resolved on $nprow/$n rows ($nppass PARITY_PASS, $npfail PARITY_FAIL)")
    end
end

main(ARGS)
