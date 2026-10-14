# ===========================================================================
#  airfoil.jl - NACA 4-digit and 5-digit section geometry
#
#  Sections are generated in unit-chord coordinates with x/c measured aft from
#  the leading edge and z/c positive up. The thickness is applied normal to
#  the camber line (the exact NACA construction), so the surface x/c values
#  are not the same as the generating parameter; the tables are therefore
#  resampled through `z_upper` / `z_lower`, which interpolate the surface at a
#  requested x/c. That is what lets the spars and stringers sit at exact
#  chord fractions.
# ===========================================================================

"""
    Airfoil

Unit-chord airfoil surface tables. `xu`/`zu` describe the upper surface and
`xl`/`zl` the lower surface, both with x/c increasing monotonically from the
leading edge (0) to the trailing edge (1).
"""
struct Airfoil
    name::String
    thickness::Float64
    xu::Vector{Float64}
    zu::Vector{Float64}
    xl::Vector{Float64}
    zl::Vector{Float64}
    source::Symbol
end

Airfoil(name, thickness, xu, zu, xl, zl) = Airfoil(name, thickness, xu, zu, xl, zl, :coordinates)

# --- designation parsing ---------------------------------------------------

"""
    naca_digits(name) -> String

Extract the digit string from a NACA designation, accepting forms such as
`"NACA 2412"`, `"naca-2412"` and `"23012"`.
"""
function naca_digits(name::AbstractString)
    s = uppercase(strip(String(name)))
    s = replace(s, "NACA" => "")
    s = replace(s, r"[\s\-_]" => "")
    isempty(s) && throw(ArgumentError("empty NACA designation"))
    all(isdigit, s) || throw(ArgumentError(
        "unsupported airfoil designation '$name': expected a NACA 4- or 5-digit code"))
    length(s) in (4, 5) || throw(ArgumentError(
        "unsupported airfoil designation '$name': expected 4 or 5 digits, got $(length(s))"))
    return s
end

# --- thickness distribution ------------------------------------------------

"""
    naca_thickness(t, x; closed_te = true) -> Float64

Half-thickness of the standard NACA thickness law at chord fraction `x` for a
maximum thickness ratio `t`. The closed form uses the -0.1036 fourth-order
coefficient so that the surfaces meet at the trailing edge.
"""
function naca_thickness(t::Float64, x::Float64; closed_te::Bool = true)
    a4 = closed_te ? -0.1036 : -0.1015
    xc = clamp(x, 0.0, 1.0)
    return 5.0 * t * (0.2969 * sqrt(xc) - 0.1260 * xc - 0.3516 * xc^2 +
                      0.2843 * xc^3 + a4 * xc^4)
end

# --- camber lines ----------------------------------------------------------

# Standard 5-digit camber parameters: position of maximum camber p, the
# transition abscissa r and the scale k1 (tabulated for a design lift
# coefficient of 0.3).
const FIVE_DIGIT_TABLE = [
    0.05 0.0580 361.400
    0.10 0.1260 51.640
    0.15 0.2025 15.957
    0.20 0.2900 6.643
    0.25 0.3910 3.230
]

function five_digit_rk(p::Float64)
    pt = @view FIVE_DIGIT_TABLE[:, 1]
    if p <= pt[1]
        return FIVE_DIGIT_TABLE[1, 2], FIVE_DIGIT_TABLE[1, 3]
    elseif p >= pt[end]
        return FIVE_DIGIT_TABLE[end, 2], FIVE_DIGIT_TABLE[end, 3]
    end
    i = findlast(<=(p), pt)
    w = (p - pt[i]) / (pt[i+1] - pt[i])
    r = FIVE_DIGIT_TABLE[i, 2] + w * (FIVE_DIGIT_TABLE[i+1, 2] - FIVE_DIGIT_TABLE[i, 2])
    k1 = FIVE_DIGIT_TABLE[i, 3] + w * (FIVE_DIGIT_TABLE[i+1, 3] - FIVE_DIGIT_TABLE[i, 3])
    return r, k1
