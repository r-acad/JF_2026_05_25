# Resolve controls for each SOL106 subcase. NLPARM is selected by Case
# Control; merely defining a card must not change unrelated subcases.
function _sol106_controls(model, cc, sub, sid)
    legacy_tol = Float64(get(model, "PARAM_NLTOL", 1e-6))
    controls = (
        load_steps=Int(get(model, "PARAM_NLLOADSTEPS", 4)),
        max_iter=Int(get(model, "PARAM_NLMAXITER", 8)),
        tol=legacy_tol,
        residual_tol=Float64(get(model, "PARAM_NLRESTOL", legacy_tol)),
        work_tol=legacy_tol,
        convergence_criteria="LEGACY",
        relaxation=Float64(get(model, "PARAM_NLRELAX", 1.0)),
        line_search_max_backtracks=Int(get(model, "PARAM_NLLSMAX", 6)),
        line_search_reduction=Float64(get(model, "PARAM_NLLSREDUCE", 0.5)),
        max_cutbacks=Int(get(model, "PARAM_NLCUTMAX", 6)),
        cutback_reduction=Float64(get(model, "PARAM_NLCUTREDUCE", 0.5)),
        step_growth=Float64(get(model, "PARAM_NLSTEPGROW", 1.25)),
        intermediate_output=false,
    )
    selection = get(sub, "NLPARM", get(cc, "NLPARM", nothing))
    if selection === nothing
        return (; controls..., metadata=Dict{String,Any}(
            "source"=>"PARAM/defaults", "subcase_id"=>sid,
            "nlparm_id"=>nothing, "convergence_policy"=>"P AND (U OR W)",
            "effective_controls"=>Dict(string(k)=>v for (k,v) in pairs(controls))))
    end
    parsed = ReferenceParser.parse_reference_number(selection, nothing)
    parsed isa Real && isfinite(parsed) && isinteger(parsed) && parsed > 0 ||
        throw(ArgumentError("SOL106 subcase $sid requires a positive integer NLPARM selector; received $selection"))
    nlid = Int(parsed)
    cards = get(model, "NLPARMs", Dict())
    raw = get(cards, string(nlid), get(cards, nlid, nothing))
    raw === nothing && throw(ArgumentError("SOL106 subcase $sid selects missing NLPARM $nlid"))
    card = ReferenceParser.normalize_nlparm(raw)
    explicit = Set(card["EXPLICIT_FIELDS"])
    unsupported = intersect(explicit, Set(("MAXDIV", "FSTRESS", "LSTOL", "MAXR", "RTOLB")))
    isempty(unsupported) || throw(ArgumentError(
        "SOL106 NLPARM $nlid explicitly requests unsupported controls $(join(sort!(collect(unsupported)), ", ")); these cannot be silently ignored"))
    card["DT"] == 0.0 || throw(ArgumentError("SOL106 NLPARM $nlid DT must be blank or zero; creep/time-dependent increments are not implemented"))
    card["KMETHOD"] in ("AUTO", "ITER") || throw(ArgumentError(
        "SOL106 NLPARM $nlid KMETHOD=$(card["KMETHOD"]) is unsupported; JFEM updates the tangent every Newton iteration"))
    if "KSTEP" in explicit && card["KSTEP"] != 1
        throw(ArgumentError("SOL106 NLPARM $nlid KSTEP=$(card["KSTEP"]) is unsupported; use KSTEP=1 for an updated tangent every iteration"))
    end
    if "MAXQN" in explicit && card["MAXQN"] != 0
        throw(ArgumentError("SOL106 NLPARM $nlid explicit MAXQN=$(card["MAXQN"]) requests unsupported quasi-Newton updates; use zero or leave blank for JFEM's full Newton solver"))
    end
    conv = card["CONV"]
    !isempty(conv) && all(c->c in ('U','P','W'), conv) && length(unique(conv)) == length(conv) ||
        throw(ArgumentError("SOL106 NLPARM $nlid CONV must select distinct U, P and/or W criteria; received $conv"))
    card["INTOUT"] in ("NO", "YES", "ALL") || throw(ArgumentError(
        "SOL106 NLPARM $nlid INTOUT=$(card["INTOUT"]) is unsupported; use NO, YES or ALL"))
    for name in ("NINC", "MAXITER")
        card[name] > 0 || throw(ArgumentError("SOL106 NLPARM $nlid $name must be positive"))
    end
    for name in ("MAXBIS", "MAXLS")
        card[name] >= 0 || throw(ArgumentError("SOL106 NLPARM $nlid $name must be nonnegative"))
    end
    for name in ("EPSU", "EPSP", "EPSW")
        card[name] > 0.0 || throw(ArgumentError("SOL106 NLPARM $nlid $name must be positive"))
    end
    controls = merge(controls, (
        load_steps=card["NINC"], max_iter=card["MAXITER"],
        tol=card["EPSU"], residual_tol=card["EPSP"], work_tol=card["EPSW"],
        convergence_criteria=join(c for c in "UPW" if c in conv),
        line_search_max_backtracks=card["MAXLS"], max_cutbacks=card["MAXBIS"],
        step_growth=1.0, intermediate_output=card["INTOUT"] != "NO",
    ))
    metadata = Dict{String,Any}(
        "source"=>"NLPARM", "subcase_id"=>sid, "nlparm_id"=>nlid,
        "selection_scope"=>haskey(sub, "NLPARM") ? "subcase" : "global",
        "requested_card"=>card,
        "effective_controls"=>Dict(string(k)=>v for (k,v) in pairs(controls)),
        "convergence_policy"=>"all selected U/P/W criteria must pass",
        "algorithm"=>"JFEM updated-tangent Newton with residual line search and load bisection",
        "algorithm_notes"=>[
            "KMETHOD AUTO/ITER uses JFEM's tangent update at every iteration; Reference-specific update heuristics and blank quasi-Newton defaults are not reproduced.",
            "NINC defines the nominal equal-load increments; failed increments may be bisected up to MAXBIS. Automatic increment growth is disabled for NLPARM.",
            "U = norm(correction)/norm(displacement); P = norm(free residual)/norm(free applied force); W = abs(correction' * preceding residual)/abs(displacement' * applied force).",
        ],
    )
    return (; controls..., metadata)
end
