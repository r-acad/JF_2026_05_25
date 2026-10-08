# Dimension-defined sections shared by the PBARL writer and the 3D viewer.
# PBARL T: DIM1=flange width (z), DIM2=overall height (y), DIM3=flange
# thickness, DIM4=web thickness. Positive local y points from the web tip
# toward the flange (outward for skin stringers, inboard for most rib bars).
# Reference: https://help.altair.com/hwsolvers/os/topics/solvers/os/pbarl_bulk_r.htm
const LEGACY_SECTION_KEYS = Set(("properties.a_stringer", "properties.a_spar_cap",
                                 "properties.i_stringer", "properties.i_spar_cap"))
const STRINGER_DIMENSION_KEYS = ("properties.stringer_flange_width",
    "properties.stringer_height", "properties.stringer_flange_thickness",
    "properties.stringer_web_thickness")

function migrate_legacy_sections!(p::AbstractDict, flat::AbstractDict)
    notes = String[]
    readreal(v) = v isa AbstractString ? parse(Float64, strip(v)) : Float64(v)
    for (part, keys, oldarea) in (("stringer", STRINGER_DIMENSION_KEYS, 1.2e-4),
            ("spar_cap", ("properties.spar_cap_side",), 4.0e-4))
        akey, ikey = "properties.a_" * part, "properties.i_" * part
        haskey(flat, akey) || haskey(flat, ikey) || continue
        inertia = readreal(get(flat, ikey, 0.0))
        isfinite(inertia) && inertia >= 0 || throw(ArgumentError("$ikey must be finite and nonnegative"))
        inertia == 0 || throw(ArgumentError(
            "$ikey is a legacy explicit inertia that cannot be preserved by a dimension-defined PBARL section. " *
            "Replace $akey and $ikey with " * join(keys, ", ") * " to define the new section explicitly."))
        area = readreal(get(flat, akey, oldarea))
        isfinite(area) && area > 0 || throw(ArgumentError("$akey must be positive and finite"))
        if any(haskey(flat, key) for key in keys)
            # Explicit dimensions are the only source of section properties.
            # Reject a conflicting legacy area instead of discarding a custom value.
            explicit_area = part == "spar_cap" ? p[first(keys)]^2 :
                p[keys[1]] * p[keys[3]] + (p[keys[2]] - p[keys[3]]) * p[keys[4]]
            isapprox(area, explicit_area; rtol = 1e-10) || throw(ArgumentError(
                "$akey conflicts with the PBARL dimensions; remove the legacy area after checking the new section."))
        elseif haskey(flat, akey)
            scale = sqrt(area / oldarea)
            for key in keys
                p[key] *= scale
            end
            push!(notes, "$akey=$(area) m2 converted to " *
                (part == "stringer" ? "a proportionally scaled T section" : "a square spar cap") *
                "; area is preserved and bending/torsional properties now come from its dimensions.")
        end
    end
    isempty(notes) || (p["section_migration_notes"] = notes)
    return p
end

"""
    section_definition(params, pid) -> Dict

Section polygon coordinates are `[local_y, local_z]`, about the centroid.
`offset_y_m` is the centroid offset from the shell GRID line. Both CBAR ends
use this same offset along the projected section orientation, so the analytical
axis remains parallel to the GRID line. The outer flange/cap face lies on the
skin or rib datum. Areas and bending inertias are exact; J uses the JFEM PBARL
approximations, explicitly identified in `torsion_model`.
"""
function section_definition(p::AbstractDict, pid::Integer)
    base_pid=component_base_pid(pid)
    if base_pid in (PID_STRINGER,PID_RIB_STIFFENER)
        dimensions=base_pid==PID_STRINGER ? panel_stringer_dimensions(p,pid) :
            rib_stiffener_dimensions(p,pid==PID_RIB_STIFFENER ? 0 : pid%COMPONENT_PID_STRIDE)
        validate_t_section_dimensions(dimensions,base_pid==PID_STRINGER ? "Stringer T section" : "Rib T stiffener")
        b, h, tf, tw = dimensions
        hw = h - tf
        af, aw = b * tf, hw * tw
        area = af + aw
        yc = (aw * hw / 2 + af * (hw + tf / 2)) / area # from web tip
        i1 = tw * hw^3 / 12 + aw * (yc - hw / 2)^2 +
             b * tf^3 / 12 + af * (hw + tf / 2 - yc)^2
        i2 = hw * tw^3 / 12 + tf * b^3 / 12
        torsion = (hw * tw^3 + b * tf^3) / 3
        polygon = [[h-yc, -b/2], [h-yc, b/2], [hw-yc, b/2],
                   [hw-yc, tw/2], [-yc, tw/2], [-yc, -tw/2],
                   [hw-yc, -tw/2], [hw-yc, -b/2]]
        return Dict{String,Any}(
            "type" => "PBARL", "shape" => "T", "dimensions_m" => [b,h,tf,tw],
            "polygon_yz_m" => polygon, "offset_y_m" => -(h-yc),
            "area_m2" => area, "I1_m4" => i1, "I2_m4" => i2, "J_m4" => torsion,
            "torsion_model" => "JFEM PBARL open-section thin-wall approximation",
            "placement" => base_pid==PID_STRINGER ? "Flange outer face at skin; web inward; centroid offset included in CBAR" :
                "Flange outer face on rib-web datum; web outboard (final rib inboard); centroid offset included in CBAR")
    elseif base_pid == PID_SPAR_CAP
        side = Float64(p["properties.spar_cap_side"])
        return Dict{String,Any}(
            "type" => "PBARL", "shape" => "BAR", "dimensions_m" => [side,side],
            "polygon_yz_m" => [[side/2,-side/2], [side/2,side/2],
                                  [-side/2,side/2], [-side/2,-side/2]],
            "offset_y_m" => -side/2, "area_m2" => side^2,
            "I1_m4" => side^4/12, "I2_m4" => side^4/12,
            "J_m4" => side^4/3 * (1 - 0.63),
            "torsion_model" => "JFEM PBARL rectangular-section approximation",
            "placement" => "Outer face at skin; square inward; centroid offset included in CBAR")
    elseif base_pid == PID_STRINGER_RUNOUT
        area = STRINGER_RUNOUT_AREA
        side = sqrt(area)
        return Dict{String,Any}(
            "type" => "PBAR", "shape" => "BAR", "dimensions_m" => [side,side],
            "polygon_yz_m" => [[side/2,-side/2], [side/2,side/2],
                                  [-side/2,side/2], [-side/2,-side/2]],
            "offset_y_m" => 0.0, "area_m2" => area,
            "I1_m4" => area^2/12, "I2_m4" => area^2/12, "J_m4" => 0.1406*area^2,
            "torsion_model" => "Fixed-area connector equivalent square",
            "placement" => "Fixed 0.001 m2 connector centered on the GRID line")
    end
    throw(ArgumentError("no bar section for PID $pid"))
end

"""Common global WA/WB vector, matching the local axes shown by the viewer."""
function bar_section_offset(m::Model, gr::ElemGroup, el::Int)
    scale = section_definition(m.params, gr.pid)["offset_y_m"]
    scale == 0 && return (0.0, 0.0, 0.0)
    a, b = gr.conn[2el-1], gr.conn[2el]
    pa = ntuple(k -> m.xyz[3a-3+k], 3)
    pb = ntuple(k -> m.xyz[3b-3+k], 3)
    x = unit3(pb .- pa)
    v = ntuple(k -> gr.orient[3el-3+k], 3)
    y = unit3(v .- (sum(x .* v) .* x))
    return scale .* y
end
