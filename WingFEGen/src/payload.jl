# ===========================================================================
#  payload.jl - MsgPack payload sent to the browser
#
#  Node coordinates and element connectivity travel as MsgPack `bin` objects
#  holding raw little-endian Float32 and Int32 values, so the browser can
#  reinterpret them as typed arrays and hand them straight to Babylon.js
#  without decoding element by element.
#
#  Connectivity is sent as zero-based indices into the node array, which is
#  what a vertex buffer needs. The NASTRAN ids travel alongside in `ids`.
# ===========================================================================

"""
    Blob

Wrapper that makes MsgPack emit a byte string (`bin`) instead of an array.
"""
struct Blob
    bytes::Vector{UInt8}
end

MsgPack.msgpack_type(::Type{Blob}) = MsgPack.BinaryType()
MsgPack.to_msgpack(::MsgPack.BinaryType, b::Blob) = b.bytes

"""Restore MessagePack binary tags when a saved viewport payload is resent.

MsgPack.unpack returns binary fields as Vector{UInt8}, but packing that vector
again emits a numeric array unless it is wrapped in Blob. Ordinary MessagePack
arrays decode as Vector{Any}; preserve them as arrays, including empty arrays
and lists of small integers that happen to fit in a byte.
"""
restore_payload_binary(value) = value
restore_payload_binary(value::Vector{UInt8}) = Blob(value)
restore_payload_binary(value::AbstractDict) = Dict{Any,Any}(key => restore_payload_binary(item) for (key,item) in value)
restore_payload_binary(value::AbstractVector) = Any[restore_payload_binary(item) for item in value]

"""Read a stored viewport payload without losing its typed binary buffers."""
unpack_view_payload(bytes) = restore_payload_binary(MsgPack.unpack(bytes))

"""
    blob_f32(v) -> Blob

Pack a real vector as raw little-endian Float32.
"""
function blob_f32(v::AbstractVector{<:Real})
    io = IOBuffer(; sizehint = 4 * length(v) + 8)
    for x in v
        write(io, htol(Float32(x)))
    end
    return Blob(take!(io))
end

"""Defined (undeformed) airfoil wire loops on the same refined loft as the FE skin.

Retain each profile's own upper/lower knots, including UIUC coordinates and a
finite trailing-edge gap. These are display geometry, not structural nodes.
"""
function airfoil_sections_payload(w::Wing)
    sections = Dict{String,Any}[]
    for (index, eta) in enumerate(w.airfoil_etas)
        af = airfoil_section(w, index)
        points = [upper_point(w, eta, x) for x in af.xu]
        append!(points, [lower_point(w, eta, x) for x in reverse(af.xl)])
        first(points) == last(points) || push!(points, first(points))
        # Retain an explicit closing vertex even when the nose already meets.
        kind = index == 1 ? "root" : index == length(w.airfoil_etas) ? "tip" : "intermediate"
        push!(sections, Dict{String,Any}(
            "eta" => eta, "name" => af.name, "source" => String(af.source),
            "kind" => kind, "count" => length(points),
            "xyz" => blob_f32(Float64[x for point in points for x in point])))
    end
    return sections
end

"""Shell material/result frames and CBAR section frames."""
function element_axes(m::Model, gr::ElemGroup;path=stringer_path(m.grid.wing,m.params))
    centers, xs, ys, zs, lengths = (Float64[] for _ in 1:5)
    n = gr.kind === :quad ? 4 : gr.kind === :tria ? 3 : 2
    for e in 1:n_elements(gr)
        points = [Tuple(m.xyz[3id-2:3id]) for id in gr.conn[n*(e-1)+1:n*e]]
        center = ntuple(c -> sum(p[c] for p in points) / n, 3)
        p1, p2 = points[1], points[2]
        if gr.kind === :bar
            x = unit3(p2 .- p1)
            v = Tuple(gr.orient[3*e-2:3*e])
            z = unit3(cross3(x, v))
            y = cross3(z, x)
        else
            x, y, z = shell_material_frame(m, gr, e;path)
        end
        append!(centers, center); append!(xs, x); append!(ys, y); append!(zs, z)
        push!(lengths, minimum(norm3(points[mod1(i+1, n)] .- points[i]) for i in 1:n))
    end
    return Dict{String,Any}("centers" => blob_f32(centers), "x" => blob_f32(xs),
        "y" => blob_f32(ys), "z" => blob_f32(zs), "lengths" => blob_f32(lengths),
        "frame_note" => gr.kind === :bar ? "CBAR axes follow its section orientation" : shell_material_description(gr))
