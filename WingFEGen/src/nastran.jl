# ===========================================================================
#  nastran.jl - NASTRAN bulk data writer
#
#  Output is small field (eight column) fixed format with explicit "+"
#  continuations, which every NASTRAN-compatible reader accepts. Reals are
#  formatted by `nas_real` so that each one carries the most precision that
#  fits in eight columns, falling back to the NASTRAN exponent form
#  ("7.100+10") outside the fixed-point range.
#
#  Cards written: GRID, CORD2R, CQUAD4, CTRIA3, CBAR, PSHELL, PBARL, PBAR, MAT1, RBE3, SPC1 and
#  EIGRL (SOL 103/105), FORCE and MOMENT in independent case load sets.
# ===========================================================================

"""
    nas_real(v) -> String

Format a real into exactly eight columns, keeping as many significant digits
as will fit.
"""
function nas_real(v::Real)
    x = Float64(v)
    isfinite(x) || throw(ArgumentError("cannot write non-finite real to a NASTRAN field"))
    x == 0.0 && return "     0.0"
    a = abs(x)
    if 1.0e-3 <= a < 1.0e5
        for nd in 6:-1:1
            s = Printf.format(Printf.Format("%.$(nd)f"), x)
            length(s) <= 8 && return lpad(s, 8)
        end
    end
    # NASTRAN exponent form without the letter E, for example 1.2000-4
    ex = floor(Int, log10(a))
    mant = x / 10.0^ex
    if abs(mant) >= 10.0        # guard the rounding edge
        mant /= 10.0
        ex += 1
    end
    es = string(ex < 0 ? "-" : "+", abs(ex))
    for nd in 5:-1:0
        s = string(Printf.format(Printf.Format("%.$(nd)f"), mant), es)
        length(s) <= 8 && return lpad(s, 8)
    end
    throw(ArgumentError("cannot fit $x into an eight column NASTRAN field"))
end

"""
    nas_field(x) -> String

Format one small-field entry. `nothing` writes a blank field.
"""
nas_field(::Nothing) = "        "
function nas_field(x::Integer)
    s = string(x)
    length(s) <= 8 || throw(ArgumentError("integer $x does not fit in a NASTRAN field"))
    return lpad(s, 8)
end
nas_field(x::AbstractFloat) = nas_real(x)
function nas_field(x::AbstractString)
    length(x) <= 8 || throw(ArgumentError("string $x does not fit in a NASTRAN field"))
    return rpad(x, 8)
end

"""
    card!(io, name, fields)

Write one bulk data card, continuing onto "+" lines after the first eight
data fields and eight more on every continuation.

`fields` must be a tuple or an `Any` vector. A plain array literal mixing
integers and reals would promote the integers to `Float64` and the card would
come out with grid and property ids written as reals.
"""
function card!(io::IO, name::AbstractString, fields)
    if get(io,:full_precision,false)
        # Sensitivity decks retain the requested perturbation exactly. Fixed
        # eight-column rounding can otherwise dominate small differences.
        all(v->!(v isa Real)||isfinite(v),fields)||throw(ArgumentError("cannot write non-finite real to a NASTRAN field"))
        for first_field in 1:8:max(1,length(fields))
            values=[v===nothing ? "" : string(v) for v in fields[first_field:min(first_field+7,length(fields))]]
            println(io,join(vcat(first_field==1 ? String(name) : "+",values),","))
        end
        return nothing
    end
    n = length(fields)
    line = rpad(name, 8) * join(nas_field(fields[i]) for i in 1:min(8, n))
    println(io, rstrip(line))
    i = 9
    while i <= n
        line = rpad("+", 8) * join(nas_field(fields[j]) for j in i:min(i + 7, n))
        println(io, rstrip(line))
        i += 8
    end
    return nothing
end

comment!(io::IO, text::AbstractString) = println(io, "\$ ", text)

function banner!(io::IO, text::AbstractString)
    println(io, "\$" * "-"^79)
    println(io, "\$ ", text)
    println(io, "\$" * "-"^79)
end

