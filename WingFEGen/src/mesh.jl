# ===========================================================================
#  mesh.jl - congruent wing torsion box with stringer runouts
#
#  Congruency by construction
#  --------------------------
#  Every node in the structural model is addressed by an integer triple
#
#        (i, j, k)      i : chordwise, 0 at the front spar .. ni at the rear spar
#                       j : spanwise,  0 at the root        .. nj at the tip
#                       k : through the box height, 0 on the lower skin
#                                                  .. nh on the upper skin
#
#  and its position is a pure function of that triple (`grid_point`). The
#  chordwise labels follow parallel piecewise stringer paths until a runout merges
#  them into a spar. The registry canonicalizes merged labels to the spar
#  label, so skins, webs, caps and runout connectors share the same nodes:
#
#    * lower skin            k = 0
#    * upper skin            k = nh
#    * front spar web        i = 0,  k = 0 .. nh
#    * rear spar web         i = ni, k = 0 .. nh
#    * rib webs              j at a rib station, all i and k
#    * spar cap bars         i = 0 and i = ni, on k = 0 and k = nh
#    * stringer bars         active physical stringer indices, on both skins
#    * shell-only lines      chordwise subdivisions between physical boundaries
#    * runout bars           last active stringer node -> next spar cap node
#    * runout triangles      skin cells with one collapsed edge
#
#  Interior web points are linearly interpolated between the lower and upper
#  skin points of the same (i, j), which is what makes the rib boundary and
#  the spar web share nodes exactly at the four corners of every rib.
# ===========================================================================

# --- property and group identifiers ---------------------------------------

const MID_STRUCT = 1
const PID_SKIN_UPPER = 1
const PID_SKIN_LOWER = 2
const PID_SPAR_WEB = 3
const PID_RIB_WEB = 4
const PID_AERO = 5
const PID_LE_SKIN = 6
const PID_LE_RIB = 7
const PID_STRINGER = 11
const PID_SPAR_CAP = 12
const PID_STRINGER_RUNOUT = 13
const PID_RIB_STIFFENER = 14
const STRINGER_RUNOUT_AREA = 0.001   # m^2, fixed connector area

"""
    BoxGrid

The index space of the torsion box together with the chordwise and spanwise
station tables and the list of spanwise indices that carry a rib.
"""
struct BoxGrid
    wing::Wing
    xcs::Vector{Float64}    # chordwise x/c stations, front spar -> rear spar
    etas::Vector{Float64}   # spanwise stations, root -> tip
    nh::Int                 # elements through the box height
    ribs::Vector{Int}       # zero-based j indices carrying a rib
    lower_xcs::Matrix{Float64} # surface intersections of the stringer planes
    upper_xcs::Matrix{Float64}
    collapsed::Matrix{Int}    # 0 active, -1 merged into front, +1 into rear
    stringer_indices::Vector{Int} # zero-based physical stringers; excludes shell-only lines
    lower_etas::Matrix{Float64}  # actual surface span locations on angled rows
    upper_etas::Matrix{Float64}
    rib_layout::Any
end

BoxGrid(w,xcs,etas,nh,ribs,lower,upper,collapsed,stringers)=BoxGrid(w,xcs,etas,nh,ribs,lower,upper,collapsed,stringers,
    repeat(reshape(etas,1,:),length(xcs),1),repeat(reshape(etas,1,:),length(xcs),1),nothing)
grid_surface_eta(g::BoxGrid,i::Int,j::Int,upper::Bool)= (upper ? g.upper_etas : g.lower_etas)[i+1,j+1]
oriented_ribs(g::BoxGrid)=g.rib_layout!==nothing&&any(!iszero,g.rib_layout.deltas)
main_rib_plane(g::BoxGrid,p::AbstractDict,j::Int)=main_rib_plane(g.wing,g.rib_layout===nothing ? physical_rib_layout(g.wing,p) : g.rib_layout,g.etas[j+1])

ni(g::BoxGrid) = length(g.xcs) - 1
nj(g::BoxGrid) = length(g.etas) - 1

"""
    grid_point(g, i, j, k) -> (x, y, z)

Position of the structural grid point with index triple `(i, j, k)`.
"""
function grid_point(g::BoxGrid, i::Int, j::Int, k::Int)
    pl = lower_point(g.wing, g.lower_etas[i+1,j+1], g.lower_xcs[i+1,j+1])
    pu = upper_point(g.wing, g.upper_etas[i+1,j+1], g.upper_xcs[i+1,j+1])
    t = k / g.nh
    return (pl[1] + t * (pu[1] - pl[1]),
            pl[2] + t * (pu[2] - pl[2]),
            pl[3] + t * (pu[3] - pl[3]))
end

"""
    NodeRegistry

Hands out one node per index triple and records its position. This is the
single mechanism that guarantees a congruent mesh.
"""
mutable struct NodeRegistry
    index::Dict{NTuple{3,Int},Int}
    keys::Vector{NTuple{3,Int}}
    xyz::Vector{Float64}
end
NodeRegistry() = NodeRegistry(Dict{NTuple{3,Int},Int}(), NTuple{3,Int}[], Float64[])

"""
    node!(reg, g, i, j, k) -> Int

Index of the node at `(i, j, k)`, creating it on first use.
"""
function node!(reg::NodeRegistry, g::BoxGrid, i::Int, j::Int, k::Int)
    side = g.collapsed[i+1,j+1]
    i = side < 0 ? 0 : side > 0 ? ni(g) : i
    key = (i, j, k)
    idx = get(reg.index, key, 0)
    idx != 0 && return idx
    p = grid_point(g, i, j, k)
    push!(reg.keys, key)
    append!(reg.xyz, p)
    idx = length(reg.keys)
    reg.index[key] = idx
    return idx
end

"""
    add_free_node!(reg, p) -> Int

Add a node that is not part of the index space, used for the RBE3 reference
nodes. It is keyed on a negative sentinel triple so it can never collide with
a structural grid point.
"""
function add_free_node!(reg::NodeRegistry, p)
    key = (-1, -length(reg.keys) - 1, -1)
    push!(reg.keys, key)
    append!(reg.xyz, p)
    idx = length(reg.keys)
    reg.index[key] = idx
    return idx
end

"""Chord columns at equal mean upper/lower surface arc length, nose to front spar.

The lofted section is piecewise linear at the union of its root/tip surface
knots, so the cumulative lengths are exact for the airfoil representation.
Using the mean length retains common upper/lower chord columns for the ribs.
It resolves the curved nose without crowding a second set of rows at the spar.
Twist and section scaling preserve this normalized arc-length distribution.
"""
function leading_edge_chord_stations(g::BoxGrid, n::Int)
    w = g.wing
    knots = airfoil_knots(w)
    stations = Matrix{Float64}(undef,n+1,length(g.etas))
    for (j,eta) in enumerate(g.etas)
        front = g.lower_xcs[1,j]
        xs = vcat(0.0,filter(x -> 0.0 < x < front,knots),front)
        upper = zup.(Ref(w),eta,xs)
        lower = zlo.(Ref(w),eta,xs)
        lengths = zeros(length(xs))
        for q in 2:length(xs)
            dx = xs[q]-xs[q-1]
            lengths[q] = lengths[q-1] +
                (hypot(dx,upper[q]-upper[q-1])+hypot(dx,lower[q]-lower[q-1]))/2
        end
        stations[1,j] = 0.0
        stations[end,j] = front
        for i in 1:n-1
            stations[i+1,j] = table_interp(lengths,xs,lengths[end]*i/n)
        end
    end
    return stations
end