end

function load_payload(loads; model::Union{Nothing,Model} = nothing)
    applied=model===nothing ? nothing : routed_applied_loads(model,loads)
    load_record(s) = Dict{String,Any}(
        "eta" => s.eta, "position" => collect(s.position),
        "force" => collect(s.force), "moment" => collect(s.moment))
    stations = [merge(load_record(s), Dict("node_index" => s.node_index - 1, "gid" => s.gid))
                for s in (applied===nothing ? loads.stations : applied.aerodynamic)]
    result = Dict{String,Any}("summary" => loads.summary,
        "stations" => stations, "panels" => Any[load_record(s) for s in loads.panels])
    result["follower_forces"]=model!==nothing && get(model.params,"loads.follower_forces",false)
    result["fuel_stations"]=model===nothing ? Any[] : [Dict{String,Any}(
        "node_index"=>s.node,"gid"=>s.gid,"fuel_bay"=>s.bay,
        "eta"=>(model.xyz[3s.node+2]-model.wing.root_ref_y)/model.wing.semispan,
        "position"=>model.xyz[3s.node+1:3s.node+3],"force"=>collect(s.force),"moment"=>collect(s.moment),
        "follower_forces"=>false) for s in applied.fuel]
    result["structure_stations"]=model===nothing ? Any[] : [Dict{String,Any}(
        "node_index"=>s.node,"gid"=>s.gid,"eta"=>(model.xyz[3s.node+2]-model.wing.root_ref_y)/model.wing.semispan,
        "position"=>model.xyz[3s.node+1:3s.node+3],"force"=>collect(s.force),"moment"=>collect(s.moment),
        "follower_forces"=>false) for s in applied.structure]
    result["moment_stations"]=applied===nothing ? Any[] : [merge(load_record(s),Dict{String,Any}(
        "node_index"=>s.node_index-1,"gid"=>s.gid,"follower_forces"=>false,
        "target_kind"=>s.target_kind,"target_rbe3_eid"=>s.target_rbe3_eid,"fuel_bay"=>s.fuel_bay,"massless"=>s.massless,
        "source_moments_Nm"=>Dict(String(key)=>collect(value) for (key,value) in pairs(s.source_moments)),
        "source_force_arm_moments_Nm"=>Dict(String(key)=>collect(value) for (key,value) in pairs(s.source_force_arm_moments)))) for s in applied.moments]
    result["force_stations"]=applied===nothing ? stations : [merge(load_record(s),Dict{String,Any}(
        "node_index"=>s.node_index-1,"gid"=>s.gid,
        "follower_forces"=>s.target_kind=="external_rbe3"&&get(model.params,"loads.follower_forces",false),
        "target_kind"=>s.target_kind,"target_rbe3_eid"=>s.target_rbe3_eid,"fuel_bay"=>s.fuel_bay,"massless"=>s.massless,
        "source_forces_N"=>Dict(String(key)=>collect(value) for (key,value) in pairs(s.source_forces)))) for s in applied.forces]
    result["routing_diagnostics"]=applied===nothing ? nothing : applied.diagnostics
    result["moment_routing_note"]=APPLIED_MOMENT_ROUTING_NOTE
    result["load_application_version"]=APPLIED_LOAD_VERSION
    result["structure_inertia"]=model!==nothing&&get(model.params,"loads.structure_inertia",false)
    result["structure_inertia_migration_note"]=model===nothing ? "" : get(model.params,"structure_inertia_migration_note","")
    model === nothing || (result["spanwise"] = spanwise_load_data(model,loads))
    if !isempty(loads.panels)
        xyz = Float64[v for p in loads.panels for corner in p.corners for v in corner]
        count = length(loads.panels)
        centers = [ntuple(c->sum(point[c] for point in panel.corners)/4,3) for panel in loads.panels]
        center_moments = [panel.moment .+ cross3(panel.position .- center,panel.force)
                          for (panel,center) in zip(loads.panels,centers)]
        result["vlm"] = Dict{String,Any}("xyz" => blob_f32(xyz),
            "conn" => blob_i32(collect(0:4count-1)), "count" => count,
            "pressure" => blob_f32([p.pressure for p in loads.panels]),
            "cp" => blob_f32([p.cp for p in loads.panels]),
            "area" => blob_f32([p.area for p in loads.panels]),
            "centers" => blob_f32(Float64[x for center in centers for x in center]),
            "forces" => blob_f32(Float64[x for panel in loads.panels for x in panel.force]),
            "moments" => blob_f32(Float64[x for moment in center_moments for x in moment]),
            "force_unit" => "N", "moment_unit" => "N m",
            "force_note" => "Applied panel resultant at the arithmetic mean of its four camber-grid corners, in model x/y/z axes. Includes the dimensionless load multiplier. The accompanying moment is shifted to this center to preserve the original panel resultant.",
            "pressure_unit" => "Pa",
            "pressure_note" => "Equivalent panel-average lower-minus-upper pressure jump from normal force; includes the dimensionless load multiplier. Cp jump = pressure jump / q. Reference camber surface.")
    end
    return result