end

"""
    camber_line(digits, x) -> (zc, dzc_dx)

Camber ordinate and slope at chord fraction `x` for a 4- or 5-digit NACA
designation.
"""
function camber_line(digits::String, x::Float64)
    xc = clamp(x, 0.0, 1.0)
    if length(digits) == 4
        m = parse(Int, digits[1:1]) / 100.0
        p = parse(Int, digits[2:2]) / 10.0
        (m == 0.0 || p == 0.0) && return (0.0, 0.0)
        if xc < p
            zc = m / p^2 * (2p * xc - xc^2)
            dz = 2m / p^2 * (p - xc)
        else
            zc = m / (1 - p)^2 * ((1 - 2p) + 2p * xc - xc^2)
            dz = 2m / (1 - p)^2 * (p - xc)
        end
        return (zc, dz)
    else
        cl = parse(Int, digits[1:1]) * 0.15      # design lift coefficient
        p = parse(Int, digits[2:2]) / 20.0       # position of maximum camber
        reflex = parse(Int, digits[3:3])
        cl == 0.0 && return (0.0, 0.0)
        r, k1 = five_digit_rk(p)
        scale = cl / 0.3
        if xc <= r
            zc = k1 / 6.0 * (xc^3 - 3r * xc^2 + r^2 * (3 - r) * xc)
            dz = k1 / 6.0 * (3xc^2 - 6r * xc + r^2 * (3 - r))
        else
            zc = k1 * r^3 / 6.0 * (1 - xc)
            dz = -k1 * r^3 / 6.0
        end
        if reflex != 0
            # The reflexed (third digit = 1) family needs its own k2/k1 table.
            # Fall back to the standard mean line and say so.
            @warn "reflexed 5-digit camber is not implemented; using the standard mean line" digits
        end
        return (scale * zc, scale * dz)
    end
end

# --- section construction --------------------------------------------------

"""
    make_monotone!(x) -> x

Force a surface abscissa table to increase strictly. The exact NACA
construction can fold back very slightly over the first few points of a
thick, highly cambered section; nudging those points keeps the interpolation
tables well posed. The correction is at the leading edge only and is far
smaller than any mesh dimension.
"""
function make_monotone!(x::Vector{Float64})
    eps = 1.0e-9
    for i in 2:length(x)
        if x[i] <= x[i-1] + eps
            x[i] = x[i-1] + eps
        end
    end
    return x
end

"""
    naca_airfoil(name; n = 121, closed_te = true) -> Airfoil

Build the upper and lower surface tables of a NACA 4- or 5-digit section
using `n` cosine-spaced generating stations per surface.
"""
function naca_airfoil(name::AbstractString; n::Int = 121, closed_te::Bool = true)
    digits = naca_digits(name)
    t = parse(Int, digits[end-1:end]) / 100.0
    t > 0.0 || throw(ArgumentError("airfoil '$name' has zero thickness"))

    xu = Vector{Float64}(undef, n)
    zu = Vector{Float64}(undef, n)
    xl = Vector{Float64}(undef, n)
    zl = Vector{Float64}(undef, n)

    for i in 1:n
        # Cosine spacing clusters points at the leading and trailing edges.
        xg = 0.5 * (1.0 - cos(pi * (i - 1) / (n - 1)))
        zc, dz = camber_line(digits, xg)
        yt = naca_thickness(t, xg; closed_te = closed_te)
        th = atan(dz)
        xu[i] = xg - yt * sin(th)
        zu[i] = zc + yt * cos(th)
        xl[i] = xg + yt * sin(th)
        zl[i] = zc - yt * cos(th)
    end

    # Pin the leading and trailing edges exactly on the tables.
    xu[1] = 0.0; xl[1] = 0.0
    xu[end] = 1.0; xl[end] = 1.0
    make_monotone!(xu)
    make_monotone!(xl)
    xu[end] = max(xu[end], 1.0)
    xl[end] = max(xl[end], 1.0)

    return Airfoil(String(name), t, xu, zu, xl, zl, :naca)
