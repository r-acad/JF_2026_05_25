# experimental/nastran_rect_kg_synth.jl
#
# Opt-in SOL105 CQUAD4 rectangular differential-stiffness synthesis.
#
# The coefficient law below was reconstructed from private Nastran MATPRN KDJJ
# nx/ny/shear triplets for flat one-element CQUAD4 PCOMP rectangles.  It is a
# geometry law in q = Lx/Ly:
#
#     B(q) = q * Bq + (1/q) * Biq + B0
#
# and is intentionally kept behind JFEM_SOL105_KG_RECT_SYNTH while it is being
# validated on larger meshes.  It does not depend on case names, PIDs/EIDs,
# groups, or internal stress-state selectors.

const _NAS_RECT_ASPECT_KNOTS =
    (1.25, 1.875, 3.0, 6.0, 8.0, 12.0)
const _NAS_RECT_ASPECT_K_PLATE_BLEND =
    (0.0, 0.10, 1.0, 0.0, 0.0, 0.0)
const _NAS_RECT_ASPECT_KG_NXX_SCALE =
    (1.04, 1.00, 1.04, 1.04, 1.00, 1.02)
const _NAS_RECT_ASPECT_KG_NYY_SCALE =
    (1.04, 1.00, 1.00, 1.02, 0.98, 1.00)
const _NAS_RECT_ASPECT_KG_NXY_SCALE =
    (1.02, 1.02, 1.02, 0.97, 1.00, 1.08)

@inline function _rect_synth_env_bool(key::AbstractString, default::Bool=false)
    raw = lowercase(strip(get(ENV, key, default ? "true" : "false")))
    return raw in ("1", "true", "yes", "on")
end

@inline function _rect_synth_env_scale(key::AbstractString, default::Float64)
    raw = get(ENV, key, nothing)
    raw === nothing && return default
    try
        return clamp(parse(Float64, raw), 0.0, Inf)
    catch
        return default
    end
end

function _rect_synth_log_interp(q::Float64, values)
    qeff = max(q, 1.0)
    knots = _NAS_RECT_ASPECT_KNOTS
    qeff <= knots[1] && return values[1]
    qeff >= knots[end] && return values[end]
    lq = log(qeff)
    @inbounds for i in 1:(length(knots) - 1)
        if qeff <= knots[i + 1]
            t = (lq - log(knots[i])) / (log(knots[i + 1]) - log(knots[i]))
            return (1.0 - t) * values[i] + t * values[i + 1]
        end
    end
    return values[end]
end

function nastran_rect_synth_k_plate_blend(q::Float64)
    qeff = max(abs(q), inv(max(abs(q), 1.0e-30)))
    return clamp(_rect_synth_log_interp(qeff, _NAS_RECT_ASPECT_K_PLATE_BLEND), 0.0, 1.0)
end

function nastran_rect_synth_kg_scales(q::Float64)
    qabs = max(abs(q), 1.0e-30)
    qeff = max(qabs, inv(qabs))
    nxx = _rect_synth_log_interp(qeff, _NAS_RECT_ASPECT_KG_NXX_SCALE)
    nyy = _rect_synth_log_interp(qeff, _NAS_RECT_ASPECT_KG_NYY_SCALE)
    nxy = _rect_synth_log_interp(qeff, _NAS_RECT_ASPECT_KG_NXY_SCALE)
    return qabs >= 1.0 ? (nxx, nyy, nxy) : (nyy, nxx, nxy)
end