end

"""
    blob_i32(v; offset = 0) -> Blob

Pack an integer vector as raw little-endian Int32, adding `offset` to each
value. Use `offset = -1` to turn the one-based internal indices into the
zero-based indices a vertex buffer expects.
"""
function blob_i32(v::AbstractVector{<:Integer}; offset::Int = 0)
    io = IOBuffer(; sizehint = 4 * length(v) + 8)
    for x in v
        write(io, htol(Int32(x + offset)))
    end
    return Blob(take!(io))
end

"""Properties as written to PSHELL/PBARL/PBAR/MAT1, with explicit SI units."""
function element_properties(m::Model, gr::ElemGroup)
    p = m.params
    out = Dict{String,Any}("pid" => gr.pid)
    if gr.kind === :bar
        out["material"]=material_payload(bar_material_definition(p,gr.pid))
        section = section_definition(p, gr.pid)
        out["section"] = section
        for key in ("type", "area_m2", "I1_m4", "I2_m4", "J_m4")
            out[key] = section[key]
        end
    else
        merge!(out,shell_material_definition(p,gr.pid))
        out["axes"]=shell_material_description(gr)
    end
    return out
end

"""
Physical rib/stringer numbering, independent of shell subdivisions. All node
indices in this JSON metadata are zero based, like the packed connectivity.
Anchors are weighted nodes so labels can follow a deformed display exactly.
"""
function physical_annotations(m::Model)
    g = m.grid
    layout=g.rib_layout===nothing ? physical_rib_layout(m.wing,m.params) : g.rib_layout
    le_reference = m.params["leading_edge.enabled"] ? leading_edge_reference(m.wing,m.params) : nothing
    node_lookup = Dict(key => n - 1 for (n, key) in enumerate(m.node_keys))
    function node_at(i, j, k)
        collapsed = g.collapsed[i+1,j+1]
        column = collapsed < 0 ? 0 : collapsed > 0 ? ni(g) : i
        return node_lookup[(column, j, k)]
    end
    ribs = Any[]
    for (index, j) in enumerate(g.ribs)
        perimeter = unique(vcat([node_at(i, j, 0) for i in 0:ni(g)],
            [node_at(ni(g), j, k) for k in 1:g.nh],
            [node_at(i, j, g.nh) for i in ni(g)-1:-1:0],
            [node_at(0, j, k) for k in g.nh-1:-1:1]))
        mid_xc = (g.upper_xcs[1,j+1] + g.upper_xcs[end,j+1]) / 2
        upper_column = argmin(abs.(g.upper_xcs[:,j+1] .- mid_xc)) - 1
        front_nodes = [node_at(0,j,0), node_at(0,j,g.nh)]
        front_midpoint = [(m.xyz[3front_nodes[1]+axis] + m.xyz[3front_nodes[2]+axis])/2 for axis in 1:3]
        plane=main_rib_plane(g,m.params,j)
        datum_u=unit3(cross3((0.0,0.0,1.0),plane.normal));datum_u[1]<0&&(datum_u=-1 .*datum_u)
        datum_v=unit3(cross3(datum_u,plane.normal));datum_v[3]<0&&(datum_v=-1 .*datum_v)
        rib = Dict{String,Any}(
            "index" => index, "label" => "R $index", "eta" => g.etas[j+1],
            "is_master"=>layout.physical[index].master,
            "nodes" => perimeter,
            "anchor_nodes" => [node_at(upper_column, j, g.nh)],
            "anchor_weights" => [1.0],
            # All section points have constant global y, even with twist and
            # dihedral. These axes describe that physical rib datum plane.
            "datum_origin" => front_midpoint,
            "datum_u" => collect(datum_u), "datum_v" => collect(datum_v),
            "datum_anchor_nodes" => front_nodes, "datum_anchor_weights" => [0.5,0.5])
        if m.params["leading_edge.enabled"]
            n = Int(m.params["leading_edge.chord_elements"])
            if haskey(node_lookup,(-n,j,0))
                rib["leading_edge_anchor_nodes"] = [node_lookup[(cld(n,2)-n,j,g.nh)]]
                rib["leading_edge_anchor_weights"] = [1.0]
                rib["leading_edge_nose_anchor_nodes"] = [node_lookup[(-n,j,0)]]
                rib["leading_edge_nose_anchor_weights"] = [1.0]
                plane=leading_edge_effective_rib_plane(m,j)
                rib["leading_edge_datum_origin"]=collect(plane.origin)
                rib["leading_edge_datum_u"]=collect(plane.direction)
                rib["leading_edge_datum_v"]=collect(plane.vertical)
                rib["leading_edge_datum_normal"]=collect(plane.normal)
            end
        end
        push!(ribs,rib)
    end
    # Connectivity lookup avoids assumptions about EID allocation or whether
    # another element family is inserted before the physical bars.
    bars = Dict{Tuple{Int,Int},Tuple{Int,Bool}}()
    next_bar_node = Dict{Int,Int}()
    for gr in m.groups
        component_base_group(gr.name) in ("STRINGERS", "STRINGER_RUNOUTS") || continue
        for e in 1:n_elements(gr)
            bars[(gr.conn[2*e-1]-1, gr.conn[2*e]-1)] = (gr.eids[e], gr.name == "STRINGER_RUNOUTS")
            next_bar_node[gr.conn[2*e-1]-1]=gr.conn[2*e]-1
        end
    end
    stringers = Any[]
    for (index, i) in enumerate(g.stringer_indices), upper in (false, true)
        k = upper ? g.nh : 0
        nodes, eids, runout_eids = Int[], Int[], Int[]
        normal_edges = Tuple{Int,Int}[]
        runout_edges = Tuple{Int,Int}[]
        for j in 0:nj(g)-1
            g.collapsed[i+1,j+1] == 0 || break
            a, b = node_at(i, j, k), node_at(i, j+1, k)
            isempty(nodes) && push!(nodes, a)
            # A physical segment can contain locally inserted spar/stringer
            # kink vertices. Follow its actual bars, retaining every EID and
            # deformation anchor instead of assuming one bar per grid row.
            hops=0
            while a!=b
                hops+=1
                hops<=length(bars)||error("stringer annotation encountered a cyclic bar chain")
                following=next_bar_node[a]
                eid,runout=bars[(a,following)]
                push!(nodes,following);push!(eids,eid)
                if runout
                    push!(runout_eids,eid);push!(runout_edges,(a,following))
                else
                    push!(normal_edges,(a,following))
                end
                a=following
            end
        end
        isempty(nodes) && continue
        # Prefer the middle of the physical normal section; a stringer with
        # only a connector still receives a meaningful end-to-end anchor.
        anchor = isempty(normal_edges) ? (first(nodes), last(nodes)) :
            normal_edges[cld(length(normal_edges), 2)]
        push!(stringers, Dict{String,Any}(
            "index" => index, "side" => upper ? "upper" : "lower",
            "label" => (upper ? "U" : "L") * string(index),
            "nodes" => nodes, "eids" => eids, "runout_eids" => runout_eids,
            "runout_anchor_nodes" => isempty(runout_edges) ? Int[] : collect(runout_edges[cld(length(runout_edges), 2)]),
            "runout_anchor_weights" => isempty(runout_edges) ? Float64[] : [0.5, 0.5],
            "anchor_nodes" => collect(anchor), "anchor_weights" => [0.5, 0.5]))
    end
    return Dict{String,Any}("ribs" => ribs, "stringers" => stringers,
        "note" => "Ribs: root to final closed rib, starting at 1. Stringers: front to rear at the root, U=upper and L=lower, starting at 1 on each skin. Shell refinement does not change these numbers. Node indices are zero based.")
