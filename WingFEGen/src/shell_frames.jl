# Explicit shell material/result frames. Nastran's geometric element frame is
# fixed by connectivity; MCID selects the requested skin, spar or rib axes.

element_points(m::Model, gr::ElemGroup, e::Int) = begin
    n = gr.kind === :quad ? 4 : gr.kind === :tria ? 3 : 2
    [Tuple(m.xyz[3id-2:3id]) for id in gr.conn[n*(e-1)+1:n*e]]
end

"""The geometric frame used by native JFEM shell stress/force recovery."""
function shell_geometric_frame(points; mode = lowercase(strip(get(ENV,
        "JFEM_Q4_FRAME_MODE_STATIC", get(ENV, "JFEM_Q4_FRAME_MODE", "diag")))))
    p1, p2, p3 = points[1:3]
    if length(points) == 3
        x = unit3(p2 .- p1)
        z = unit3(cross3(x, p3 .- p1))
    else
        p4 = points[4]
        gxi = (-1 .* p1 .+ p2 .+ p3 .- p4) ./ 4
        geta = (-1 .* p1 .- p2 .+ p3 .+ p4) ./ 4
        zr = cross3(gxi, geta)
        sum(zr .* zr) <= 1e-24 && (zr = cross3(p3 .- p1, p4 .- p2))
        z = unit3(zr)
        raw = if mode in ("parametric", "center", "center_tangent", "tangent")
            sum(gxi .* gxi) > 1e-24 ? gxi : p2 .- p1
        elseif mode in ("edge", "g12", "edge12")
            p2 .- p1
        else
            a, b = unit3(p3 .- p1), unit3(p4 .- p2)
            r = a .- b
            sum(r .* r) < 1e-20 ? a .+ b : r
        end
        projected = raw .- sum(raw .* z) .* z
        sum(projected .* projected) <= 1e-24 &&
            (projected = geta .- sum(geta .* z) .* z)
        x = unit3(projected)
    end
    return x, cross3(z, x), z
end

"""Skin x follows the local stringer segment in the shell plane, pointing tipward.

Spar webs use the nominal stringer direction projected into their own plane.
Rib x is the horizontal intersection of its actual plane with constant-z,
directed aft. For main-box and line-of-flight ribs this is global +x.
"""
function shell_material_frame(m::Model, gr::ElemGroup, e::Int;
                              path=stringer_path(m.grid.wing,m.params))
    pid=component_base_pid(gr.pid)
    _, _, z = shell_geometric_frame(element_points(m, gr, e))
    n=gr.kind === :quad ? 4 : 3
    stations=[m.grid.etas[m.node_keys[id][2]+1] for id in gr.conn[n*(e-1)+1:n*e]]
    eta=(minimum(stations)+maximum(stations))/2
    if oriented_ribs(m.grid) || pid==PID_LE_SKIN && (get(m.params,"leading_edge.rib_orientation","flight_direction")=="front_spar_angle" || !isempty(get(m.params,"leading_edge.rib_orientations",Any[])))
        # These nodes have shifted along the loft from their front-spar row.
        ys=[m.xyz[3id-1] for id in gr.conn[n*(e-1)+1:n*e]]
        eta=((minimum(ys)+maximum(ys))/2-m.wing.root_ref_y)/m.wing.semispan
    end
    slope = stringer_slope(path,eta)
    if pid in (PID_SKIN_UPPER, PID_SKIN_LOWER, PID_LE_SKIN)
        x = unit3(cross3(z, (1.0, -slope, 0.0)))
        x[2] < 0 && (x = -1 .* x)
    elseif pid in (PID_RIB_WEB, PID_LE_RIB)
        x = unit3(cross3((0.0,0.0,1.0),z))
        (x[1]<0 || (x[1]==0 && x[2]<0)) && (x = -1 .* x)
    else
        nominal = (slope, 1.0, tand(m.params["planform.dihedral"]))
        x = unit3(nominal .- sum(nominal .* z) .* z)
        norm3(x) < 0.5 && (x = unit3((1.0, 0.0, 0.0) .- z[1] .* z))
    end
    norm3(x) > 0.5 || error("Cannot define shell reference x for EID $(gr.eids[e])")
    return x, cross3(z, x), z
end

"""User-facing convention shared by element properties and recovered results."""
shell_material_description(gr::ElemGroup) = component_base_pid(gr.pid) in (PID_RIB_WEB, PID_LE_RIB) ?
    "Shell material axes (MCID): x is horizontal in the rib plane, directed aft (horizontal global +x for line-of-flight ribs); z preserves the shell normal" :
    component_base_pid(gr.pid) in (PID_SKIN_UPPER, PID_SKIN_LOWER, PID_LE_SKIN) ?
    "Shell material axes (MCID): x follows the local stringer segment toward the tip; z is the outward skin normal" :
    "Shell material axes (MCID): x follows the in-plane stringer projection on the spar web; z preserves the shell normal"

# Coordinate and element IDs occupy independent namespaces; no other CIDs are
# generated. One CORD2R per shell avoids angle conventions and skew ambiguity.
shell_material_cid(m::Model, gr::ElemGroup, e::Int) = gr.eids[e]

function shell_result_rotation(m::Model, gr::ElemGroup, e::Int;
                               path=stringer_path(m.grid.wing,m.params))
    gx, gy, _ = shell_geometric_frame(element_points(m, gr, e))
    x, _, _ = shell_material_frame(m, gr, e;path)
    return (sum(x .* gx), sum(x .* gy))
end

"""Rotate native geometric shell components into the deck's material frame."""
function rotate_shell_results!(data::AbstractDict, field::String, c::Real, s::Real)
    function tensor!(d, kx, ky, kxy)
        keys = (kx, ky, kxy)
        if all(k -> get(d, k, nothing) isa Real && isfinite(d[k]), keys)
            xx, yy, xy = (Float64(d[k]) for k in keys)
            d[kx] = c*c*xx + s*s*yy + 2c*s*xy
            d[ky] = s*s*xx + c*c*yy - 2c*s*xy
            d[kxy] = c*s*(yy-xx) + (c*c-s*s)*xy
        else
            # An incomplete tensor cannot be relabeled as rotated components.
            for k in keys; pop!(d, k, nothing); end
        end
    end
    if field == "stress"
        for face in ("z1", "z2")
            d = get(data, face, nothing)
            d isa AbstractDict || continue
            # JSON.Object supports reading but not Dict's pop! API. Work on an
            # owned Dict so sparse/native inputs follow the same path.
            d = Dict{String,Any}(String(k) => v for (k, v) in d)
            data[face] = d
            tensor!(d, "normal_x", "normal_y", "shear_xy")
        end
    elseif field == "forces"
        tensor!(data, "fx", "fy", "fxy")
        tensor!(data, "mx", "my", "mxy")
        if all(k -> get(data, k, nothing) isa Real && isfinite(data[k]), ("qx", "qy"))
            qx, qy = data["qx"], data["qy"]
            data["qx"], data["qy"] = c*qx + s*qy, -s*qx + c*qy
        else
            pop!(data, "qx", nothing); pop!(data, "qy", nothing)
        end
    end
    return data
end
