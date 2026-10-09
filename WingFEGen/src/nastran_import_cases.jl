# Read-only source case control and native constraint metadata for imported decks.
# The original source remains authoritative for every solve and deck export.
function imported_source_case_control(source)
    globals=Dict{String,Any}();subcases=Dict{Int,Dict{String,Any}}();current=globals
    for raw in eachline(IOBuffer(source["flattened"]))
        line=strip(first(split(raw,'$';limit=2)));isempty(line)&&continue
        occursin(r"^BEGIN\s+BULK"i,line)&&break
        uppercase(line)=="ENDDATA"&&break
        if (found=match(r"^SOL\s+(\d+)"i,line))!==nothing
            globals["SOL"]=parse(Int,found[1]);continue
        elseif (found=match(r"^SUBCASE\s+(\d+)"i,line))!==nothing
            current=get!(subcases,parse(Int,found[1]),Dict{String,Any}());continue
        elseif uppercase(line)=="CEND"
            continue
        elseif (found=match(r"^([^=]+)=(.*)$",line))!==nothing
            key=uppercase(strip(found[1]));value=strip(found[2]);number=tryparse(Int,value)
            if (modifier=match(r"^([^()]+)\(([^()]*)\)$",key))!==nothing
                key=strip(modifier[1]);current[key*"_MODIFIER"]=strip(modifier[2])
            end
            current[key]=key in ("TITLE","SUBTITLE","LABEL")||number===nothing ? value : number
        elseif occursin(r"^(GRID\*?|GRDSET|CORD[12][RCS]|CQUAD4|CTRIA3|MAT[128]|PARAM)(?:\s|,)"i,line)
            break # Punch-style bulk following CEND without BEGIN BULK.
        end
    end
    Dict("globals"=>globals,"subcases"=>subcases)
end

function imported_effective_case_control(model,sourcecontrol,sid)
    native=model["CASE_CONTROL"]
    result=Dict{String,Any}(key=>value for (key,value) in native if key!="SUBCASES")
    merge!(result,get(native["SUBCASES"],sid,Dict()))
    merge!(result,sourcecontrol["globals"])
    merge!(result,get(sourcecontrol["subcases"],sid,Dict()))
    result
end

function imported_case_selector(control,key)
    raw=get(control,key,nothing)
    raw===nothing&&return nothing
    raw isa Integer&&return Int(raw)
    tryparse(Int,string(raw))
end

function imported_load_selection(native,model,control)
    warnings=String[];load_id=imported_case_selector(control,"LOAD")
    scales=try native.Solver._load_sid_scales(model,load_id;include_zero=true) catch err
        push!(warnings,sprint(showerror,err));Dict{Int,Float64}()
    end
    counts=Dict{Tuple{String,Int},Int}()
    for (key,fallback) in (("FORCEs","FORCE"),("MOMENTs","MOMENT"),("PLOAD4s","PLOAD4/PLOAD2"),("PLOADs","PLOAD"),("PLOAD1s","PLOAD1"),("GRAVs","GRAV"),("RFORCEs","RFORCE"),("ACCEL1s","ACCEL1"),("ACCELs","ACCEL"),("SPCDs","SPCD"),("LOAD_COMBOS","LOAD"))
        for row in get(model,key,[])
            sid=Int(row["SID"]);haskey(scales,sid)||continue
            pair=(String(get(row,"TYPE",fallback)),sid);counts[pair]=get(counts,pair,0)+1
        end
    end
    rows=[Dict{String,Any}("type"=>kind,"set_id"=>sid,"count"=>count,"scale"=>scales[sid]) for ((kind,sid),count) in sort!(collect(counts);by=first)]
    load_id!==nothing&&isempty(rows)&&push!(warnings,"LOAD $load_id has no recognized source load entries; inspect the source and unsupported-card diagnostics.")
    for field in ("TEMP","TEMPERATURE")
        sid=imported_case_selector(control,field);sid===nothing&&continue
        count=length(get(get(model,"TEMPs",Dict()),sid,Dict()))+(haskey(get(model,"TEMPDs",Dict()),sid) ? 1 : 0)
        count>0&&push!(rows,Dict{String,Any}("type"=>"TEMP/TEMPD","set_id"=>sid,"count"=>count,"scale"=>1.))
        break
    end
    rows,scales,warnings