"""Leading-edge index columns are negative; the front spar keeps its existing GRID.

All height indices collapse to one nose GRID at each span station. The first
rib column consequently forms a triangle fan, never zero-area quadrilaterals.
Negative span indices remain reserved for free RBE3 reference nodes.
"""
leading_edge_column_count(stations::Matrix{Float64}) = size(stations,1)-1
function leading_edge_skin_points(stations::Matrix{Float64},g::BoxGrid,i::Int,j::Int)
    eta,xc = g.etas[j+1],stations[i+1,j+1]
    return lower_point(g.wing,eta,xc),upper_point(g.wing,eta,xc)
end

function leading_edge_node!(reg::NodeRegistry, g::BoxGrid, stations, i::Int, j::Int, k::Int)
    n = leading_edge_column_count(stations)
    i == n && return node!(reg, g, 0, j, k)
    key = (i - n, j, i == 0 ? 0 : k)
    haskey(reg.index, key) && return reg.index[key]
    lower, upper = leading_edge_skin_points(stations,g,i,j)
    if i == 0
        norm3(upper .- lower) <= 1e-9 * g.wing.chord_root ||
            throw(ArgumentError("leading-edge structure requires upper/lower airfoil surfaces to meet at the nose"))
    end
    t = k / g.nh
    position = lower .+ t .* (upper .- lower)
    push!(reg.keys, key); append!(reg.xyz, position)
    idx = length(reg.keys); reg.index[key] = idx
    return idx
end

"""
    ElemGroup

One family of elements. `conn` is a flat list of node indices, four per
`:quad`, three per `:tria`, and two per `:bar` element. `orient`
holds the CBAR orientation vector of each bar, three components per element.
"""
struct ElemGroup
    name::String
    kind::Symbol
    pid::Int
    eids::Vector{Int}
    conn::Vector{Int}
    orient::Vector{Float64}
end

ElemGroup(name, kind, pid) = ElemGroup(name, kind, pid, Int[], Int[], Float64[])

n_elements(gr::ElemGroup) = length(gr.eids)

"""
    RBE3Spider

One RBE3: an independent reference node at a chord fraction of a rib station,
tied to the translations of every skin-to-rib and spar-to-rib intersection of
that station.
"""
struct RBE3Spider
    eid::Int
    ref::Int              # node index of the reference grid
    dep::Vector{Int}      # node indices of the connected grids
    station::Int          # spanwise index j of the rib
    eta::Float64
end

"""One separate rigid interpolation center and mass element per physical fuel bay."""
struct FuelBaySpider
    eid::Int
    mass_eid::Int
    ref::Int
    dep::Vector{Int}
    start_rib::Int
    end_rib::Int
end

"""
    Model

The complete generated model: nodes, element groups, RBE3 spiders, the
constrained root nodes, the aerodynamic loft and the reporting data.
"""
struct Model
    params::Dict{String,Any}
    wing::Wing
    grid::BoxGrid
    node_ids::Vector{Int}
    xyz::Vector{Float64}
    node_keys::Vector{NTuple{3,Int}}
    n_struct::Int
    groups::Vector{ElemGroup}
    rbe3::Vector{RBE3Spider}
    spc::Vector{Int}
    aero_xyz::Vector{Float64}
    aero_quads::Vector{Int}
    aero_nloop::Int
    aero_map::Vector{Int}          # 4 legacy / 8 interpolated structural nodes per aero node
    aero_weights::Vector{Float64}  # section weights, interpolated across span if needed
    info::Vector{Tuple{String,String}}
    checks::Vector{Tuple{String,String,Bool}}
    le_rib_metadata::Vector{Dict{String,Any}}
    fuel_rbe3::Vector{FuelBaySpider}
end

Model(params,wing,grid,node_ids,xyz,node_keys,n_struct,groups,rbe3,spc,aero_xyz,aero_quads,aero_nloop,aero_map,aero_weights,info,checks)=
    Model(params,wing,grid,node_ids,xyz,node_keys,n_struct,groups,rbe3,spc,aero_xyz,aero_quads,aero_nloop,aero_map,aero_weights,info,checks,Dict{String,Any}[])
Model(params,wing,grid,node_ids,xyz,node_keys,n_struct,groups,rbe3,spc,aero_xyz,aero_quads,aero_nloop,aero_map,aero_weights,info,checks,le_rib_metadata)=
    Model(params,wing,grid,node_ids,xyz,node_keys,n_struct,groups,rbe3,spc,aero_xyz,aero_quads,aero_nloop,aero_map,aero_weights,info,checks,le_rib_metadata,FuelBaySpider[])

# ---------------------------------------------------------------------------
#  Station layout
# ---------------------------------------------------------------------------

"""
    chord_stations(w, p) -> (xcs, n_stringer_bays)

Root stations with the exact requested pitch between stringers. The leftover
width is split equally between the spars, with each edge margin at least one
pitch. These stations seed parallel vertical planes, not constant-x/c lines.
"""
function chord_stations(w::Wing, p::AbstractDict)
    spars = spar_geometry(p)
    fs = spar_surface_xc(w, spars, 0.0, :front)
    rs = spar_surface_xc(w, spars, 0.0, :rear)
    width_root = (rs - fs) * w.chord_root
    pitch = p["box.stringer_pitch"]
    ns = max(0, floor(Int, width_root / pitch + 1e-10) - 1)
    margin = (width_root - (ns - 1) * pitch) / 2
    xcs = vcat(fs, [fs + (margin + (i - 1) * pitch) / w.chord_root
                    for i in 1:ns], rs)
    return xcs, ns + 1
end

# Invert the actual twisted skin abscissa, so each stringer really lies in
# its specified plane even when the upper/lower x/c intersections differ.
function plane_skin_xc(w, eta, target_x, fs, rs, upper)
    surface = upper ? upper_point : lower_point
    lo, hi = fs, rs
    for _ in 1:48
        mid = (lo + hi) / 2
        if surface(w, eta, mid)[1] < target_x
            lo = mid
        else
            hi = mid
        end
    end
    return (lo + hi) / 2
end