const _NAS_RECT_SYNTH_COEFFS = Dict{Symbol,Vector{NTuple{5,Float64}}}(
    :nxx => NTuple{5,Float64}[
        (1, 1, 3.3751582932165160e-02, -4.0349451490490611e-03, -1.6452072396266535e-03),
        (1, 4, 6.5523248779597843e-06, -2.5388042094509067e-03, -9.3549383016081899e-05),
        (1, 7, -3.3751582932165174e-02, 4.0349451490489579e-03, 1.6452072396267413e-03),
        (1, 10, -6.5523248779497419e-06, 2.5388042094509960e-03, 9.3549383016008932e-05),
        (2, 2, -6.5531648141426698e-05, 3.2924189645512419e-01, 1.2575137144946182e-03),
        (2, 5, 6.5531648141408890e-05, -3.2924189645512442e-01, -1.2575137144944612e-03),
        (2, 8, -2.4208425392183914e-05, 1.6636213509767880e-01, 5.1079693569549883e-04),
        (2, 11, 2.4208425392195399e-05, -1.6636213509767869e-01, -5.1079693569557722e-04),
        (3, 3, 3.3688413716806732e-02, 3.2522849851845836e-01, -4.0272961558037129e-04),
        (3, 6, 7.0889854216038960e-05, -3.3181305313344550e-01, -1.3358080028472617e-03),
        (3, 9, -3.3772877693116855e-02, 1.7044044132287683e-01, 2.1201731375898223e-03),
        (3, 12, 1.7802262875237586e-05, -1.6382176948008120e-01, -4.1811924309717238e-04),
        (4, 4, -3.3726192792751145e-02, -6.1150117946060546e-03, 1.2662469772097920e-03),
        (4, 7, -6.5523248779698454e-06, 2.5388042094508130e-03, 9.3549383016155787e-05),
        (4, 10, 3.3726192792751165e-02, 6.1150117946063348e-03, -1.2662469772100225e-03),
        (5, 5, -6.5531648141399119e-05, 3.2924189645512447e-01, 1.2575137144943827e-03),
        (5, 8, 2.4208425392172560e-05, -1.6636213509767891e-01, -5.1079693569540071e-04),
        (5, 11, -2.4208425392183914e-05, 1.6636213509767880e-01, 5.1079693569549883e-04),
        (6, 6, -3.3789556946333642e-02, 3.2316770610766843e-01, 2.5026080358891254e-03),
        (6, 9, 1.7802262875198941e-05, -1.6382176948008170e-01, -4.1811924309685845e-04),
        (6, 12, 3.3702031433374330e-02, 1.7247809494303823e-01, -7.5787748955583121e-04),
        (7, 7, 3.3751582932165194e-02, -4.0349451490488061e-03, -1.6452072396268727e-03),
        (7, 10, 6.5523248779597843e-06, -2.5388042094509067e-03, -9.3549383016081899e-05),
        (8, 8, -3.2494845882979232e-05, 3.3617636637679466e-01, 7.9980145922040654e-04),
        (8, 11, 3.2494845882997047e-05, -3.3617636637679454e-01, -7.9980145922056353e-04),
        (9, 9, 3.3720325208583299e-02, 3.3215209253220929e-01, -8.5132692602621438e-04),
        (9, 12, 3.7811758307560639e-05, -3.3874762558437604e-01, -8.7801399279063190e-04),
        (10, 10, -3.3726192792751158e-02, -6.1150117946062845e-03, 1.2662469772099819e-03),
        (11, 11, -3.2494845883007117e-05, 3.3617636637679449e-01, 7.9980145922060278e-04),
        (12, 12, -3.3757645454557145e-02, 3.3009130012141885e-01, 2.0540107254437530e-03),
    ],
    :nyy => NTuple{5,Float64}[
        (1, 1, 3.2154371659235259e-01, -1.5032045535465520e-02, 2.2667609742457406e-02),
        (1, 4, 1.6665919935072943e-01, 1.2118137584182761e-04, 1.3936028522883528e-04),
        (1, 7, -3.2154371659235259e-01, 1.5032045535465520e-02, -2.2667609742457406e-02),
        (1, 10, -1.6665919935072943e-01, -1.2118137584182761e-04, -1.3936028522883528e-04),
        (2, 2, 7.4030777054021394e-04, 5.3253585849683760e-02, -1.5620644143657181e-02),
        (2, 5, -7.4030777054021014e-04, -5.3253585849683718e-02, 1.5620644143657152e-02),
        (2, 8, 3.7247049164885213e-04, 5.3603365571520045e-03, -7.8648763733685737e-03),
        (2, 11, -3.7247049164885603e-04, -5.3603365571520574e-03, 7.8648763733686067e-03),
        (3, 3, 3.2226997979042948e-01, 3.8108538588256649e-02, 7.1268439347046695e-03),
        (3, 6, 1.6591822141178536e-01, -5.3139542853776520e-02, 1.5766693534704307e-02),
        (3, 9, -3.2117515367378718e-01, 2.0330143442124190e-02, -3.0465803684229957e-02),
        (3, 12, -1.6703150933855229e-01, -5.4723456364110315e-03, 7.7184158426582498e-03),
        (4, 4, 3.4510936013679472e-01, 1.5515178487595120e-02, -2.2109267688150393e-02),
        (4, 7, -1.6665919935072943e-01, -1.2118137584182761e-04, -1.3936028522883528e-04),
        (4, 10, -3.4510936013679472e-01, -1.5515178487595120e-02, 2.2109267688150393e-02),
        (5, 5, 7.4030777054020754e-04, 5.3253585849683677e-02, -1.5620644143657133e-02),
        (5, 8, -3.7247049164884779e-04, -5.3603365571519559e-03, 7.8648763733685390e-03),
        (5, 11, 3.7247049164885213e-04, 5.3603365571520045e-03, -7.8648763733685737e-03),
        (6, 6, 3.4583568888979882e-01, 6.8652341693239444e-02, -3.7648662167573552e-02),
        (6, 9, -1.6703150933855229e-01, -5.4723456364109205e-03, 7.7184158426582003e-03),
        (6, 12, -3.4473997911541221e-01, -1.0205117780495938e-02, 1.4301777040734728e-02),
        (7, 7, 3.2154371659235259e-01, -1.5032045535465520e-02, 2.2667609742457406e-02),
        (7, 10, 1.6665919935072943e-01, 1.2118137584182761e-04, 1.3936028522883528e-04),
        (8, 8, 7.4972244629428590e-04, -3.1809353876726516e-02, -1.5840243546270085e-02),
        (8, 11, -7.4972244629428980e-04, 3.1809353876726482e-02, 1.5840243546270116e-02),
        (9, 9, 3.2229635339470475e-01, -4.6791040748392063e-02, 6.7701773929564873e-03),
        (9, 12, 1.6590942595989008e-01, 3.1924701060313782e-02, 1.5985135825930669e-02),
        (10, 10, 3.4510936013679472e-01, 1.5515178487595120e-02, -2.2109267688150393e-02),
        (11, 11, 7.4972244629429360e-04, -3.1809353876726447e-02, -1.5840243546270144e-02),
        (12, 12, 3.4586206249407453e-01, -1.6247237643406506e-02, -3.8005328709323973e-02),
    ],
    :nxy => NTuple{5,Float64}[
        (1, 1, 2.4718955117440640e-07, -4.3280746959339975e-05, 2.5006269812861809e-01),
        (1, 2, -1.6669647593438958e-01, -1.6655796121690250e-01, -7.1172632393286868e-05),
        (1, 5, -8.3357153859776947e-02, 1.6666598898987106e-01, 3.3511647528033415e-05),
        (1, 8, 1.6671064799503935e-01, -8.3345094026549382e-02, -3.0994785540955893e-05),
        (1, 10, -2.4718955164434764e-07, 4.3280746956109256e-05, -2.5006269812861509e-01),
        (1, 11, 8.3354430654246942e-02, 8.3344847119407456e-02, -1.2648357365676231e-05),
        (2, 2, 7.4156865585219268e-07, -1.2984224086180337e-04, 7.5018809438583933e-01),
        (2, 4, -8.3357153859776947e-02, 1.6666598898987106e-01, 3.3511647528033415e-05),
        (2, 5, -4.9437910386921090e-07, 8.6561493908080897e-05, -5.0012539625722641e-01),
        (2, 7, 1.6671064799503935e-01, -8.3345094026549382e-02, -3.0994785540955893e-05),
        (2, 10, 8.3354430654246942e-02, 8.3344847119407456e-02, -1.2648357365676231e-05),
        (2, 11, -2.4718955193460545e-07, 4.3280746954040449e-05, -2.5006269812861320e-01),
        (3, 3, 9.8875820693675743e-07, -1.7312298782191555e-04, 1.0002507925144579e+00),
        (3, 6, -4.9437910417329054e-07, 8.6561493906045416e-05, -5.0012539625722441e-01),
        (3, 12, -4.9437910359277492e-07, 8.6561493910271176e-05, -5.0012539625722818e-01),
        (4, 4, -2.4718955241145758e-07, 4.3280746950215763e-05, -2.5006269812860993e-01),
        (4, 5, -1.6669647593438958e-01, -1.6655796121690250e-01, -7.1172632393286868e-05),
        (4, 7, 2.4718955222486326e-07, -4.3280746951841226e-05, 2.5006269812861132e-01),
        (4, 8, 8.3354430654246942e-02, 8.3344847119407456e-02, -1.2648357365676231e-05),
        (4, 11, 1.6671064799503935e-01, -8.3345094026549382e-02, -3.0994785540955893e-05),
        (5, 5, 2.4718955194151634e-07, -4.3280746954051575e-05, 2.5006269812861320e-01),
        (5, 7, 8.3354430654246942e-02, 8.3344847119407456e-02, -1.2648357365676231e-05),
        (5, 8, 2.4718955194842723e-07, -4.3280746953868670e-05, 2.5006269812861309e-01),
        (5, 10, 1.6671064799503935e-01, -8.3345094026549382e-02, -3.0994785540955893e-05),
        (6, 9, 4.9437910421475588e-07, -8.6561493905759770e-05, 5.0012539625722419e-01),
        (7, 7, -2.4718955272935900e-07, 4.3280746948293154e-05, -2.5006269812860810e-01),
        (7, 8, -1.6669647593438958e-01, -1.6655796121690250e-01, -7.1172632393286868e-05),
        (7, 11, -8.3357153859776947e-02, 1.6666598898987106e-01, 3.3511647528033415e-05),
        (8, 8, -7.4156865582454902e-07, 1.2984224086187420e-04, -7.5018809438583955e-01),
        (8, 10, -8.3357153859776947e-02, 1.6666598898987106e-01, 3.3511647528033415e-05),
        (8, 11, 4.9437910389685446e-07, -8.6561493907737341e-05, 5.0012539625722618e-01),
        (9, 9, -9.8875820854008619e-07, 1.7312298780990836e-04, -1.0002507925144475e+00),
        (9, 12, 4.9437910357895304e-07, -8.6561493910184033e-05, 5.0012539625722829e-01),
        (10, 10, 2.4718955147848604e-07, -4.3280746957458206e-05, 2.5006269812861631e-01),
        (10, 11, -1.6669647593438958e-01, -1.6655796121690250e-01, -7.1172632393286868e-05),
        (11, 11, -2.4718955196915995e-07, 4.3280746953783540e-05, -2.5006269812861304e-01),
    ],
)