end

"""
    table_interp(xt, zt, x) -> Float64

Linear interpolation in a strictly increasing table, clamped at both ends.
"""
function table_interp(xt::Vector{Float64}, zt::Vector{Float64}, x::Float64)
    x <= xt[1] && return zt[1]
    x >= xt[end] && return zt[end]
    lo = 1
    hi = length(xt)
    while hi - lo > 1
        mid = (lo + hi) >> 1
        if xt[mid] <= x
            lo = mid
        else
            hi = mid
        end
    end
    w = (x - xt[lo]) / (xt[hi] - xt[lo])
    return zt[lo] + w * (zt[hi] - zt[lo])
end

"""
    z_upper(af, xc)

Upper surface z/c of the section at chord fraction `xc`.
"""
z_upper(af::Airfoil, xc::Float64) = table_interp(af.xu, af.zu, xc)

"""
    z_lower(af, xc)

Lower surface z/c of the section at chord fraction `xc`.
"""
z_lower(af::Airfoil, xc::Float64) = table_interp(af.xl, af.zl, xc)

mean_camber(af::Airfoil, xc::Float64) = af.source === :naca ?
    first(camber_line(naca_digits(af.name), xc)) : (z_upper(af, xc) + z_lower(af, xc)) / 2

"""Validate embedded UIUC coordinates; loading/building never needs the network."""
function airfoil_from_profile(profile::AbstractDict)
    get(profile, "version", 0) == 1 || throw(ArgumentError("unsupported embedded airfoil profile version"))
    id=get(profile,"id",nothing);hash=get(profile,"raw_sha256",nothing)
    id isa AbstractString && valid_uiuc_id(id) && get(profile,"source_url","")==UIUC_AIRFOIL_URL*id &&
        hash isa AbstractString && occursin(r"^[0-9a-f]{64}$",hash) && get(profile,"fetched_at",nothing) isa AbstractString ||
        throw(ArgumentError("embedded UIUC profile has missing or invalid source provenance; select the profile again"))
    tables = map(("xu", "zu", "xl", "zl")) do key
        values = get(profile, key, nothing)
        values isa AbstractVector && 3 <= length(values) <= 20000 || throw(ArgumentError("embedded airfoil $key needs 3 to 20000 coordinates"))
        all(v -> v isa Real && isfinite(v), values) || throw(ArgumentError("embedded airfoil $key contains invalid coordinates"))
        Float64.(values)
    end
    xu, zu, xl, zl = tables
    length(xu) == length(zu) && length(xl) == length(zl) || throw(ArgumentError("embedded airfoil coordinate lengths do not match"))
    for x in (xu, xl)
        all(diff(x) .> 0) && abs(first(x)) < 1e-10 && abs(last(x)-1) < 1e-10 ||
            throw(ArgumentError("embedded airfoil surfaces must increase strictly from x/c=0 to 1"))
    end
    abs(first(zu)-first(zl)) < 1e-10 || throw(ArgumentError("embedded airfoil has an open leading edge"))
    stations = sort!(unique(vcat(xu, xl)))
    gaps = [table_interp(xu,zu,x)-table_interp(xl,zl,x) for x in stations]
    minimum(gaps) >= -1e-8 && maximum(gaps) > 1e-8 || throw(ArgumentError("airfoil surfaces cross or have zero thickness"))
    return Airfoil(String(get(profile,"name",get(profile,"id","UIUC profile"))), maximum(gaps), xu,zu,xl,zl,:uiuc)
end