"""
Build variable-width skin rows, retiring a line at the first station where
either skin comes within the requested fraction of a pitch of a spar in
projected x. Both skin lines
terminate together, preserving a conforming rib web. A terminating line is
merged into the cap at that station; the preceding edge becomes a runout.
Refine a span strip if several lines would terminate at the same spar, so
each collapse produces one triangle without overlapping connectors.
"""
function stringer_grid(w, p, xcs, base_etas, base_ribs, nh)
    layout=physical_rib_layout(w,p)
    any(!iszero,layout.deltas)&&return oriented_stringer_grid(w,p,xcs,base_etas,base_ribs,nh,layout)
    spars = spar_geometry(p)
    pitch = p["box.stringer_pitch"]
    clearance = pitch * get(p, "mesh.stringer_runout_ratio", 1.0)
    path = stringer_path(w, p)
    roots = [section_point(w, 0.0, xc, 0.0)[1] for xc in xcs]
    count = length(xcs)
    etas = Float64[0.0]
    states = [zeros(Int, count)]
    tol = 1e-10 * max(w.chord_root, pitch)

    function advance(eta, depth = 0)
        prev = states[end]
        next = copy(prev)
        fs, rs = spar_surface_xc(w, spars, eta, :front), spar_surface_xc(w, spars, eta, :rear)
        # Use the most restrictive upper/lower clearance at each spar.
        front = max(lower_point(w, eta, fs)[1], upper_point(w, eta, fs)[1])
        rear = min(lower_point(w, eta, rs)[1], upper_point(w, eta, rs)[1])
        for i in 2:count-1
            prev[i] == 0 || continue
            x = roots[i] + stringer_offset(path, eta)
            df, dr = x - front, rear - x
            if min(df, dr) < clearance - tol
                next[i] = df <= dr ? -1 : 1
            end
        end
        nf = sum(prev[i] == 0 && next[i] == -1 for i in 2:count-1; init = 0)
        nr = sum(prev[i] == 0 && next[i] == 1 for i in 2:count-1; init = 0)
        if nf > 1 || nr > 1
            depth < 40 || throw(ArgumentError("stringer runouts could not be separated; check the pitch and angle"))
            advance((etas[end] + eta) / 2, depth + 1)
            advance(eta, depth + 1)
        else
            push!(etas, eta)
            push!(states, next)
        end
    end
    for eta in base_etas[2:end]
        advance(eta)
    end
    ribs = [searchsortedfirst(etas, base_etas[j+1]) - 1 for j in base_ribs]
    collapsed = hcat(states...)
    lower = Matrix{Float64}(undef, count, length(etas))
    upper = similar(lower)
    for (j, eta) in enumerate(etas), i in 1:count
        fs, rs = spar_surface_xc(w, spars, eta, :front), spar_surface_xc(w, spars, eta, :rear)
        side = collapsed[i,j]
        if i == 1 || i == count || side != 0
            xc = i == 1 || side < 0 ? fs : rs
            lower[i,j] = upper[i,j] = xc
        elseif j == 1
            lower[i,j] = upper[i,j] = xcs[i]
        else
            x = roots[i] + stringer_offset(path, eta)
            lower[i,j] = plane_skin_xc(w, eta, x, fs, rs, false)
            upper[i,j] = plane_skin_xc(w, eta, x, fs, rs, true)
        end
    end
    grid=BoxGrid(w,xcs,etas,nh,ribs,lower,upper,collapsed,collect(1:count-2))
    return layout.legacy ? grid : BoxGrid(w,xcs,etas,nh,ribs,lower,upper,collapsed,grid.stringer_indices,grid.lower_etas,grid.upper_etas,layout)
end

"""
    refine_stringer_bays(g, subdivisions) -> BoxGrid

Subdivide each physical chordwise bay into the requested number of shell
elements without changing the stringer planes, runout stations or spar caps.
New skin stations interpolate x/c between the original boundaries; the rib
webs use those same stations through the height. Stringer bars remain on the
original boundaries, recorded separately in `stringer_indices`.

When a bay retires into a spar, all its subdivision lines merge into that
same cap node. Its last span strip therefore becomes a conforming triangle
fan, with the physical runout connector as one boundary edge. Subdivisions
in the adjacent surviving bay remain active and share that edge exactly.
"""
function refine_stringer_bays(g::BoxGrid, subdivisions::Int)
    subdivisions >= 1 || throw(ArgumentError("mesh.elements_between_stringers must be at least 1"))
    subdivisions == 1 && return g
    oriented_ribs(g)&&return refine_oriented_stringer_bays(g,subdivisions)
    ncoarse = ni(g)
    nrefined = ncoarse * subdivisions
    nspan = length(g.etas)
    xcs = Vector{Float64}(undef, nrefined + 1)
    lower = Matrix{Float64}(undef, nrefined + 1, nspan)
    upper = similar(lower)
    collapsed = Matrix{Int}(undef, nrefined + 1, nspan)
    for bay in 0:ncoarse-1, sub in 0:subdivisions-1
        dst = bay * subdivisions + sub + 1
        left, right = bay + 1, bay + 2
        t = sub / subdivisions
        xcs[dst] = (1 - t) * g.xcs[left] + t * g.xcs[right]
        for j in 1:nspan
            if sub == 0
                # Preserve physical boundaries and their coordinates exactly.
                lower[dst,j] = g.lower_xcs[left,j]
                upper[dst,j] = g.upper_xcs[left,j]
                collapsed[dst,j] = g.collapsed[left,j]
            else
                leftside = bay == 0 ? -1 : g.collapsed[left,j]
                rightside = bay + 1 == ncoarse ? 1 : g.collapsed[right,j]
                side = leftside == rightside ? leftside : 0
                collapsed[dst,j] = side
                if side != 0
                    lower[dst,j] = upper[dst,j] = side < 0 ? g.lower_xcs[1,j] : g.lower_xcs[end,j]
                else
                    lower[dst,j] = (1 - t) * g.lower_xcs[left,j] + t * g.lower_xcs[right,j]
                    upper[dst,j] = (1 - t) * g.upper_xcs[left,j] + t * g.upper_xcs[right,j]
                end
            end
        end
    end
    xcs[end] = g.xcs[end]
    lower[end,:] .= g.lower_xcs[end,:]
    upper[end,:] .= g.upper_xcs[end,:]
    collapsed[end,:] .= g.collapsed[end,:]
    grid=BoxGrid(g.wing,xcs,g.etas,g.nh,g.ribs,lower,upper,collapsed,g.stringer_indices .* subdivisions)
    return BoxGrid(grid.wing,grid.xcs,grid.etas,grid.nh,grid.ribs,grid.lower_xcs,grid.upper_xcs,grid.collapsed,grid.stringer_indices,grid.lower_etas,grid.upper_etas,g.rib_layout)
end

"""
    span_stations(w, p) -> (etas, ribs, n_rib_bays)

Spanwise stations and rib indices. The rib pitch is measured along the
reference line and rounded to a whole number of bays, so ribs always land on
the root and on the final box rib at `box.end_eta`. Each bay is then subdivided into
`mesh.elements_between_ribs` elements, which keeps every rib on a node line.
"""
function span_stations(w::Wing, p::AbstractDict)
    m = p["mesh.elements_between_ribs"]
    end_eta = Float64(p["box.end_eta"])
    if !isempty(get(p,"ribs.masters",Any[]))
        layout=physical_rib_layout(w,p);rib_etas=[row.eta for row in layout.physical]
        etas=Float64[]
        for bay in 1:length(rib_etas)-1
            a,b=layout.physical[bay].arc,layout.physical[bay+1].arc
            for k in 0:m-1
                push!(etas,k==0 ? rib_etas[bay] : rear_arc_eta(layout.arc,a+(b-a)*k/m))
            end
        end
        push!(etas,end_eta)
        # An angled grid resolves spar/stringer kinks on the affected element
        # edges. Adding the rear-ETA breakpoint as another complete row would
        # still leave a narrow strip beside a nearly coincident regular row.
        all(iszero,layout.deltas)&&(etas=with_stations(etas,vcat(spar_breakpoints(p),stringer_path(w,p).kink_etas)))
        etas=with_planform_stations(w,etas)
        return etas,[searchsortedfirst(etas,eta)-1 for eta in rib_etas],length(rib_etas)-1
    end
    nb = max(1, round(Int, end_eta * reference_length(w) / p["box.rib_pitch"]))
    njj = nb * m
    etas = [end_eta * (j / njj) for j in 0:njj]
    rib_etas = etas[1:m:end]
    etas = with_stations(etas, vcat(spar_breakpoints(p),stringer_path(w,p).kink_etas))
    etas = with_planform_stations(w, etas)
    ribs = [searchsortedfirst(etas, eta) - 1 for eta in rib_etas]
    return etas, ribs, nb
end

"""Retain edge kinks as mesh rows without creating additional physical ribs.

Coincident stations retain their original coordinates, preventing tiny strips
from decimal round-off at a rib or prescribed aerodynamic station.
"""
function with_planform_stations(w::Wing, stations::AbstractVector)
    return with_stations(stations, planform_breakpoints(w))
end