@inline function _rect_synth_edge_lengths(coords::AbstractMatrix)
    l12 = hypot(coords[2, 1] - coords[1, 1], coords[2, 2] - coords[1, 2])
    l43 = hypot(coords[3, 1] - coords[4, 1], coords[3, 2] - coords[4, 2])
    l23 = hypot(coords[3, 1] - coords[2, 1], coords[3, 2] - coords[2, 2])
    l14 = hypot(coords[4, 1] - coords[1, 1], coords[4, 2] - coords[1, 2])
    return 0.5 * (l12 + l43), 0.5 * (l23 + l14)
end

function _add_rect_synth_component!(K12::AbstractMatrix, coeffs, scale::Float64, q::Float64)
    invq = 1.0 / q
    @inbounds for (ii, jj, cq, cinvq, c0) in coeffs
        i = Int(ii)
        j = Int(jj)
        v = scale * (cq * q + cinvq * invq + c0)
        K12[i, j] += v
        i == j || (K12[j, i] += v)
    end
    return K12
end

@inline function _rect_synth_corner_index(x::Float64, y::Float64, cx::Float64, cy::Float64)
    if x <= cx
        return y <= cy ? 1 : 3
    else
        return y <= cy ? 2 : 4
    end
end

function _rect_synth_basis_index_by_local_node(coords::AbstractMatrix)
    xmin = minimum(@view coords[:, 1])
    xmax = maximum(@view coords[:, 1])
    ymin = minimum(@view coords[:, 2])
    ymax = maximum(@view coords[:, 2])
    cx = 0.5 * (xmin + xmax)
    cy = 0.5 * (ymin + ymax)
    return ntuple(i -> _rect_synth_corner_index(
            Float64(coords[i, 1]), Float64(coords[i, 2]), cx, cy,
        ), 4)
