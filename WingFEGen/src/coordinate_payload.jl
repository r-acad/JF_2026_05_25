# Coordinate glyphs show the actual deck frame in BASIC, not a relocated
# element frame. Curvilinear systems have a defining orthonormal triad; their
# radial/tangential displacement basis still depends on the evaluation point.
function basic_coordinate_record()
    Dict{String,Any}("id"=>0,"type"=>"RECTANGULAR","card"=>"BASIC","origin"=>[0.,0.,0.],
        "x"=>[1.,0.,0.],"y"=>[0.,1.,0.],"z"=>[0.,0.,1.],"properties"=>Dict("Definition"=>"Global BASIC frame"))
end

function generated_coordinate_payload(groups)
    records=Any[basic_coordinate_record()]
    for group in groups
        group["kind"] in ("quad","tria")||continue
        # Reuse the already computed MCID axes at the viewer's Float32
        # precision, avoiding another full element-frame pass.
        ids=reinterpret(Int32,group["eids"].bytes)
        axes=Dict(key=>reinterpret(Float32,group["axes"][key].bytes) for key in ("x","y","z"))
        for (index,id) in enumerate(ids)
            push!(records,Dict{String,Any}("id"=>Int(id),"type"=>"RECTANGULAR","card"=>"CORD2R",
                "origin"=>[0.,0.,0.],"x"=>Float64.(axes["x"][3index-2:3index]),
                "y"=>Float64.(axes["y"][3index-2:3index]),"z"=>Float64.(axes["z"][3index-2:3index]),
                "properties"=>Dict("Role"=>"Shell material coordinate system (MCID)","Element ID"=>Int(id),"Reference ID"=>0)))
        end
    end
    Dict("systems"=>records,"warnings"=>String[],"note"=>"Generated shell MCIDs share the BASIC origin, exactly as written in CORD2R. Their triads and labels can overlap. Shell local axes display these directions at element centers.")
end

function imported_coordinate_payload(native)
    records=Any[basic_coordinate_record()];warnings=String[]
    for (key,frame) in sort!(collect(get(native,"CORDs",Dict()));by=p->parse(Int,string(first(p))))
        id=parse(Int,string(key));id==0&&continue
        type=String(get(frame,"TYPE",""))
        try
            type in ("RECTANGULAR","CYLINDRICAL","SPHERICAL")||throw(ArgumentError("unsupported coordinate type $type"))
            vectors=[Float64.(frame[key]) for key in ("Origin","U","V","W")]
            all(v->length(v)==3&&all(isfinite,v),vectors)||throw(ArgumentError("nonfinite or missing defining frame"))
            origin,x,y,z=vectors
            maximum(abs(sum(a.*b)-(i==j ? 1. : 0.)) for (i,a) in enumerate((x,y,z)) for (j,b) in enumerate((x,y,z)))<1e-6||throw(ArgumentError("defining axes are not orthonormal"))
            sum(collect(cross3(Tuple(x),Tuple(y))).*z)>1-1e-6||throw(ArgumentError("defining axes are not right handed"))
            card=(haskey(frame,"G1") ? "CORD1" : haskey(frame,"A_raw") ? "CORD2" : "Resolved ")*Dict("RECTANGULAR"=>"R","CYLINDRICAL"=>"C","SPHERICAL"=>"S")[type]
            properties=Dict{String,Any}("Coordinate ID"=>id,"Type"=>type,"Source card"=>card)
            for key in ("RID","G1","G2","G3","A_raw","B_raw","C_raw");haskey(frame,key)&&(properties[key]=frame[key]);end
            type=="RECTANGULAR"||(properties["Triad note"]="Defining Cartesian triad of this curvilinear system; radial/tangential directions vary with the evaluation point.")
            push!(records,Dict("id"=>id,"type"=>type,"card"=>card,"origin"=>origin,"x"=>x,"y"=>y,"z"=>z,"properties"=>properties))
        catch error
            push!(warnings,"Coordinate $id is not drawn: "*sprint(showerror,error))
        end
    end
    Dict("systems"=>records,"warnings"=>warnings,"note"=>"Coordinate origins and defining axes are resolved to global BASIC, including nested RID and CORD1 GRID definitions. Cylindrical/spherical triads show their defining axes, not a displacement basis at an arbitrary point.")
end

function imported_entity_sources(cards)
    records=Dict{Int,Any}()
    for card in ("RBE2","RBAR","RBE1","RSPLINE","CELAS1","CELAS2","CONM2","RBE3"),fields in get(cards,card,Any[])
        length(fields)>=3||continue
        id=tryparse(Int,strip(string(fields[3])));id===nothing&&continue
        record=Dict{String,Any}("type"=>card,"source_fields"=>string.(fields[2:end]))
        if card=="RBAR"
            for (index,key) in enumerate(("GA","GB","CNA","CNB","CMA","CMB"))
                record[key]=length(fields)>=index+3 ? string(fields[index+3]) : ""
            end
        end
        records[id]=record
    end
    records
end

"""A GRID displacement axis in BASIC, including point-dependent CORD*C/S bases.
The importer runs without the solver module in the server process. These basis
formulae match the native GRID CD transformation; tests compare both paths.
"""
function imported_grid_component_axis(native,grid,component)
    component in 1:6||return nothing
    cid=Int(get(grid,"CD",0));axis=mod1(component,3)
    cid==0&&return Float64[i==axis for i in 1:3]
    frame=get(get(native,"CORDs",Dict()),string(cid),nothing)
    frame===nothing&&throw(ArgumentError("Undefined GRID displacement coordinate $cid"))
    basis=hcat(Float64.(frame["U"]),Float64.(frame["V"]),Float64.(frame["W"]))
    type=uppercase(string(get(frame,"TYPE","RECTANGULAR")))
    type=="RECTANGULAR"&&return collect(basis[:,axis])
    localpoint=basis'*(Float64.(grid["X"])-Float64.(frame["Origin"]))
    if type=="CYLINDRICAL"
        theta=atan(localpoint[2],localpoint[1]);c=cos(theta);s=sin(theta)
        return collect(basis*([c s 0.;-s c 0.;0. 0. 1.]'[:,axis]))
    elseif type=="SPHERICAL"
        theta=atan(hypot(localpoint[1],localpoint[2]),localpoint[3]);phi=atan(localpoint[2],localpoint[1])
        localbasis=[sin(theta)*cos(phi) cos(theta)*cos(phi) -sin(phi);
                    sin(theta)*sin(phi) cos(theta)*sin(phi) cos(phi);
                    cos(theta) -sin(theta) 0.]
        return collect(basis*localbasis[:,axis])
    end
    throw(ArgumentError("Unsupported GRID displacement coordinate type $type"))
end

function imported_spring_endpoints(native,element,index)
    endpoints=Any[]
    for endindex in 1:2
        gid=Int(get(element,"G$endindex",0));component=Int(get(element,"C$endindex",0))
        endpoint=Dict{String,Any}("end"=>endindex,"grid"=>gid,"component"=>component,
            "grounded"=>gid==0,"node"=>get(index,gid,0)-1,"axis"=>nothing)
        if haskey(index,gid)&&component in 1:6
            grid=native["GRIDs"][string(gid)];endpoint["coordinate_id"]=Int(get(grid,"CD",0))
            try
                endpoint["axis"]=imported_grid_component_axis(native,grid,component)
            catch error
                endpoint["warning"]=sprint(showerror,error)
            end
        elseif gid!=0
            endpoint["warning"]=component==0 ? "Scalar component: no spatial axis is defined" : "Undefined GRID or component"
        end
        push!(endpoints,endpoint)
    end
    endpoints
end