function with_stations(stations::AbstractVector, breakpoints::AbstractVector)
    etas = Float64[stations...]
    lo, hi = first(etas), last(etas)
    for eta in breakpoints
        lo < eta < hi || continue
        any(x -> abs(x-eta) <= 1e-12, etas) || push!(etas, eta)
    end
    return sort!(etas)
end

"""Inclusive physical rib interval; zero selects the final box rib at End ETA."""
function leading_edge_rib_bounds(p::AbstractDict, rib_count::Int)
    first_rib = Int(p["leading_edge.start_rib"])
    requested_last = Int(p["leading_edge.end_rib"])
    last_rib = requested_last == 0 ? rib_count : requested_last
    1 <= first_rib < last_rib <= rib_count || throw(ArgumentError(
        "leading-edge ribs must satisfy 1 <= first < last <= $rib_count; " *
        "got first=$first_rib, last=$last_rib (last=0 selects the final box rib)"))
    return first_rib,last_rib
end

"""Physical leading-edge bays and the ribs that close their retained segments."""
function leading_edge_layout(p::AbstractDict, rib_count::Int)
    first_rib,last_rib=leading_edge_rib_bounds(p,rib_count)
    disabled=leading_edge_disabled_bays(p,rib_count)
    active_bays=[bay for bay in first_rib:last_rib-1 if !(bay in disabled)]
    active_ribs=sort!(unique(vcat(active_bays,active_bays.+1)))
    return (;first_rib,last_rib,disabled,active_bays,active_ribs)
end

function leading_edge_summary(m::Model)
    result=Dict{String,Any}("enabled"=>m.params["leading_edge.enabled"],"rib_count"=>length(m.grid.ribs),
        "rib_orientation"=>get(m.params,"leading_edge.rib_orientation","flight_direction"),
        "rib_angle_deg"=>get(m.params,"leading_edge.rib_angle",90.0))
    result["enabled"] || return result
    layout=leading_edge_layout(m.params,length(m.grid.ribs))
    merge!(result,Dict("start_rib"=>layout.first_rib,"end_rib"=>layout.last_rib,
        "eta_start"=>m.grid.etas[m.grid.ribs[layout.first_rib]+1],"eta_end"=>m.grid.etas[m.grid.ribs[layout.last_rib]+1],
        "disabled_bays"=>layout.disabled,"active_bays"=>layout.active_bays,
        "active_ribs"=>layout.active_ribs,"mesh_present"=>!isempty(layout.active_bays)))
    reference=leading_edge_reference(m.wing,m.params)
    result["inboard_front_spar_tangent"]=collect(reference.tangent)
    result["angle_reference_note"]="Common root front-spar segment, outboard tangent toward nose in plan view; 90 degrees perpendicular. Physical rib/bay indices refer to front-spar attachments. Closure angles are not clipped at the root or tip."
    orientations=leading_edge_orientation_metadata(m)
    result["ribs"]=orientations
    result["fallback_ribs"]=[row["rib"] for row in orientations if get(row,"fallback",false)]
    result["warnings"]=["Leading-edge rib $(row["rib"]): $(row["reason"])" for row in orientations if get(row,"fallback",false)]
    result
end

# ---------------------------------------------------------------------------
#  Surface normals for the bar orientation vectors
# ---------------------------------------------------------------------------

"""
    skin_normal(g, i, j, upper) -> (nx, ny, nz)

Outward unit normal of the skin at the grid point `(i, j)`, evaluated from
central differences on the skin surface. It is used as the CBAR orientation
vector of the stringers and spar caps, which puts CBAR plane 1 in the
out-of-plane bending direction of the skin.
"""
function skin_normal(g::BoxGrid, i::Int, j::Int, upper::Bool)
    k = upper ? g.nh : 0
    # Keep the physical bar axes invariant when only the shell density changes.
    stride = isempty(g.stringer_indices) ? ni(g) : first(g.stringer_indices)
    i0 = max(i - stride, 0)
    i1 = min(i + stride, ni(g))
    j0 = max(j - 1, 0)
    j1 = min(j + 1, nj(g))
    dchord = grid_point(g, i1, j, k) .- grid_point(g, i0, j, k)
    dspan = grid_point(g, i, j1, k) .- grid_point(g, i, j0, k)
    n = unit3(cross3(dchord, dspan))     # chordwise x spanwise points up
    norm3(n) < 0.5 && return (0.0, 0.0, upper ? 1.0 : -1.0)
    return upper ? n : (-n[1], -n[2], -n[3])
end

# ---------------------------------------------------------------------------
#  Model assembly
# ---------------------------------------------------------------------------

