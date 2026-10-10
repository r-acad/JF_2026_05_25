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