function embedded_airfoil(p, station)
    key = "airfoil.$(station)_profile"
    text = get(p,key,"")
    text isa AbstractString && !isempty(strip(text)) || throw(ArgumentError("Choose and load a UIUC $station profile in Airfoils before creating the model."))
    sizeof(text) <= 2_000_000 || throw(ArgumentError("embedded $station airfoil exceeds 2 MB"))
    profile = try JSON.parse(text) catch; throw(ArgumentError("embedded $station airfoil is not valid JSON")); end
    profile isa AbstractDict || throw(ArgumentError("embedded $station airfoil must be an object"))
    return airfoil_from_profile(profile)
end

function validate_airfoil_selection(p, station)
    source = get(p,"airfoil.$(station)_source","naca")
    source in ("naca","uiuc") || throw(ArgumentError("airfoil.$(station)_source must be naca or uiuc"))
    source == "naca" ? naca_digits(p["airfoil.$station"]) : embedded_airfoil(p,station)
    return nothing
end

function airfoil_from_params(p, station::AbstractString)
    validate_airfoil_selection(p,station)
    return get(p,"airfoil.$(station)_source","naca") == "uiuc" ? embedded_airfoil(p,station) :
        naca_airfoil(p["airfoil.$station"]; n=p["airfoil.n_points"],closed_te=p["airfoil.closed_trailing_edge"])
end

"""Validate portable intermediate sections without accessing the network."""
function normalize_airfoil_stations(value)
    value isa AbstractVector || throw(ArgumentError("airfoil.stations must be an array of section tables"))
    length(value)<=100 || throw(ArgumentError("airfoil.stations supports at most 100 intermediate sections"))
    out=Dict{String,Any}[];seen=Set{Float64}()
    for (index,raw) in enumerate(value)
        prefix="airfoil.stations row $index"
        raw isa AbstractDict || throw(ArgumentError("$prefix must be a table"))
        all(k->k isa AbstractString||k isa Symbol,keys(raw)) || throw(ArgumentError("$prefix has invalid field names"))
        row=Dict{String,Any}(String(k)=>v for (k,v) in raw)
        all(k->k in ("eta","source","code","profile"),keys(row)) ||
            throw(ArgumentError("$prefix has unsupported fields"))
        eta=get(row,"eta",nothing)
        eta isa Real && !(eta isa Bool) && isfinite(eta) && 0<eta<1 ||
            throw(ArgumentError("$prefix ETA must be a finite number strictly between 0 and 1; root and tip are defined separately"))
        eta=Float64(eta)
        any(abs(eta-other)<1e-8 for other in seen) &&
            throw(ArgumentError("$prefix duplicates another section ETA; separate sections by at least 1e-8"))
        push!(seen,eta)
        source=get(row,"source","naca");code=get(row,"code",nothing)
        source in ("naca","uiuc") || throw(ArgumentError("$prefix source must be naca or uiuc"))
        code isa AbstractString && !isempty(strip(code)) || throw(ArgumentError("$prefix needs an airfoil code"))
        result=Dict{String,Any}("eta"=>eta,"source"=>String(source),"code"=>strip(String(code)))
        if source=="naca"
            digits=naca_digits(code)
            parse(Int,digits[end-1:end])>0 || throw(ArgumentError("$prefix has zero thickness"))
        else
            profile=get(row,"profile",nothing)
            profile isa AbstractDict || throw(ArgumentError("$prefix needs a loaded UIUC profile; select it in Airfoils"))
            sizeof(JSON.json(profile))<=2_000_000 || throw(ArgumentError("$prefix embedded profile exceeds 2 MB"))
            airfoil_from_profile(profile)
            String(profile["id"])==result["code"] || throw(ArgumentError("$prefix code does not match its embedded UIUC profile"))
            result["profile"]=deepcopy(profile)
        end
        push!(out,result)
    end
    sort!(out;by=row->row["eta"])
    return out
end

function intermediate_airfoil(p,row)
    return row["source"]=="uiuc" ? airfoil_from_profile(row["profile"]) :
        naca_airfoil(row["code"];n=p["airfoil.n_points"],closed_te=p["airfoil.closed_trailing_edge"])
end