"""
    build_model(p) -> Model

Generate the whole finite element model from the flat parameter dictionary.
"""
function build_model(p::AbstractDict; progress = stage -> nothing)
    progress("geometry")
    validate_params(p)
    w = make_wing(p)
    xcs, n_str_bays = chord_stations(w, p)
    etas, ribs, n_rib_bays = span_stations(w, p)
    nh = p["mesh.elements_spar_height"]
    g = refine_stringer_bays(stringer_grid(w, p, xcs, etas, ribs, nh),
                            get(p, "mesh.elements_between_stringers", 1))
    etas, ribs = g.etas, g.ribs
    NI = ni(g)
    NJ = nj(g)
    properties=resolved_component_properties(p,length(ribs))
    panel_layout=stiffened_panel_layout(g)
    register_panel_properties!(p,g;layout=panel_layout)

    progress("mesh")
    reg = NodeRegistry()

    # --- nodes, created in a tidy order so the BDF reads well --------------
    # Skins first, then the spar web interiors, then the rib web interiors.
    for j in 0:NJ, i in 0:NI
        node!(reg, g, i, j, 0)
        node!(reg, g, i, j, nh)
    end
    for j in 0:NJ, k in 1:nh-1
        node!(reg, g, 0, j, k)
        node!(reg, g, NI, j, k)
    end
    for jr in ribs, i in 1:NI-1, k in 1:nh-1
        node!(reg, g, i, jr, k)
    end
    n_struct = length(reg.keys)

    # --- element groups ---------------------------------------------------
    groups = ElemGroup[]
    eid = 1

    quad!(gr, a, b, c, d) = begin
        length(unique((a, b, c, d))) < 4 && return
        push!(gr.eids, eid)
        append!(gr.conn, (a, b, c, d))
        eid += 1
    end

    shell!(quads, trias, a, b, c, d) = begin
        nodes = unique([a, b, c, d])
        length(nodes) < 3 && return  # collapsed strip beyond a runout
        gr = length(nodes) == 3 ? trias : quads
        push!(gr.eids, eid)
        append!(gr.conn, nodes)
        eid += 1
    end

    # Upper skin. Ordered chordwise then spanwise so the normal points up.
    panel_groups=Dict{Tuple{String,Symbol,Int},ElemGroup}()
    skin!(upper,i,j,nodes) = begin
        unique_nodes=unique(nodes);length(unique_nodes)<3&&return
        id=panel_layout.skins[upper][i+1,j+1]
        base=upper ? PID_SKIN_UPPER : PID_SKIN_LOWER
        pid=id==0 ? base : panel_skin_pid(id,upper)
        kind=length(unique_nodes)==3 ? :tria : :quad
        name=(upper ? "UPPER_SKIN" : "LOWER_SKIN")*(kind===:tria ? "_RUNOUTS" : "")
        group=panel_element_group!(groups,panel_groups,name,kind,pid,base)
        push!(group.eids,eid);append!(group.conn,unique_nodes);eid+=1
    end
    for j in 0:NJ-1, i in 0:NI-1
        skin!(true,i,j,[
              node!(reg, g, i, j, nh), node!(reg, g, i + 1, j, nh),
              node!(reg, g, i + 1, j + 1, nh), node!(reg, g, i, j + 1, nh)])
    end

    # Lower skin, reversed so the normal points down, again outward.
    for j in 0:NJ-1, i in 0:NI-1
        skin!(false,i,j,[
              node!(reg, g, i, j, 0), node!(reg, g, i, j + 1, 0),
              node!(reg, g, i + 1, j + 1, 0), node!(reg, g, i + 1, j, 0)])
    end

    # Front spar web, normal pointing forward, out of the box.
    front_groups=Dict{Int,ElemGroup}()
    for j in 0:NJ-1, k in 0:nh-1
        bay=searchsortedlast(ribs,j)
        gf=property_group!(groups,front_groups,"FRONT_SPAR_WEB",:quad,properties.bays[bay].front_pid,PID_SPAR_WEB)
        quad!(gf,
              node!(reg, g, 0, j, k), node!(reg, g, 0, j, k + 1),
              node!(reg, g, 0, j + 1, k + 1), node!(reg, g, 0, j + 1, k))
    end

    # Rear spar web, normal pointing aft, out of the box.
    rear_groups=Dict{Int,ElemGroup}()
    for j in 0:NJ-1, k in 0:nh-1
        bay=searchsortedlast(ribs,j)
        gr_=property_group!(groups,rear_groups,"REAR_SPAR_WEB",:quad,properties.bays[bay].rear_pid,PID_SPAR_WEB)
        quad!(gr_,
              node!(reg, g, NI, j, k), node!(reg, g, NI, j + 1, k),
              node!(reg, g, NI, j + 1, k + 1), node!(reg, g, NI, j, k + 1))
    end

    # Rib webs at every rib station, chordwise by height.
    rib_groups=Dict{Int,ElemGroup}()
    for (rib,jr) in enumerate(ribs), i in 0:NI-1, k in 0:nh-1
        grib=property_group!(groups,rib_groups,"RIB_WEBS",:quad,properties.ribs[rib].web_pid,PID_RIB_WEB)
        quad!(grib,
              node!(reg, g, i, jr, k), node!(reg, g, i + 1, jr, k),
              node!(reg, g, i + 1, jr, k + 1), node!(reg, g, i, jr, k + 1))
    end

    # Bars run spanwise along the skin node lines, one element per skin
    # element edge, so they are congruent with the shells by construction.
    bar!(gr, a, b, v) = begin
        push!(gr.eids, eid)
        append!(gr.conn, (a, b))
        append!(gr.orient, v)
        eid += 1
    end

    gcap = ElemGroup("SPAR_CAPS", :bar, PID_SPAR_CAP)
    for i in (0, NI), upper in (false, true)
        k = upper ? nh : 0
        for j in 0:NJ-1
            v = skin_normal(g, i, j, upper)
            bar!(gcap, node!(reg, g, i, j, k), node!(reg, g, i, j + 1, k), v)
        end
    end
    push!(groups, gcap)

    gout = ElemGroup("STRINGER_RUNOUTS", :bar, PID_STRINGER_RUNOUT)
    for i in g.stringer_indices, upper in (false, true)
        k = upper ? nh : 0
        for j in 0:NJ-1
            g.collapsed[i+1,j+1] == 0 || continue
            gr = g.collapsed[i+1,j+2] == 0 ? panel_element_group!(groups,panel_groups,"STRINGERS",:bar,
                panel_stringer_pid(panel_layout.bars[(i,j,upper)]),PID_STRINGER) : gout
            v = skin_normal(g, i, j, upper)
            bar!(gr, node!(reg, g, i, j, k), node!(reg, g, i, j + 1, k), v)
        end
    end
    push!(groups, gout)

    # Physical rib stiffeners follow the through-height edges at stringer
    # attachments. Shell-only refinement columns never add another section.
    stiffener_groups=Dict{Int,ElemGroup}()
    for (rib,jr) in enumerate(ribs)
        property=properties.ribs[rib];property.stiffener_enabled||continue
        normal=main_rib_plane(g,p,jr).normal
        # Positive local y points toward the flange face. The web lies on the
        # outboard side of each rib, except the final closure where it is inboard.
        direction=(rib==length(ribs) ? 1.0 : -1.0).*normal
        for i in g.stringer_indices
            g.collapsed[i+1,jr+1]==0||continue
            group=property_group!(groups,stiffener_groups,"RIB_STIFFENERS",:bar,property.stiffener_pid,PID_RIB_STIFFENER)
            for k in 0:nh-1
                bar!(group,node!(reg,g,i,jr,k),node!(reg,g,i,jr,k+1),direction)
            end
        end
    end

    # Optional load-carrying leading edge. Every skin row uses the same span
    # stations as the box, including inserted runout stations; ribs occur only
    # at physical rib stations. The complete front-spar boundary is shared.
    le_ribs = Int[]
    le_stations = Matrix{Float64}(undef,0,0)
    le_metadata=Dict{String,Any}[]
    if p["leading_edge.enabled"]
        progress("leading_edge")
        layout=leading_edge_layout(p,length(ribs))
        le_ribs=ribs[layout.active_ribs]
        nl = Int(p["leading_edge.chord_elements"])
        le_stations = leading_edge_mesh_stations(g,p,layout)
        hasproperty(le_stations,:metadata)&&(le_metadata=le_stations.metadata)
        le(i,j,k) = leading_edge_node!(reg,g,le_stations,i,j,k)
        leup = ElemGroup("LE_UPPER_SKIN", :quad, PID_LE_SKIN)
        lelo = ElemGroup("LE_LOWER_SKIN", :quad, PID_LE_SKIN)
        lerib = ElemGroup("LE_RIB_WEBS", :quad, PID_LE_RIB)
        lenose = ElemGroup("LE_RIB_NOSE", :tria, PID_LE_RIB)
        for bay in layout.active_bays, j in ribs[bay]:ribs[bay+1]-1, i in 0:nl-1
            quad!(leup, le(i,j,nh), le(i+1,j,nh), le(i+1,j+1,nh), le(i,j+1,nh))
            quad!(lelo, le(i,j,0), le(i,j+1,0), le(i+1,j+1,0), le(i+1,j,0))
        end
        for jr in le_ribs, i in 0:nl-1, k in 0:nh-1
            shell!(lerib,lenose,le(i,jr,k),le(i+1,jr,k),le(i+1,jr,k+1),le(i,jr,k+1))
        end
        push!(groups,leup,lelo,lerib,lenose)
    end
    n_struct = length(reg.keys)

    oriented_ribs(g) && (eid=split_oriented_kink_edges!(reg,g,groups,eid))
    n_struct = length(reg.keys)

    # --- RBE3 spiders ------------------------------------------------------
    rbe3 = RBE3Spider[]
    if p["rbe3.enabled"]
        ref_xc = p["rbe3.ref_xc"]
        for jr in ribs
            eta = etas[jr+1]
            # Independent node on the chord line at the requested fraction.
            reference=oriented_ribs(g) ? rib_reference_point(g,p,jr,ref_xc) : section_point(w,eta,ref_xc,0.0)
            refidx = add_free_node!(reg, reference)
            dep = Int[]
            # Skin to rib intersections: the two chordwise lines of the rib.
            for i in 0:NI
                push!(dep, node!(reg, g, i, jr, 0))
                push!(dep, node!(reg, g, i, jr, nh))
            end
            # Spar to rib intersections: the two vertical lines of the rib.
            for k in 1:nh-1
                push!(dep, node!(reg, g, 0, jr, k))
                push!(dep, node!(reg, g, NI, jr, k))
            end
            if jr in le_ribs
                nl = Int(p["leading_edge.chord_elements"])
                for i in 0:nl-1, k in (0,nh)
                    push!(dep,leading_edge_node!(reg,g,le_stations,i,jr,k))
                end
            end
            ref_eta=oriented_ribs(g) ? (reference[2]-w.root_ref_y)/w.semispan : eta
            push!(rbe3, RBE3Spider(eid, refidx, unique(dep), jr, ref_eta))
            eid += 1
        end
    end

    # --- supports on selected physical rib intersections -------------------
    # Keep the historical unique-node API; per-node component unions are
    # resolved from the same definition for the deck and viewer payload.
    spc = [row.node for row in support_assignments(g,reg.index,p)]

    # --- aerodynamic loft --------------------------------------------------
    # Keep the generating wing complete when its structural box stops early.
    # Existing box rows stay congruent; additional display rows continue to
    # the physical tip at the full-wing nominal spanwise mesh density.
    progress("aero")
    full_bays = max(1, round(Int, reference_length(w) / p["box.rib_pitch"]))
    full_intervals = full_bays * p["mesh.elements_between_ribs"]
    aero_etas = vcat(etas, [j / full_intervals for j in 1:full_intervals
                           if j / full_intervals > last(etas)])
    aero_etas = with_planform_stations(w, sort!(unique(vcat(aero_etas,w.airfoil_etas))))
    aero_xyz, aero_quads, aero_nloop, aero_uv =
        aero_surface(w, aero_etas, p["mesh.aero_chord_points"],
                     p["box.front_spar_xc"], p["box.rear_spar_xc"])
    aero_map,aero_w=oriented_ribs(g) ? aero_attachment_oriented(g,reg,aero_nloop,aero_etas,aero_xyz) : !w.perturbed && !spar_geometry(p).perturbed && isempty(w.intermediate_afs) ?
        aero_attachment(g, reg, aero_nloop, length(aero_etas), aero_uv, aero_xyz) :
        aero_attachment_refined(g, reg, aero_nloop, aero_etas, aero_xyz)

    node_ids = collect(1:length(reg.keys))
    model = Model(Dict{String,Any}(p), w, g, node_ids, reg.xyz, reg.keys,
                  n_struct, groups, rbe3, spc, aero_xyz, aero_quads, aero_nloop,
                  aero_map, aero_w,
                  Tuple{String,String}[], Tuple{String,String,Bool}[],le_metadata)

    oriented_ribs(g)&&validate_main_rib_mesh(model)

    p["leading_edge.enabled"] && validate_oriented_le_elements(model)

    progress("fuel_masses")
    add_fuel_references!(model)

    append!(model.info, model_info(model, n_str_bays, n_rib_bays))
    progress("fuel")
    append!(model.info, fuel_info(model))
    progress("weights")
    append!(model.info, weights_info(model))
    progress("checks")
    append!(model.checks, mesh_checks(model))
    return model