end

"""
    mesh_payload(m) -> Dict

Assemble the complete description of the model for the viewer.
"""
function rib_layout_payload(m::Model)
    g=m.grid;layout=g.rib_layout===nothing ? physical_rib_layout(m.wing,m.params) : g.rib_layout
    le=Dict(record["rib"]=>record for record in leading_edge_orientation_metadata(m));rows=Any[]
    for (number,j) in enumerate(g.ribs)
        low=[collect(grid_point(g,i,j,0)) for i in 0:ni(g)]
        high=[collect(grid_point(g,i,j,g.nh)) for i in 0:ni(g)]
        info=layout.physical[number];leading=get(le,number,nothing)
        eids=Int[]
        for group in m.groups
            component_base_pid(group.pid)==PID_RIB_WEB||continue
            n=group.kind==:quad ? 4 : 3
            append!(eids,[group.eids[e] for e in eachindex(group.eids) if m.node_keys[group.conn[n*(e-1)+1]][2]==j])
        end
        push!(rows,Dict{String,Any}("number"=>number,"eta"=>g.etas[j+1],"rear_eta"=>g.etas[j+1],
            "front_eta"=>(g.lower_etas[1,j+1]+g.upper_etas[1,j+1])/2,
            "is_master"=>info.master,"master_index"=>info.master_index,"mode"=>info.mode,"angle"=>info.angle,
            "direction"=>collect(rib_row_direction(layout,g.etas[j+1])),"front"=>(first(low).+first(high))./2,"rear"=>(last(low).+last(high))./2,
            "lower"=>low,"upper"=>high,"eids"=>eids,"leading"=>leading===nothing ? nothing : leading["nose"],
            "le_fallback"=>leading===nothing ? false : leading["fallback"],"le_status"=>leading===nothing ? "not modeled" : leading["reason"]))
    end
    return Dict{String,Any}("ribs"=>rows,"masters"=>layout.masters,"angle_reference"=>"local_inboard_rear_spar",
        "pitch_reference"=>layout.legacy ? "legacy_reference_line" : "rear_spar_3d_reference",
        "note"=>"Actual generated rib/skin intersections. ETA is measured at the rear spar; root and final closures are fixed line of flight.")