"""
    bar_inertia(area, given) -> Float64

Bar bending inertia. A non-positive input means take the equivalent square
section, A^2 / 12.
"""
bar_inertia(area::Float64, given::Float64) = given > 0 ? given : area^2 / 12.0

"""
    find_node(m, i, j, k) -> Int

NASTRAN id of the structural grid with index triple `(i, j, k)`, or zero when
that triple is not part of the model.
"""
function find_node(m::Model, i::Int, j::Int, k::Int)
    idx = findfirst(==((i, j, k)), m.node_keys)
    return idx === nothing ? 0 : m.node_ids[idx]
end

"""
    lift_fraction(kind, taper, eta) -> Float64

Fraction of the semi-span lift carried inboard of span station `eta`, for the
three spanwise distributions. Each one integrates to exactly 1 at the tip, so
the station forces always sum to the requested total.

    elliptical   f(e) = (4/pi) sqrt(1 - e^2)
    chord        f(e) proportional to the local chord
    uniform      f(e) = 1
"""
function lift_fraction(kind::AbstractString, taper::Float64, eta::Float64)
    e = clamp(eta, 0.0, 1.0)
    if kind == "elliptical"
        return (2.0 / pi) * (e * sqrt(max(1.0 - e^2, 0.0)) + asin(e))
    elseif kind == "chord"
        return 2.0 * (e - 0.5 * (1.0 - taper) * e^2) / (1.0 + taper)
    else
        return e
    end
end

"""
    lift_forces(m) -> Vector{Tuple{Int,Float64,Float64}}

The lift load set: one vertical force per RBE3 station, as
`(grid id, force in N, span station)`.

Each station carries the lift of its tributary strip, bounded by the midpoints
to its neighbours, so the forces sum to `lift_total * load_factor` whatever the
rib spacing. They act along global +z at the RBE3 reference node, which spreads
them through the spider into the whole rib boundary rather than into one grid.
"""
function analytic_lift_forces(m::Model)
    out = Tuple{Int,Float64,Float64}[]
    isempty(m.rbe3) && return out
    p = m.params
    total = Float64(p["loads.lift_total"]) * Float64(p["loads.load_factor"])
    kind = String(p["loads.distribution"])
    etas = [sp.eta for sp in m.rbe3]
    n = length(etas)
    for (r, sp) in enumerate(m.rbe3)
        lo = r == 1 ? 0.0 : 0.5 * (etas[r-1] + etas[r])
        hi = r == n ? 1.0 : 0.5 * (etas[r] + etas[r+1])
        share = lift_fraction(kind, m.wing, hi) - lift_fraction(kind, m.wing, lo)
        push!(out, (m.node_ids[sp.ref], total * share, sp.eta))
    end
    return out
end

"""
    write_nastran(m, path) -> Dict

Write the model as a complete, runnable NASTRAN deck and return a summary of
what was written.
"""
# Native linear/nonlinear defaults differ (0 versus 100). A paired baseline
# uses the nonlinear sequence's drilling stabilization in BOTH decks.
const COMPARISON_K6ROT = 100.0

function write_nastran(m::Model, path::AbstractString; frozen_load_cases=nothing, comparison=false)
    if fuel_states_differ(m)
        cases=frozen_load_cases===nothing ? case_loads(m) : frozen_load_cases
        files=Any[];stem,extension=splitext(path)
        for case in cases
            params=copy(case.params);params["loads.cases"]=Any[];params["loads.label"]=case.label
            isolated=Model((field===:params ? params : getfield(m,field) for field in fieldnames(Model))...)
            destination=case.id==1 ? path : stem*"_case_$(case.id)"*extension
            result=write_nastran(isolated,destination;frozen_load_cases=[(id=1,label=case.label,params=params,loads=case.loads)],comparison)
            push!(files,merge(result,Dict("case_id"=>case.id,"label"=>case.label,"fuel_percent"=>fuel_case_percent(params))))
        end
        result=copy(first(files));result["files"]=files
        result["note"]="Fuel CONM2 masses vary by case: separate complete decks were written, each with local SUBCASE 1."
        return result
    end
    dir = dirname(abspath(path))
    isempty(dir) || isdir(dir) || mkpath(dir)
    open(path, "w") do io
        write_deck(io, m; frozen_load_cases, comparison)
    end
    return Dict{String,Any}(
        "ok" => true,
        "path" => abspath(path),
        "bytes" => filesize(path),
        "lines" => countlines(path),
    )