end

# ---------------------------------------------------------------------------
#  Aerodynamic surface mesh
# ---------------------------------------------------------------------------

"""
    aero_surface(w, etas, n_chord, fs, rs) -> (xyz, quads, n_loop, uv)

Quadrilateral mesh of the complete aerodynamic surface, wrapping around the
section from the trailing edge along the lower surface, round the leading edge
and back along the upper surface. The loop closes on itself, so the trailing
edge carries a single node line and the surface has no seam. The spanwise
stations include every structural row and continue to the full-wing tip if
the structural box ends earlier.

`uv` holds, for every aero node, its bilinear coordinates in the box of its own
section: `u` runs 0 at the front spar to 1 at the rear spar, `v` runs 0 on the
lower skin to 1 on the upper skin. They fall outside `[0, 1]` ahead of the
front spar and behind the rear spar, which is what lets the viewer carry the
skin over the leading and trailing edges when it draws a deformed shape.
"""
function aero_surface(w::Wing, etas::Vector{Float64}, n_chord::Int,
                      fs::Float64, rs::Float64)
    a = [0.5 * (1.0 - cos(pi * (m - 1) / (n_chord - 1))) for m in 1:n_chord]
    # side: -1 lower surface, +1 upper surface, 0 on the chord line (LE, TE)
    loop = Tuple{Float64,Int}[]
    push!(loop, (a[end], 0))                       # trailing edge
    for m in n_chord-1:-1:2
        push!(loop, (a[m], -1))                    # lower surface, aft to fwd
    end
    push!(loop, (a[1], 0))                         # leading edge
    for m in 2:n_chord-1
        push!(loop, (a[m], 1))                     # upper surface, fwd to aft
    end
    M = length(loop)

    xyz = Float64[]
    uv = Float64[]
    sizehint!(xyz, 3 * M * length(etas))
    sizehint!(uv, 2 * M * length(etas))
    for eta in etas
        # The box edges of this section, used as the frame for u and v.
        zl_f = zlo(w, eta, fs)
        zu_f = zup(w, eta, fs)
        zl_r = zlo(w, eta, rs)
        zu_r = zup(w, eta, rs)
        for (xc, side) in loop
            zc = side == 1 ? zup(w, eta, xc) :
                 side == -1 ? zlo(w, eta, xc) :
                 0.5 * (zup(w, eta, xc) + zlo(w, eta, xc))
            append!(xyz, section_point(w, eta, xc, zc))
            u = (xc - fs) / (rs - fs)
            zl = zl_f + u * (zl_r - zl_f)
            zu = zu_f + u * (zu_r - zu_f)
            h = zu - zl
            v = abs(h) < 1.0e-12 ? 0.5 : (zc - zl) / h
            push!(uv, u, v)
        end
    end

    quads = Int[]
    NS = length(etas)
    for j in 0:NS-2, m in 0:M-1
        m2 = (m + 1) % M
        push!(quads, j * M + m + 1, j * M + m2 + 1,
              (j + 1) * M + m2 + 1, (j + 1) * M + m + 1)
    end
    return xyz, quads, M, uv
end

"""
    aero_attachment(g, reg, n_loop, n_span, uv, xyz) -> (map, weights)

Tie every aero node to the four box corner grids of its own section, with
bilinear weights from `uv`. The viewer uses this to carry the aerodynamic
surface along with a deformed shape:

    d_aero = (1-u)(1-v) d_fl + u(1-v) d_rl + (1-u)v d_fu + u v d_ru

It is exact on the box corners and extrapolates smoothly over the leading and
trailing edges, which is what a rigid rib extension would do. It is a display
device, not a structural connection: the aero mesh is never part of the
stiffness. Beyond the box end, affine weights project the aerodynamic point
onto the final rib's x-z plane. Its remaining y offset is carried by the final
rib rotations in the viewer, as a rigid extension for display only.
"""
function aero_attachment(g::BoxGrid, reg::NodeRegistry, n_loop::Int,
                         n_span::Int, uv::Vector{Float64}, xyz::Vector{Float64})
    NI = ni(g)
    nmap = Vector{Int}(undef, 4 * n_loop * n_span)
    w = Vector{Float64}(undef, 4 * n_loop * n_span)
    for j in 0:n_span-1
        station = min(j, nj(g))
        corners = (reg.index[(0, station, 0)], reg.index[(NI, station, 0)],
                   reg.index[(0, station, g.nh)], reg.index[(NI, station, g.nh)])
        for m in 1:n_loop
            a = j * n_loop + m
            u = uv[2*a-1]
            v = uv[2*a]
            base = 4 * (a - 1)
            nmap[base+1] = corners[1]
            nmap[base+2] = corners[2]
            nmap[base+3] = corners[3]
            nmap[base+4] = corners[4]
            w[base+1] = (1 - u) * (1 - v)
            w[base+2] = u * (1 - v)
            w[base+3] = (1 - u) * v
            w[base+4] = u * v
            if j > nj(g)
                # Minimum-norm affine coordinates in the actual terminal
                # section, robust under taper, sweep, twist and dihedral.
                # Their sum is one and their x/z resultant is the aero point.
                cx = sum(reg.xyz[3n-2] for n in corners) / 4
                cz = sum(reg.xyz[3n] for n in corners) / 4
                dx = [reg.xyz[3n-2] - cx for n in corners]
                dz = [reg.xyz[3n] - cz for n in corners]
                aa, bb, cc = sum(abs2, dx), sum(dx .* dz), sum(abs2, dz)
                determinant = aa * cc - bb^2
                determinant > 0 || error("Final wing-box section cannot carry the aerodynamic overlay")
                px, pz = xyz[3a-2] - cx, xyz[3a] - cz
                alpha = (cc * px - bb * pz) / determinant
                beta = (aa * pz - bb * px) / determinant
                for k in 1:4
                    w[base+k] = 0.25 + alpha * dx[k] + beta * dz[k]
                end
            end
        end
    end
    return nmap, w