end

function imported_case_supports(native,m,control,scales)
    model=imported_native(m);index=Dict(id=>i for (i,id) in enumerate(m.node_ids));assignments=Dict{Int,Dict{String,Any}}();warnings=String[]
    spc_id=imported_case_selector(control,"SPC");valid=true
    sets=try native.Solver.selected_spc_sets(model,spc_id) catch err
        valid=false;push!(warnings,sprint(showerror,err));Set{Int}()
    end
    function add(gid,components,value,kind,set_id)
        if !haskey(index,gid)
            push!(warnings,"$kind references missing GRID $gid");return
        end
        dofs=sort!(unique([Int(c-'0') for c in string(components) if '1'<=c<='6']))
        isempty(dofs)&&return
        row=get!(assignments,gid) do
            grid=model["GRIDs"][string(gid)];cid=Int(get(grid,"CD",0))
            axes=try
                frame=native.Solver.get_coord_transform(model,cid,Matrix{Float64}(I,3,3);position=grid["X"])
                [collect(frame[:,i]) for i in 1:3]
            catch err
                push!(warnings,"GRID $gid: "*sprint(showerror,err));nothing
            end
            Dict{String,Any}("node"=>index[gid]-1,"grid"=>gid,"components"=>"","values"=>Dict{String,Float64}(),"coordinate_id"=>cid,"source_sets"=>Int[],"sources"=>Any[],"axes"=>axes,"ribs"=>Int[],"targets"=>["Imported boundary condition"])
        end
        set_id!==nothing&&!(set_id in row["source_sets"])&&push!(row["source_sets"],set_id)
        push!(row["sources"],Dict("type"=>kind,"set_id"=>set_id,"components"=>join(dofs),"value"=>value))
        for dof in dofs
            key=string(dof);existing=get(row["values"],key,0.)
            if !iszero(existing)&&!iszero(value)&&existing!=value
                push!(warnings,"GRID $gid component $dof has conflicting prescribed values $existing and $value")
            end
            row["values"][key]=iszero(value) ? existing : value
        end
    end
    for (key,grid) in model["GRIDs"]
        add(parse(Int,key),get(grid,"PS",""),0.,"GRID/GRDSET PS",nothing)
    end
    for entry in model["SPC1s"]
        sid=Int(entry["SID"]);sid in sets||continue
        for gid in entry["NODES"]
            add(Int(gid),entry["C"],Float64(get(entry,"D",0.)),haskey(entry,"D") ? "SPC" : "SPC1",sid)
        end
    end
    enforced=Dict{Tuple{Int,Int},Float64}()
    for entry in get(model,"SPCDs",[])
        sid=Int(entry["SID"]);haskey(scales,sid)||continue;factor=scales[sid]
        key=(Int(entry["GID"]),Int(entry["C"]));enforced[key]=get(enforced,key,0.)+factor*Float64(entry["D"])
    end
    prescribed=Any[]
    for ((gid,dof),value) in sort!(collect(enforced);by=first)
        row=get(assignments,gid,nothing);constrained=row!==nothing&&haskey(row["values"],string(dof))
        constrained ? row["values"][string(dof)]=value : push!(warnings,"SPCD selects unconstrained GRID $gid component $dof; its SPC set must also be selected")
        push!(prescribed,Dict("grid"=>gid,"component"=>dof,"value"=>value,"constrained"=>constrained))
        constrained&&push!(row["sources"],Dict("type"=>"SPCD via LOAD","set_id"=>imported_case_selector(control,"LOAD"),"components"=>string(dof),"value"=>value))
    end
    rows=sort!(collect(values(assignments));by=row->row["node"])
    for row in rows;row["components"]=join(sort!(collect(keys(row["values"]))));sort!(row["source_sets"]);end
    dofs=[row["components"] for row in rows]
    Dict{String,Any}("count"=>length(rows),"nodes"=>blob_i32([row["node"] for row in rows]),"node_components"=>dofs,"components"=>length(unique(dofs))==1 ? first(dofs) : "mixed","mode"=>"imported","assignments"=>rows,"selected_spc_id"=>spc_id,"expanded_sets"=>sort!(collect(sets)),"selection_valid"=>valid,"constrained_dofs"=>sum(row->length(row["values"]),rows;init=0),"enforced_displacements"=>prescribed,"warnings"=>unique(warnings),"note"=>"Selected case only: SPC/SPC1, SPCADD unions and permanent GRID/GRDSET PS. Values are in source units and GRID CD components. Automatic numerical constraints are determined during analysis.")