end

function mesh_payload(m::Model; progress = stage -> nothing)
    progress("element_axes")
    path=stringer_path(m.grid.wing,m.params)
    groups = Any[]
    for gr in m.groups
        n_elements(gr) == 0 && continue
        entry = Dict{String,Any}(
            "name" => gr.name,
            "kind" => String(gr.kind),
            "n_per_elem" => gr.kind === :quad ? 4 : gr.kind === :tria ? 3 : 2,
            "pid" => gr.pid,
            "base_pid"=>component_base_pid(gr.pid),"base_group"=>component_base_group(gr.name),
            "count" => n_elements(gr),
            "eid_first" => minimum(gr.eids),
            "eid_last" => maximum(gr.eids),
            "eids" => blob_i32(gr.eids),
            "properties" => element_properties(m, gr),
            "axes" => element_axes(m, gr;path),
            "conn" => blob_i32(gr.conn; offset = -1),
        )
        gr.kind === :bar && (entry["orient"] = blob_f32(gr.orient))
        entry["panel_id"]=stiffened_panel_id(gr.pid)
        push!(groups, entry)
    end

    # RBE3 spiders as a flat line list, two node indices per drawn line.
    rbe3_lines = Int[]
    rbe3_refs = Int[]
    for sp in m.rbe3
        push!(rbe3_refs, sp.ref)
        for d in sp.dep
            push!(rbe3_lines, sp.ref, d)
        end
    end

    progress("aerodynamic_loads")
    aerodynamic_cases=case_loads(m)
    progress("case_preparation")
    cases = [begin
        case_model=model_for_load_case(m,c)
        Dict{String,Any}("id"=>c.id,"label"=>c.label,"loads"=>load_payload(c.loads;model=case_model),
            "fuel"=>fuel_mass_state(case_model),"weights"=>weights_payload(case_model))
    end for c in aerodynamic_cases]
    progress("fuel_display")
    fuel = fuel_payload(m)
    progress("weights")
    weights = weights_payload(m)
    progress("annotations")
    annotations = physical_annotations(m)

    progress("payload")
    return Dict{String,Any}(
        "ok" => true,
        "format" => "wingfegen-mesh-1",
        "note" => "bin blobs are little-endian Float32 or Int32; " *
                  "connectivity is zero-based into nodes.xyz",
        "title" => String(m.params["output.title"]),
        "model_params" => copy(m.params),
        "stiffened_panels" => stiffened_panels_payload(m),
        "planform" => Dict{String,Any}(
            "area_m2" => m.wing.area, "aspect_ratio" => m.wing.aspect_ratio,
            "root_chord_m" => m.wing.chord_root, "tip_chord_m" => m.wing.chord_tip,
            "mac_m" => m.wing.mac, "base_area_m2" => m.wing.base_area,
            "base_root_chord_m" => m.wing.base_chord_root,
            "base_tip_chord_m" => m.wing.base_chord_tip,
            "edge_station_etas" => planform_breakpoints(m.wing),
            "note" => "Skins and leading-edge nose lie on this refined aerodynamic loft. Spar paths retain independent base-trapezoid x/c references and are mapped onto the refined section. RBE3 references use the refined chord. Stringer paths follow rear-spar segments with the specified endpoint angles; without rear points they use the global angle to the base rear spar."),
        "spars" => Dict{String,Any}(
            "station_etas" => spar_breakpoints(m.params),
            "grid_etas" => m.grid.etas,
            "front_xc" => [spar_xc(m.wing,m.params,eta,:front) for eta in m.grid.etas],
            "rear_xc" => [spar_xc(m.wing,m.params,eta,:rear) for eta in m.grid.etas],
            "front_surface_xc" => collect(m.grid.lower_xcs[1,:]),
            "rear_surface_xc" => collect(m.grid.lower_xcs[end,:]),
            "note" => "front_xc/rear_xc are independent base-trapezoid fractions; surface_xc values locate those paths on the refined section. Physical rib numbering is unchanged by inserted edge/spar rows."),
        "leading_edge" => leading_edge_summary(m),
        "materials"=>Dict{String,Any}("library"=>[material_payload(row) for row in material_definitions(m.params)],
            "note"=>MATERIAL_IDEALIZATION_NOTE),
        "rib_layout" => rib_layout_payload(m),
        "stringer_path" => Dict{String,Any}(
            "station_etas"=>path.etas,"slopes_dx_dy"=>path.slopes,
            "offsets_x_m"=>path.offsets,"angles_deg"=>path.angles,
            "per_rear_point"=>path.per_point,
            "note"=>"Each angle applies to the segment ending at its rear-spar point; the last angle continues to the tip. Paths remain continuous at the knots."),
        "fuel" => fuel,
        "weights" => weights,
        "annotations" => annotations,
        "loads" => first(cases)["loads"],
        "load_cases" => cases,
        "nodes" => Dict{String,Any}(
            "count" => length(m.node_ids),
            "n_structural" => m.n_struct,
            "ids" => blob_i32(m.node_ids),
            "xyz" => blob_f32(m.xyz),
        ),
        "groups" => groups,
        "rbe3" => Dict{String,Any}(
            "count" => length(m.rbe3),
            "refs" => blob_i32(rbe3_refs; offset = -1),
            "eids" => blob_i32([sp.eid for sp in m.rbe3]),
            "lines" => blob_i32(rbe3_lines; offset = -1),
            "elements" => Any[Dict{String,Any}(
                "eid" => sp.eid, "ref" => sp.ref - 1,
                "reference_grid" => m.node_ids[sp.ref],
                "connected_grids" => m.node_ids[sp.dep],
                "reference_components" => "123456",
                "connected_components" => "123", "weight" => 1.0,
                "eta" => sp.eta) for sp in m.rbe3],
        ),
        "fuel_rbe3" => Dict{String,Any}(
            "count"=>length(m.fuel_rbe3),"refs"=>blob_i32([sp.ref for sp in m.fuel_rbe3];offset=-1),
            "massless_count"=>count(sp->fuel_reference_is_massless(m,sp),m.fuel_rbe3),
            "reference_note"=>"Fuel-bay references also carry structural inertial couples. Where no tank bay is active, massless equivalents have the same rib/skin attachments and no CONM2 or fuel capacity.",
            "eids"=>blob_i32([sp.eid for sp in m.fuel_rbe3]),
            "lines"=>blob_i32(Int[n for sp in m.fuel_rbe3 for d in sp.dep for n in (sp.ref,d)];offset=-1),
            "elements"=>Any[Dict{String,Any}("eid"=>sp.eid,"ref"=>sp.ref-1,"reference_grid"=>m.node_ids[sp.ref],
                "connected_grids"=>m.node_ids[sp.dep],"reference_components"=>"123456","dependent_dofs"=>"123456",
                "connected_components"=>"123","weight"=>1.,"bay"=>sp.start_rib,"start_rib"=>sp.start_rib,
                "end_rib"=>sp.end_rib,"massless"=>fuel_reference_is_massless(m,sp),
                "reference_role"=>fuel_reference_is_massless(m,sp) ? "massless_inertia" : "fuel_property",
                "conm2_eid"=>fuel_reference_is_massless(m,sp) ? nothing : sp.mass_eid) for sp in m.fuel_rbe3]),
        "spc" => supports_payload(m),
        "aero" => Dict{String,Any}(
            "count" => length(m.aero_quads) ÷ 4,
            "sections" => airfoil_sections_payload(m.wing),
            "n_loop" => m.aero_nloop,
            "xyz" => blob_f32(m.aero_xyz),
            "conn" => blob_i32(m.aero_quads; offset = -1),
            # Legacy four-node section mapping, or eight nodes spanning two
            # structural rows when aerodynamic and structural outlines differ.
            "n_per_node" => length(m.aero_map) ÷ (length(m.aero_xyz) ÷ 3),
            "map" => blob_i32(m.aero_map; offset = -1),
            "weights" => blob_f32(m.aero_weights),
            "rotation_lever_m" => blob_f32(aero_rotation_levers(m)),
            "deformation_note" => oriented_ribs(m.grid) ? "Display-only aero overlay: continuous blending between rib-row projections plus rotational offsets preserves rigid translations and infinitesimal rotations. General strain away from the angled rib planes is approximated. No aero-overlay stiffness or force-transfer connection is modeled." : "Aerodynamic nodes interpolate between structural section projections; beyond the final box rib the overlay follows a rigid terminal-rib extension for display only. No aerodynamic-overlay stiffness is modeled.",
        ),
        "bbox" => bbox_of(m),
        "info" => vcat(Any[Any[k, v] for (k, v) in m.info],
            Any[Any["Section migration", note] for note in get(m.params, "section_migration_notes", String[])]),
        "checks" => Any[Any[n, d, ok] for (n, d, ok) in m.checks],
        "checks_pass" => all_checks_pass(m),
    )
end

"""
    bbox_of(m) -> Dict

Axis aligned bounding box of the structural and aerodynamic geometry, used by
the viewer to frame the camera.
"""
function bbox_of(m::Model)
    lo = fill(Inf, 3)
    hi = fill(-Inf, 3)
    for arr in (m.xyz, m.aero_xyz)
        for n in 1:(length(arr)÷3), c in 1:3
            v = arr[3*(n-1)+c]
            lo[c] = min(lo[c], v)
            hi[c] = max(hi[c], v)
        end
    end
    any(!isfinite, lo) && return Dict{String,Any}("min" => [0.0, 0.0, 0.0],
                                                  "max" => [1.0, 1.0, 1.0])
    return Dict{String,Any}("min" => lo, "max" => hi)
end