end

function geometric_stiffness_quad4_nastran_rect_synth(coords::AbstractMatrix,
                                                       sigma_mem::AbstractVector,
                                                       h::Float64)
    Kg = zeros(24, 24)
    h > 1e-30 || return Kg
    lx, ly = _rect_synth_edge_lengths(coords)
    lx > 1e-30 && ly > 1e-30 || return Kg
    q = lx / ly
    K12 = zeros(12, 12)
    if _rect_synth_env_bool("JFEM_SOL105_RECT_SYNTH_ASPECT_LAW", false)
        law_nxx, law_nyy, law_nxy = nastran_rect_synth_kg_scales(q)
        nxx_scale = law_nxx * _rect_synth_env_scale("JFEM_SOL105_KG_RECT_SYNTH_NXX_SCALE", 1.0)
        nyy_scale = law_nyy * _rect_synth_env_scale("JFEM_SOL105_KG_RECT_SYNTH_NYY_SCALE", 1.0)
        nxy_scale = law_nxy * _rect_synth_env_scale("JFEM_SOL105_KG_RECT_SYNTH_NXY_SCALE", 1.0)
    else
        nxx_scale = _rect_synth_env_scale("JFEM_SOL105_KG_RECT_SYNTH_NXX_SCALE", 1.0)
        nyy_scale = _rect_synth_env_scale("JFEM_SOL105_KG_RECT_SYNTH_NYY_SCALE", 1.0)
        nxy_scale = _rect_synth_env_scale("JFEM_SOL105_KG_RECT_SYNTH_NXY_SCALE", 1.0)
    end
    _add_rect_synth_component!(K12, _NAS_RECT_SYNTH_COEFFS[:nxx], nxx_scale * sigma_mem[1] * h, q)
    _add_rect_synth_component!(K12, _NAS_RECT_SYNTH_COEFFS[:nyy], nyy_scale * sigma_mem[2] * h, q)
    _add_rect_synth_component!(K12, _NAS_RECT_SYNTH_COEFFS[:nxy], nxy_scale * sigma_mem[3] * h, q)
    tdofs = (1, 2, 3, 7, 8, 9, 13, 14, 15, 19, 20, 21)
    basis_by_local = _rect_synth_basis_index_by_local_node(coords)
    @inbounds for a in 1:12, b in 1:12
        local_node_a = div(a - 1, 3) + 1
        local_node_b = div(b - 1, 3) + 1
        comp_a = (a - 1) % 3 + 1
        comp_b = (b - 1) % 3 + 1
        basis_a = (basis_by_local[local_node_a] - 1) * 3 + comp_a
        basis_b = (basis_by_local[local_node_b] - 1) * 3 + comp_b
        Kg[tdofs[a], tdofs[b]] = K12[basis_a, basis_b]
    end
    return Kg
end

function geometric_stiffness_quad4_nastran_rect_synth(coords::AbstractMatrix,
                                                       sigma_mem_gp::AbstractMatrix,
                                                       h::Float64)
    size(sigma_mem_gp, 2) >= 3 || return zeros(24, 24)
    inv_ngp = 1.0 / max(size(sigma_mem_gp, 1), 1)
    sigma_mem = [
        sum(@view sigma_mem_gp[:, 1]) * inv_ngp,
        sum(@view sigma_mem_gp[:, 2]) * inv_ngp,
        sum(@view sigma_mem_gp[:, 3]) * inv_ngp,
    ]
    return geometric_stiffness_quad4_nastran_rect_synth(coords, sigma_mem, h)
end