end

function imported_prepare_cases!(native,m)
    model=imported_native(m);sourcecontrol=imported_source_case_control(m.params["imported.source"])
    m.params["imported.case_control"]=sourcecontrol["globals"]
    for row in m.params["imported.cases"]
        control=imported_effective_case_control(model,sourcecontrol,row["id"])
        row["declared_case_control"]=copy(control)
        preload=imported_case_selector(control,"STATSUB")
        if Int(model["SOL"])==105&&preload!==nothing&&haskey(model["CASE_CONTROL"]["SUBCASES"],preload)
            static=imported_effective_case_control(model,sourcecontrol,preload)
            control["LOAD"]=get(static,"LOAD",nothing)
            get(control,"SPC",nothing)===nothing&&(control["SPC"]=get(static,"SPC",nothing))
            row["load_source_case_id"]=preload
        else
            row["load_source_case_id"]=row["id"]
        end
        rows,scales,warnings=imported_load_selection(native,model,control)
        row["case_control"]=control;row["load_cards"]=rows
        row["spc"]=imported_case_supports(native,m,control,scales)
        row["label"]=String(get(control,"LABEL",get(control,"SUBTITLE","Subcase $(row["id"])")))
        row["warnings"]=unique(vcat(warnings,row["spc"]["warnings"]))
        if Int(model["SOL"])==106
            try native.Solver._assert_nonlinear_prescribed_supported(model,imported_case_selector(control,"LOAD"),imported_case_selector(control,"SPC")) catch err
                push!(row["warnings"],sprint(showerror,err))
            end
        end
        row["analysis_role"]=get(control,"STATSUB",nothing)===nothing ? (Int(model["SOL"])==105 ? "Static preload" : "Analysis") : "Buckling from subcase $(control["STATSUB"])"
    end
    # Result extraction uses this facade union to retain support reactions;
    # the viewport then selects each case's own node/component assignments.
    empty!(m.spc)
    append!(m.spc,sort!(unique([entry["node"]+1 for row in m.params["imported.cases"] for entry in row["spc"]["assignments"]])))
    m
end

function imported_prepare_inventory!(native,m,cards,reportpath)
    # Use the selected native solver's own support inventory, rather than a
    # second hard-coded importer card list that can drift from that solver.
    open(reportpath,"w") do output
        redirect_stdout(output) do
            Base.invokelatest(native._report_card_inventory,cards)
        end
    end
    report=read(reportpath,String);isempty(report)||print(report)
    unprocessed=Any[]
    for line in eachline(IOBuffer(report))
        found=match(r"^\s+([A-Z][A-Z0-9*]+):\s+(\d+)(.*)$",line);found===nothing&&continue
        name=found[1];count=parse(Int,found[2]);guarded=occursin("retained unsupported",found[3])
        haskey(cards,name)&&(isempty(strip(found[3]))||guarded)||continue
        push!(unprocessed,Dict("name"=>name,"count"=>count,"status"=>guarded ? "unsupported_if_selected" : "unprocessed","message"=>guarded ? "Retained by the native parser; selecting this load raises a solver capability error." : "Source text is retained unchanged, but this native solver does not process this card type. Its physical contribution is not analyzed."))
    end
    m.params["imported.unprocessed_cards"]=unprocessed
    if !isempty(unprocessed)
        push!(m.params["imported.warnings"],"Retained source includes cards not fully analyzed by this JFEM version: "*join(["$(row["name"]) ($(row["count"]))" for row in unprocessed],", ")*". Inspect card diagnostics before running.")
    end
    m
end
