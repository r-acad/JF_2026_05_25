"""Current authored loft only. No FE model, load calculation or server mutation."""
function geometry_preview_payload(raw::AbstractDict)
    geometry=Dict{String,Any}(k=>v for (k,v) in raw if any(prefix->startswith(k,prefix),("planform.","airfoil.","loft.","movable_surfaces.")))
    p,unknown=normalize_params(geometry)
    isempty(unknown)||throw(ArgumentError("Unknown geometry parameters: "*join(unknown,", ")))
    w=make_wing(p)
    etas=with_planform_stations(w,sort!(unique(vcat(collect(range(0.,1.;length=49)),w.airfoil_etas,loft_control_etas(w)))))
    length(etas)<=4096||throw(ArgumentError("Too many loft stations for the geometry preview"))
    xyz,quads,nloop,_=aero_surface(w,etas,41,.15,.65)
    return Dict{String,Any}("ok"=>true,"geometry_only"=>true,
        "aero"=>Dict("count"=>length(quads)÷4,"xyz"=>blob_f32(xyz),"conn"=>blob_i32(quads;offset=-1),
            "n_loop"=>nloop,"sections"=>airfoil_sections_payload(w)),
        "bbox"=>Dict("min"=>[minimum(xyz[k:3:end]) for k in 1:3],"max"=>[maximum(xyz[k:3:end]) for k in 1:3]),
        "movables"=>movable_surfaces_preview(p))
end

function handle_geometry_preview(st,req)
    try
        raw=JSON.parse(String(req.body));raw isa AbstractDict||throw(ArgumentError("Expected geometry parameters"))
        return msgpack_response(geometry_preview_payload(raw))
    catch error
        return error_response("Geometry preview: "*describe_error(error))
    end
end