end

"""Map an independent aerodynamic loft onto adjacent structural cross-sections.

Each section's four corner weights reproduce the aerodynamic point's x/z
projection and sum to one. Linear interpolation between the two surrounding
rows additionally reproduces y. Thus any affine structural displacement field
is carried exactly and there are no jumps at extra aerodynamic edge rows.
Outboard points retain their full x/z projection at the terminal row and use
the existing rotation lever for their remaining spanwise offset. This is a
display attachment only; it never changes structural nodes or constraints.
"""
function aero_attachment_refined(g::BoxGrid, reg::NodeRegistry, n_loop::Int,
                                 aero_etas::Vector{Float64}, xyz::Vector{Float64})
    sections = map(0:nj(g)) do j
        corners = (reg.index[(0,j,0)], reg.index[(ni(g),j,0)],
                   reg.index[(0,j,g.nh)], reg.index[(ni(g),j,g.nh)])
        cx = sum(reg.xyz[3n-2] for n in corners) / 4
        cz = sum(reg.xyz[3n] for n in corners) / 4
        dx = ntuple(k -> reg.xyz[3corners[k]-2]-cx,4)
        dz = ntuple(k -> reg.xyz[3corners[k]]-cz,4)
        aa,bb,cc = sum(abs2,dx),sum(dx .* dz),sum(abs2,dz)
        determinant = aa*cc-bb^2
        determinant > 0 || error("Wing-box section cannot carry the independent aerodynamic overlay")
        (;corners,cx,cz,dx,dz,aa,bb,cc,determinant)
    end
    nmap = Vector{Int}(undef, 8n_loop*length(aero_etas))
    weights = Vector{Float64}(undef,length(nmap))
    for (j,eta) in enumerate(aero_etas)
        lo = clamp(searchsortedlast(g.etas,eta),1,length(g.etas)-1)
        hi = lo+1
        t = clamp((eta-g.etas[lo])/(g.etas[hi]-g.etas[lo]),0.0,1.0)
        for k in 1:n_loop
            a = (j-1)*n_loop+k
            for (half,station,share) in ((0,lo,1-t),(1,hi,t))
                s = sections[station]
                px,pz = xyz[3a-2]-s.cx,xyz[3a]-s.cz
                alpha=(s.cc*px-s.bb*pz)/s.determinant
                beta=(s.aa*pz-s.bb*px)/s.determinant
                for corner in 1:4
                    index=8(a-1)+4half+corner
                    nmap[index]=s.corners[corner]
                    weights[index]=share*(0.25+alpha*s.dx[corner]+beta*s.dz[corner])
                end
            end
        end
    end
    return nmap,weights
end

"""Unboxed aero-point span offset from its terminal-rib projection (model axes)."""
function aero_rotation_levers(m::Model)
    lever = zeros(length(m.aero_xyz))
    if oriented_ribs(m.grid)
        stride=length(m.aero_map)÷(length(m.aero_xyz)÷3)
        for a in 1:length(m.aero_xyz)÷3,axis in 1:3
            projected=sum(m.aero_weights[stride*(a-1)+k]*m.xyz[3m.aero_map[stride*(a-1)+k]-3+axis] for k in 1:stride)
            lever[3a-3+axis]=m.aero_xyz[3a-3+axis]-projected
        end
        return lever
    end
    end_y = m.grid.wing.root_ref_y + last(m.grid.etas) * m.grid.wing.semispan
    for a in 1:length(m.aero_xyz)÷3
        lever[3a-1] = max(m.aero_xyz[3a-1] - end_y, 0.0)
    end
    return lever
end

# ---------------------------------------------------------------------------
#  Reporting
# ---------------------------------------------------------------------------

fmt(x::Real, d::Int = 3) = string(round(Float64(x); digits = abs(x) >= 100 ? min(d, 2) : d))