end

function write_deck(io::IO, m::Model; frozen_load_cases=nothing, comparison=false)
    fuel_states_differ(m)&&throw(ArgumentError("Fuel masses vary by case; use write_nastran to write separate case decks or pass an isolated case model"))
    p = m.params
    w = m.wing
    sol = String(p["output.solution"])
    title = String(p["output.title"])
    specs = load_case_specs(p)

    # --- executive and case control ---------------------------------------
    banner!(io, "Wing torsion box, generated by WingFEGen")
    comment!(io, "Written " * Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"))
    comment!(io, "Units SI: m, N, kg, Pa")
    comment!(io, "Axes: x aft, y towards the tip, z up. Right-hand semi-span.")
    comment!(io, "Root airfoil " * String(p["airfoil.root"]) *
                 ", tip airfoil " * String(p["airfoil.tip"]))
    comment!(io,"Spanwise airfoil interpolation: "*String(get(p,"airfoil.interpolation","linear")))
    for station in normalize_airfoil_stations(get(p,"airfoil.stations",Any[]))
        comment!(io,"Intermediate airfoil at ETA "*string(station["eta"])*": "*station["code"]*" ("*station["source"]*")")
    end
    comment!(io, "Span " * fmt(w.span) * " m, area " * fmt(w.area) *
                 " m2, AR " * fmt(w.aspect_ratio) * ", taper " * fmt(w.taper))
    if w.perturbed
        comment!(io, "Aerodynamic planform above includes leading/trailing-edge points")
        comment!(io, "Base trapezoid area " * fmt(w.base_area) * " m2, AR " *
                     fmt(w.base_aspect_ratio) * ", taper " * fmt(w.base_taper))
    end
    spar_paths = spar_geometry(p)
    if !isempty(get(p,"ribs.masters",Any[]))
        comment!(io,"Master ribs: ETA anchors on rear spar; root and final closures fixed line of flight")
        comment!(io,"Master angles use the immediately inboard rear-spar tangent; pitch follows its 3D reference path")
        for row in normalize_rib_tables(p["ribs.masters"],"ribs.masters";end_eta=p["box.end_eta"])
            comment!(io,"Master ETA "*fmt(row["eta"],6)*"  "*row["mode"]*"  angle "*fmt(row["angle"])*" deg  outgoing pitch "*fmt(row["pitch"])*" m")
        end
    end
    if w.perturbed || spar_paths.perturbed
        comment!(io, "External FE nodes follow the refined aerodynamic airfoil loft")
        comment!(io, "Independent front/rear spar paths use eta and BASE chord x/c")
        comment!(io, "Spar point counts: front " * string(length(get(p, "box.front_spar_points", []))) *
                     ", rear " * string(length(get(p, "box.rear_spar_points", []))))
    end
    if p["leading_edge.enabled"] && !isempty(strip(get(p, "leading_edge.disabled_bays", "")))
        comment!(io, "Requested leading-edge omitted bays: " * p["leading_edge.disabled_bays"])
        comment!(io, "Bay b lies between ribs b and b+1; exclusions outside the selected span are inactive")
    end
    for (name, value) in fuel_info(m)
        comment!(io, name * ": " * value)
    end
    println(io, "SOL ", sol)
    println(io, "CEND")
    println(io, "TITLE = ", first(title, 60))
    println(io, "SUBTITLE = Torsion box, front spar ",
            fmt(p["box.front_spar_xc"]), " c, rear spar ",
            fmt(p["box.rear_spar_xc"]), " c")
    println(io, "ECHO = NONE")
    println(io, "DISPLACEMENT(PLOT) = ALL")
    println(io, "SPCFORCES(PLOT) = ALL")
    if sol == "103"
        comment!(io, "SOL 103 computes common unloaded normal modes; load cases below are not applied")
        println(io, "STRESS(PLOT) = ALL")
        println(io, "SUBCASE 1")
        println(io, "  LABEL = Normal modes, ",isempty(m.spc) ? "unsupported" : get(p,"supports.mode","root")=="root" ? "root fixed in 1 2 3" : "custom rib supports")
        isempty(m.spc)||println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
    elseif sol in ("101", "106")
        # Shell STRESS includes physical components and major/minor principals
        # at both fibres; VONMISES requests the equivalent invariant as well.
        println(io, "STRESS(PLOT,VONMISES) = ALL")
        # FORCE is the JFEM-supported NASTRAN element-force request (OEF):
        # shell resultants and bar end forces/moments, not applied grid loads.
        println(io, "FORCE(PLOT) = ALL")
        for spec in specs
            println(io, "SUBCASE ", spec.id)
            println(io, "  LABEL = ", first(replace(spec.label, '\$' => ' '), 60))
            isempty(m.spc)||println(io, "  SPC = 1")
            println(io, "  LOAD = ", spec.id)
        end
    else
        # SOL 105 needs the static preload subcase first, then the eigenvalue
        # subcase pointing back at it through STATSUB.
        println(io, "STRESS(PLOT,VONMISES) = ALL")
        for spec in specs
            sid = static_subcase_id(spec.id, sol)
            println(io, "SUBCASE ", sid)
            println(io, "  LABEL = Static preload: ", first(replace(spec.label, '\$' => ' '), 44))
            isempty(m.spc)||println(io, "  SPC = 1")
            println(io, "  LOAD = ", spec.id)
            println(io, "  DISPLACEMENT = ALL")
            println(io, "SUBCASE ", buckling_subcase_id(spec.id))
            println(io, "  LABEL = Buckling: ", first(replace(spec.label, '\$' => ' '), 50))
            println(io, "  STATSUB = ", sid)
            println(io, "  METHOD = 1")
        end
    end
    println(io, "BEGIN BULK")
    card!(io, "PARAM", ("POST", -1))
    card!(io, "PARAM", ("GRDPNT", 0))
    card!(io, "PARAM", ("AUTOSPC", "YES"))
    card!(io, "PARAM", ("WTMASS", 1.0))
    follower_enabled=any(c->get(c.params,"loads.follower_forces",false),
        frozen_load_cases===nothing ? case_loads(m) : frozen_load_cases)
    if follower_enabled && sol in ("101","106")
        comment!(io,"OpenJFEM extension PARAM,JFFOLLOW,1 activates FORCE ROT only; MOMENT loads remain fixed in BASIC")
        comment!(io,sol=="101" ? "First-order follower load linearization at zero rotation; not finite-rotation SOL101" :
            "Follower FORCE directions update with nodal rotation vectors at every nonlinear trial; aerodynamic pressures stay frozen")
        println(io,"PARAM,JFFOLLOW,1")
    elseif follower_enabled && sol=="105"
        throw(ArgumentError("Follower FORCE stiffness is not supported for SOL105; choose SOL101/SOL106 or turn off follower forces"))
    end
    if sol=="106" || comparison
        comment!(io,"Paired SOL101/SOL106 use the same explicit drilling stabilization K6ROT=100")
        card!(io,"PARAM",("K6ROT",COMPARISON_K6ROT))
    end
    if sol == "106"
        comment!(io, "Experimental JFEM geometric nonlinear static; fixed reference aerodynamic loads, no aeroelastic update")
        comment!(io, "JFEM nonlinear PARAM extensions use free fields because their names exceed eight columns")
        for (name,key) in (("NLLOADSTEPS","nonlinear.load_steps"),
                ("NLMAXITER","nonlinear.max_iterations"),("NLTOL","nonlinear.displacement_tolerance"),
                ("NLRESTOL","nonlinear.residual_tolerance"),("NLCUTMAX","nonlinear.max_cutbacks"))
            println(io,"PARAM,",name,",",p[key])
        end
        println(io,"PARAM,NLMETHOD,AUTO")
    end

    # Skins follow local stringer segments; rib x stays horizontal in its plane.
    # Using an MCID leaves connectivity and shell normals unchanged.
    banner!(io, "Shell material axes: local stringer segments, spar projection, horizontal rib x")
    frame_path=stringer_path(m.grid.wing,m.params)
    for gr in m.groups
        gr.kind in (:quad, :tria) || continue
        for el in 1:n_elements(gr)
            x, _, z = shell_material_frame(m, gr, el;path=frame_path)
            card!(io, "CORD2R", (shell_material_cid(m, gr, el), 0,
                                 0.0, 0.0, 0.0, z..., x...))
        end
    end

    # --- grids -------------------------------------------------------------
    banner!(io, "GRID: " * string(m.n_struct) * " structural, " *
                string(length(m.node_ids) - m.n_struct) * " RBE3 reference")
    for n in 1:length(m.node_ids)
        card!(io, "GRID", (m.node_ids[n], nothing,
                           m.xyz[3n-2], m.xyz[3n-1], m.xyz[3n]))
    end

    # --- shell and bar elements -------------------------------------------
    for gr in m.groups
        n_elements(gr) == 0 && continue
        card_name = gr.kind === :quad ? "CQUAD4" :
                    gr.kind === :tria ? "CTRIA3" : "CBAR"
        banner!(io, gr.name * ": " * string(n_elements(gr)) *
                    " " * card_name * ", PID " *
                    string(gr.pid) * ", EID " * string(first(gr.eids)) *
                    " to " * string(last(gr.eids)))
        if gr.kind === :quad
            for el in 1:n_elements(gr)
                card!(io, "CQUAD4", (gr.eids[el], gr.pid,
                                     m.node_ids[gr.conn[4*el-3]],
                                     m.node_ids[gr.conn[4*el-2]],
                                     m.node_ids[gr.conn[4*el-1]],
                                     m.node_ids[gr.conn[4*el]],
                                     shell_material_cid(m, gr, el)))
            end
        elseif gr.kind === :tria
            for el in 1:n_elements(gr)
                card!(io, "CTRIA3", (gr.eids[el], gr.pid,
                                     m.node_ids[gr.conn[3*el-2]],
                                     m.node_ids[gr.conn[3*el-1]],
                                     m.node_ids[gr.conn[3*el]],
                                     shell_material_cid(m, gr, el)))
            end
        else
            comment!(io, "local y is the outward skin normal; PBARL section centroid is offset inward")
            for el in 1:n_elements(gr)
                offset = bar_section_offset(m, gr, el)
                fields = Any[gr.eids[el], gr.pid,
                                   m.node_ids[gr.conn[2*el-1]],
                                   m.node_ids[gr.conn[2*el]],
                                   gr.orient[3*el-2],
                                   gr.orient[3*el-1],
                                   gr.orient[3*el]]
                if norm3(offset) > 0
                    append!(fields, Any["GGG", nothing, nothing, offset..., offset...])
                end
                card!(io, "CBAR", fields)
            end
        end
    end

    # --- aerodynamic loft, optional ---------------------------------------
    if p["output.include_aero_shells"]
        nq = length(m.aero_quads) ÷ 4
        id0 = maximum(gr -> isempty(gr.eids) ? 0 : maximum(gr.eids), m.groups) + 1
        id0 = max(id0, isempty(m.rbe3) ? id0 : last(m.rbe3).eid + 1)
        id0 = max(id0, isempty(m.fuel_rbe3) ? id0 : maximum(sp.mass_eid for sp in m.fuel_rbe3)+1)
        nid0 = length(m.node_ids) + 1
        banner!(io, "AERO_LOFT: " * string(nq) * " CQUAD4, PID " *
                    string(PID_AERO) * " (aerodynamic surface, not structural)")
        comment!(io, "WARNING: these shells carry their own grids and are NOT")
        comment!(io, "connected to the torsion box. They describe the wetted")
        comment!(io, "surface for loads and plotting work. As written they form")
        comment!(io, "a free body, so connect or remove them before running a")
        comment!(io, "solution on this deck.")
        na = length(m.aero_xyz) ÷ 3
        for n in 1:na
            card!(io, "GRID", (nid0 + n - 1, nothing,
                               m.aero_xyz[3n-2], m.aero_xyz[3n-1], m.aero_xyz[3n]))
        end
        for el in 1:nq
            card!(io, "CQUAD4", (id0 + el - 1, PID_AERO,
                                 nid0 + m.aero_quads[4*el-3] - 1,
                                 nid0 + m.aero_quads[4*el-2] - 1,
                                 nid0 + m.aero_quads[4*el-1] - 1,
                                 nid0 + m.aero_quads[4*el] - 1))
        end
    end

    # --- properties and material ------------------------------------------
    banner!(io, "Properties and material")
    for property in model_property_definitions(m)
        pid=property["pid"]
        if property["kind"]=="shell"
            if property["type"]=="PCOMP"
                comment!(io,"Symmetric isotropic face/core/face; ply thicknesses explicit, centered midsurface")
                fields=Any[pid,property["z0_m"],0.,nothing,nothing,nothing,nothing,nothing]
                for ply in property["plies"];append!(fields,Any[ply["material_id"],ply["thickness_m"],ply["angle_deg"],"YES"]);end
                card!(io,"PCOMP",fields)
            else
                mid=property["material_id"]
                card!(io,"PSHELL",(pid,mid,property["thickness_m"],mid,nothing,mid))
            end
        else
            section=property["section"];mid=property["material_id"]
            if section["type"]=="PBARL"
                comment!(io,"PBARL "*section["shape"]*": "*section["placement"])
                card!(io,"PBARL",Any[pid,mid,nothing,section["shape"],nothing,nothing,nothing,nothing,section["dimensions_m"]...,0.])
            else
                card!(io,"PBAR",(pid,mid,section["area_m2"],section["I1_m4"],section["I2_m4"],section["J_m4"]))
            end
        end
    end
    if p["output.include_aero_shells"]
        card!(io, "PSHELL", (PID_AERO, MID_STRUCT, p["output.t_aero_shell"],
                             MID_STRUCT, nothing, MID_STRUCT))
    end

    for material in model_material_definitions(m)
        comment!(io,"material $(material["id"]): "*material["name"])
        card!(io,"MAT1",(material["id"],material["E"],nothing,material["nu"],material["rho"]))
    end

    # --- RBE3 spiders ------------------------------------------------------
    if !isempty(m.rbe3)
        banner!(io, "RBE3: " * string(length(m.rbe3)) *
                    " spiders, reference node at " *
                    fmt(p["rbe3.ref_xc"]) * " c of each rib station")
        comment!(io, "reference grid is dependent in 1-6, connected grids")
        comment!(io, "contribute translations 1 2 3 with unit weight")
        for sp in m.rbe3
            fields = Any[sp.eid, nothing, m.node_ids[sp.ref], 123456, 1.0, 123]
            for d in sp.dep
                push!(fields, m.node_ids[d])
            end
            card!(io, "RBE3", fields)
        end
    end

    # Fuel RBE3 references are deliberately separate from aerodynamic stations.
    state=fuel_mass_state(m)
    if !isempty(m.fuel_rbe3)
        banner!(io,"Fuel / inertia: $(length(m.fuel_rbe3)) bay RBE3 connections, $(state["fuel_percent"]) percent fill")
        comment!(io,"CONM2 CID=0: CG offsets in BASIC; inertia about fuel CG, positive product-of-inertia fields")
        fuel_bays=Dict(bay["index"]=>bay for bay in state["bays"])
        for sp in m.fuel_rbe3
            fuel_reference_is_massless(m,sp)&&comment!(io,"Massless inertia reference for rib bay $(sp.start_rib); no fuel CONM2")
            card!(io,"RBE3",Any[sp.eid,nothing,m.node_ids[sp.ref],123456,1.0,123,m.node_ids[sp.dep]...])
            bay=get(fuel_bays,sp.start_rib,nothing);bay===nothing&&continue
            bay["mass_kg"]>0||continue
            card!(io,"CONM2",Any[sp.mass_eid,m.node_ids[sp.ref],0,bay["mass_kg"],bay["offset_m"]...,nothing,bay["conm2_inertia_kg_m2"]...])
        end
    end

    # --- supports ----------------------------------------------------------
    banner!(io, "SPC1: " * string(length(m.spc)) * " supported grids (" * get(p,"supports.mode","root") * ")")
    comment!(io,support_description(m))
    constrained=support_assignments(m)
    for components in sort!(unique([row.components for row in constrained]))
        # Every GRID is written once with its unioned component set. Mixed
        # selectors cannot emit overlapping/conflicting duplicate SPC entries.
        card!(io,"SPC1",Any[1,parse(Int,components),(m.node_ids[row.node] for row in constrained if row.components==components)...])
    end

    # --- loads -------------------------------------------------------------
    # The lift is part of the model whatever the solution, so it is always
    # written; only the case control decides whether it is used.
    for case in (frozen_load_cases === nothing ? case_loads(m) : frozen_load_cases)
    loads = case.loads
    applied = routed_applied_loads(m, loads;params=case.params)
    if !isempty(loads.stations)
        banner!(io, "LOAD CASE $(case.id): $(case.label)")
        comment!(io, "FORCE/MOMENT: " * String(case.params["loads.method"]) * " loads at " *
                    string(length(loads.stations)) * " RBE3 reference nodes")
        comment!(io, loads.summary["engine"] * "; load multiplier " * eng(case.params["loads.load_factor"]) * " (dimensionless)")
        comment!(io, LOAD_MULTIPLIER_NOTE)
        comment!(io, "Total force (N): " * join(eng.(loads.summary["force_N"]), ", "))
        comment!(io, "Moment about origin (Nm): " * join(eng.(loads.summary["moment_Nm"]), ", "))
        for s in applied.aerodynamic
            comment!(io, "eta " * fmt(s.eta, 4) * "  Fz " * eng(s.force[3]) * " N")
            # Unit scale with dimensional vector avoids normalization roundoff.
            if norm3(s.force) > 0
                follower=get(case.params,"loads.follower_forces",false) && sol in ("101","106")
                card!(io, "FORCE", follower ? (case.id, s.gid, nothing, 1.0, s.force...,"ROT") :
                    (case.id, s.gid, nothing, 1.0, s.force...))
            end
        end
    elseif sol != "103"
        comment!(io, "WARNING: no RBE3 stations, so no lift could be applied")
    end
    if !isempty(applied.mass)
        comment!(io,"Combined fuel and dry-structure inertia FORCE at fuel/mass bay RBE3s; fixed BASIC directions; force-transfer lever arms retained in MOMENT")
        for load in applied.mass
            norm3(load.force)>0&&card!(io,"FORCE",(case.id,load.gid,0,1.0,load.force...))
        end
    end
    comment!(io,APPLIED_MOMENT_ROUTING_NOTE)
    comment!(io,"Load application version: "*APPLIED_LOAD_VERSION)
    for line in applied.diagnostics["log_lines"];comment!(io,line);end
    for load in applied.moments
        norm3(load.moment)>0&&card!(io,"MOMENT",(case.id,load.gid,0,1.0,load.moment...))
    end
    end

    # --- eigenvalue extraction ---------------------------------------------
    if sol == "103"
        banner!(io, "EIGRL: " * string(p["output.n_modes"]) * " modes")
        # SID, V1, V2, ND, MSGLVL, MAXSET, SHFSCL, NORM
        card!(io, "EIGRL", (1, nothing, nothing, p["output.n_modes"],
                            nothing, nothing, nothing, "MASS"))
    elseif sol == "105"
        vmax = Float64(p["output.buckling_max_factor"])
        banner!(io, "EIGRL: " * string(p["output.n_modes"]) *
                    " buckling roots per load case, scaled against its own static preload")
        comment!(io, "the search is restricted to positive factors, which are")
        comment!(io, "the ones acting in the applied lift direction. A negative")
        comment!(io, "root would mean the box buckles under reversed load, and")
        comment!(io, "those sit nearer zero here because the lower skin is the")
        comment!(io, "thinner one. Raise output.buckling_max_factor to widen it.")
        card!(io, "EIGRL", (1, 1.0e-6, vmax, p["output.n_modes"]))
    end

    println(io, "ENDDATA")
    return nothing
end