function model_info(m::Model, n_str_bays::Int, n_rib_bays::Int)
    w = m.wing
    g = m.grid
    NJ = nj(g)
    rib_pitch = last(g.etas) * reference_length(w) / n_rib_bays
    p = m.params
    fs, rs = g.lower_xcs[1,1], g.lower_xcs[end,1]
    info = Tuple{String,String}[
        ("Full span", fmt(w.span) * " m"),
        ("Root reference x / y / z", join(fmt.((w.root_ref_x,w.root_ref_y,w.root_ref_z)), " / ") * " m"),
        ("Semi-span modelled", fmt(w.semispan) * " m"),
        ("Real planform area", fmt(w.area) * " m2 (full wing)"),
        ("Base trapezoid area", fmt(w.base_area) * " m2 (full wing)"),
        ("Real planform aspect ratio", fmt(w.aspect_ratio)),
        ("Planform perturbation stations", string(length(planform_breakpoints(w)) - 2) * " interior edge stations"),
        ("Structural geometry", "Skins and nose follow the refined aerodynamic loft; spar paths retain base-trapezoid references"),
        ("Spar perturbation stations", string(length(spar_breakpoints(p)) - 2) * " interior spar stations"),
        ("Airfoil stations", join(["ETA "*fmt(eta)*": "*af.name for (eta,af) in zip(w.airfoil_etas,airfoil_sections(w))],"; ")),
        ("Airfoil interpolation", w.airfoil_interpolation===:cosine ? "Smooth cosine blend between adjacent sections" : "Linear blend between adjacent sections"),
        ("Wing box End ETA", string(last(g.etas))),
        ("Structural box span", fmt(last(g.etas) * w.semispan) * " m"),
        ("Root chord", fmt(w.chord_root) * " m"),
        ("Tip chord", fmt(w.chord_tip) * " m"),
        ("Mean aerodynamic chord", fmt(w.mac) * " m"),
        ("Reference line length", fmt(reference_length(w)) * " m"),
        ("Ribs", string(length(g.ribs)) * " (" * string(n_rib_bays) * " bays)"),
        ("Actual rib pitch", isempty(get(p,"ribs.masters",Any[])) ? fmt(rib_pitch)*" m" : "Interval-specific, measured on the rear-spar reference path"),
        ("Master ribs", string(2+length(get(p,"ribs.masters",Any[]))) * " including fixed root and final line-of-flight closures"),
        ("Stringer bays", string(n_str_bays)),
        ("Stringers per skin at root", string(n_str_bays - 1)),
        ("Stringers per skin at final rib", string(count(i -> g.collapsed[i+1,end] == 0,
                                                   g.stringer_indices))),
        ("Stringer pitch (constant)", fmt(p["box.stringer_pitch"]) * " m"),
        ("Stringer runout distance / pitch", fmt(get(p,"mesh.stringer_runout_ratio",1.0))),
        ("Stringer runout clearance", fmt(p["box.stringer_pitch"]*get(p,"mesh.stringer_runout_ratio",1.0))*" m in projected x"),
        ("Shell elements per stringer bay", string(get(p, "mesh.elements_between_stringers", 1))),
        ("Stringer direction", isempty(get(p,"box.rear_spar_points",Any[])) ?
            fmt(p["box.stringer_angle"]) * " deg to the base rear spar (straight paths)" :
            "Piecewise rear-spar directions with endpoint angle offsets; continuous paths"),
        ("Runout connector area", string(STRINGER_RUNOUT_AREA) * " m2"),
        ("Box height at root", fmt(box_height(g.wing, 0.0, 0.5 * (fs + rs))) * " m"),
        ("Box height at final rib", fmt(box_height(g.wing, last(g.etas),
            0.5 * (g.lower_xcs[1,end] + g.lower_xcs[end,end]))) * " m"),
        ("Grid size i x j x k", string(ni(g)) * " x " * string(NJ) * " x " *
                                string(g.nh) * " elements"),
        ("Structural nodes", string(m.n_struct)),
        ("RBE3 reference nodes", string(length(m.rbe3))),
        ("Nodes total", string(length(m.node_ids))),
    ]
    component_counts=Dict{Tuple{String,Symbol},Int}()
    for gr in m.groups
        key=(component_base_group(gr.name),gr.kind)
        component_counts[key]=get(component_counts,key,0)+n_elements(gr)
    end
    for ((name,kind),count) in sort!(collect(component_counts);by=first)
        push!(info,(name,string(count)*(kind===:quad ? " CQUAD4" : kind===:tria ? " CTRIA3" : " CBAR")))
    end
    panelids=unique([stiffened_panel_id(gr.pid) for gr in m.groups if stiffened_panel_id(gr.pid)!==nothing])
    push!(info,("Stiffened panels",string(length(panelids))*" (separate inherited skin and T-stringer properties)"))
    unassigned=sum((n_elements(gr) for gr in m.groups if gr.pid in (PID_SKIN_UPPER,PID_SKIN_LOWER));init=0)
    push!(info,("Skin elements without a normal stringer",string(unassigned)*" (original skin property retained)"))
    if p["leading_edge.enabled"]
        layout=leading_edge_layout(p,length(g.ribs))
        orientation=get(p,"leading_edge.rib_orientation","flight_direction")=="flight_direction" ?
            "Line of flight" : "$(p["leading_edge.rib_angle"]) deg to common inboard front-spar segment"
        push!(info,("Leading-edge rib orientation",orientation))
        push!(info,("Leading-edge physical ribs","$(layout.first_rib) to $(layout.last_rib)"))
        push!(info,("Leading-edge active bays",isempty(layout.active_bays) ? "None (all selected bays disabled)" : join(layout.active_bays,", ")))
        push!(info,("Leading-edge closing/support ribs",isempty(layout.active_ribs) ? "None" : join(layout.active_ribs,", ")))
    end
    push!(info, ("RBE3 elements", string(length(m.rbe3))))
    push!(info, ("Supported nodes", string(length(m.spc)) * " (" * get(p,"supports.mode","root") * " support definition)"))
    push!(info, ("Support constraints", support_description(m)))
    push!(info, ("Aero loft quads", string(length(m.aero_quads) ÷ 4)))
    return info
end

"""
    mesh_checks(m) -> Vector{(name, detail, pass)}

Verify that the generated mesh really is congruent. The checks are exact, not
statistical: they look for duplicated grid points, count how many shells use
each edge, confirm that the torsion box is closed, and confirm that every bar
lies exactly on a shell element edge rather than cutting across one.
"""
function mesh_checks(m::Model)
    out = Tuple{String,String,Bool}[]

    # 1. No two distinct index triples may land on the same point.
    scale = max(m.grid.wing.mac, 1.0e-3)
    tol = 1.0e-9 * scale
    seen = Dict{NTuple{3,Int},Int}()
    dup = 0
    for n in 1:m.n_struct
        key = (round(Int, m.xyz[3n-2] / tol),
               round(Int, m.xyz[3n-1] / tol),
               round(Int, m.xyz[3n] / tol))
        haskey(seen, key) ? (dup += 1) : (seen[key] = n)
    end
    push!(out, ("Duplicated grid points", string(dup), dup == 0))

    # 2. Edge use histogram over all shells. An edge shared by three shells
    #    is normal where a rib meets the skins or the spar webs.
    edges = Dict{Tuple{Int,Int},Int}()
    degenerate = 0
    for gr in m.groups
        gr.kind in (:quad, :tria) || continue
        nn = gr.kind === :quad ? 4 : 3
        for el in 1:n_elements(gr)
            nodes = view(gr.conn, nn*(el-1)+1:nn*el)
            point(n) = (m.xyz[3n-2], m.xyz[3n-1], m.xyz[3n])
            a, b, c = point.(nodes[1:3])
            area = norm3(cross3(b .- a, c .- a))
            if nn == 4
                area += norm3(cross3(c .- a, point(nodes[4]) .- a))
            end
            (length(unique(nodes)) == nn && area > tol^2) || (degenerate += 1)
            for t in 1:nn
                a = nodes[t]
                b = nodes[t%nn+1]
                key = a < b ? (a, b) : (b, a)
                edges[key] = get(edges, key, 0) + 1
            end
        end
    end
    hist = Dict{Int,Int}()
    for v in values(edges)
        hist[v] = get(hist, v, 0) + 1
    end
    free = get(hist, 1, 0)
    push!(out, ("Degenerate shells", string(degenerate), degenerate == 0))
    push!(out, ("Free shell edges (closed box)", string(free), free == 0))
    push!(out, ("Edge use 2 / 3 / 4+",
                string(get(hist, 2, 0)) * " / " * string(get(hist, 3, 0)) * " / " *
                string(sum((c for (u, c) in hist if u >= 4); init = 0)), true))

    # 3. Every bar must coincide with a shell edge, which is what makes the
    #    stringers and spar caps congruent with the skins.
    off = 0
    zerolen = 0
    for gr in m.groups
        gr.kind === :bar || continue
        for el in 1:n_elements(gr)
            a = gr.conn[2*el-1]
            b = gr.conn[2*el]
            key = a < b ? (a, b) : (b, a)
            haskey(edges, key) || (off += 1)
            pa = (m.xyz[3a-2], m.xyz[3a-1], m.xyz[3a])
            pb = (m.xyz[3b-2], m.xyz[3b-1], m.xyz[3b])
            norm3(pb .- pa) > 1.0e-9 * scale || (zerolen += 1)
        end
    end
    push!(out, ("Bars not on a shell edge", string(off), off == 0))
    push!(out, ("Zero length bars", string(zerolen), zerolen == 0))

    # 4. Referential integrity of the connectivity, the RBE3 sets and the SPC.
    nn = length(m.node_ids)
    bad = 0
    for gr in m.groups, v in gr.conn
        (1 <= v <= nn) || (bad += 1)
    end
    for sp in m.rbe3
        (1 <= sp.ref <= nn) || (bad += 1)
        for d in sp.dep
            (1 <= d <= nn) || (bad += 1)
        end
        # A reference node must never appear among its own dependent grids.
        sp.ref in sp.dep && (bad += 1)
    end
    for s in m.spc
        (1 <= s <= m.n_struct) || (bad += 1)
    end
    push!(out, ("Dangling node references", string(bad), bad == 0))

    return out
end

"""
    all_checks_pass(m)

True when every congruency check on the model passed.
"""
all_checks_pass(m::Model) = all(c -> c[3], m.checks)
