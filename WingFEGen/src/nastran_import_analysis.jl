# Analysis overlays never regenerate imported geometry or alter the saved source.
function imported_analysis_options(raw=nothing)
    raw===nothing&&(raw=Dict())
    raw isa AbstractDict||throw(ArgumentError("Imported analysis settings must be an object"))
    solution=string(get(raw,"solution","source"));solution in ("source","101","103","105","106")||throw(ArgumentError("Imported analysis supports SOL101, SOL103, SOL105 and SOL106"))
    follower=string(get(raw,"follower","source"));follower in ("source","fixed","force")||throw(ArgumentError("Invalid imported follower-force option"))
    options=Dict{String,Any}("solution"=>solution,"follower"=>follower)
    for (key,default,lo,hi,integer) in (("modes",10,1,200,true),("buckling_max_factor",100.,1e-8,1e12,false),("load_steps",20,1,10000,true),("max_iterations",40,1,10000,true),("max_cutbacks",12,0,100,true),("displacement_tolerance",1e-6,1e-14,.1,false),("residual_tolerance",1e-5,1e-14,.1,false))
        value=get(raw,key,default)
        value isa Real&&isfinite(value)&&lo<=value<=hi&&(!integer||isinteger(value))||throw(ArgumentError("Invalid imported analysis setting $key"))
        options[key]=integer ? Int(value) : Float64(value)
    end
    options
end

function imported_analysis_signature(m)
    get(m.params,"imported.analysis_signature",m.params["imported.source"]["signature"])
end

function imported_card_name(line)
    text=strip(first(split(line,'$';limit=2)))
    isempty(text)&&return ""
    uppercase(strip(first(split(first(text,min(8,length(text))),','))))
end

# Read only the selected entry's fields. All other source text stays verbatim.
function imported_entry_fields(lines)
    fields=String[]
    for (i,raw) in enumerate(lines)
        line=first(split(raw,'$';limit=2))
        isempty(strip(line))&&continue
        if occursin(',',line)
            row=split(line,',');append!(fields,String.(row[2:end]))
        else
            large=endswith(strip(first(line,min(8,length(line)))),'*')||startswith(strip(line),'*')
            width=large ? 16 : 8
            padded=rpad(line,72)
            append!(fields,[strip(padded[j:min(j+width-1,72)]) for j in 9:width:72])
        end
    end
    strip.(fields)
end

function imported_overlay_bulk(lines,options)
    io=IOBuffer();i=1;force_count=0;max_method=0;source_follower=false;rot_sets=Set{Int}()
    replacing=Set{String}()
    options["follower"]!="source"&&push!(replacing,"JFFOLLOW")
    options["solution"]=="106"&&union!(replacing,["NLLOADSTEPS","NLMAXITER","NLTOL","NLRESTOL","NLCUTMAX","NLMETHOD"])
    while i<=length(lines)
        line=lines[i];name=replace(imported_card_name(line),"*"=>"");j=i+1
        if name in ("FORCE","PARAM","EIGRL","EIGR")
            while j<=length(lines)
                key=imported_card_name(lines[j])
                (startswith(key,"+")||startswith(key,"*")||startswith(strip(lines[j]),",")||(!isempty(strip(lines[j]))&&isempty(key)))||break
                j+=1
            end
            fields=imported_entry_fields(lines[i:j-1])
            if name=="PARAM"&&uppercase(first(fields))=="JFFOLLOW"
                source_follower=length(fields)>1&&tryparse(Float64,fields[2])==1.
            elseif name=="FORCE"&&length(fields)>=8&&uppercase(fields[8])=="ROT"
                sid=tryparse(Int,fields[1]);sid===nothing||push!(rot_sets,sid)
            end
            if name in ("EIGRL","EIGR")
                id=tryparse(Int,first(fields));id===nothing||(max_method=max(max_method,id))
            elseif name=="PARAM"&&uppercase(first(fields)) in replacing
                i=j;continue
            elseif name=="FORCE"&&options["follower"]!="source"
                length(fields)>=7||throw(ArgumentError("Incomplete FORCE entry in imported source"))
                println(io,join(vcat(["FORCE"],fields[1:7],[options["follower"]=="force" ? "ROT" : ""]),','))
                force_count+=1;i=j;continue
            end
        end
        uppercase(strip(first(split(line,'$';limit=2))))=="ENDDATA"||println(io,line)
        i+=1
    end
    if options["follower"]!="source"
        options["follower"]=="force"&&force_count==0&&throw(ArgumentError("This deck has no concentrated FORCE cards to make follower loads. Pressure, moment and body-load follower tangents are not supported."))
        println(io,"PARAM,JFFOLLOW,",options["follower"]=="force" ? 1 : 0)
    end
    if options["solution"]=="106"
        for (name,key) in (("NLLOADSTEPS","load_steps"),("NLMAXITER","max_iterations"),("NLTOL","displacement_tolerance"),("NLRESTOL","residual_tolerance"),("NLCUTMAX","max_cutbacks"))
            println(io,"PARAM,$name,",options[key])
        end
        println(io,"PARAM,NLMETHOD,AUTO")
    end
    String(take!(io)),max_method+1,source_follower,rot_sets
end

function imported_check_source_followers(m,sol,source_follower,rot_sets)
    sol in ("103","105")&&source_follower&&!isempty(rot_sets)||return
    active=Set(Int(row["set_id"]) for case in m.params["imported.cases"] for row in get(case,"load_cards",[]) if get(row,"type","")=="FORCE"&&!iszero(get(row,"scale",1.)))
    (!isempty(intersect(active,rot_sets))||all(!haskey(case,"load_cards") for case in m.params["imported.cases"]))&&throw(ArgumentError("The source activates FORCE ROT follower loads, which SOL$sol does not support. Choose Fixed directions in Analysis before running this solution."))
end

function imported_analysis_model(m,raw=nothing)
    options=imported_analysis_options(raw)
    source=m.params["imported.source"];sol=options["solution"]=="source" ? m.params["output.solution"] : options["solution"]
    if options["solution"]=="source"&&options["follower"]=="source"
        # Keep the original bytes and selectors, but never silently ignore an
        # explicitly activated unsupported follower tangent in an eigen solve.
        if sol in ("103","105")&&occursin(r"JFFOLLOW"i,source["flattened"])&&occursin(r"\bROT\b"i,source["flattened"])
            lines=split(source["flattened"],'\n');bulk=findfirst(line->occursin(r"^\s*BEGIN\s+BULK"i,line),lines)
            _,_,source_follower,rot_sets=imported_overlay_bulk(bulk===nothing ? lines : lines[bulk+1:end],options)
            imported_check_source_followers(m,sol,source_follower,rot_sets)
        end
        return m
    end
    options["follower"]=="force"&&!(sol in ("101","106"))&&throw(ArgumentError("Follower FORCE loads are supported only by SOL101 and SOL106. Select fixed forces for SOL103/SOL105."))
    # A source-preserving request stays byte-for-byte unchanged. An override
    # requires explicit section delimiters so no bulk card is guessed away.
    lines=split(source["flattened"],'\n');bulk=findfirst(line->occursin(r"^\s*BEGIN\s+BULK"i,line),lines)
    bulk===nothing&&throw(ArgumentError("Changing an imported solution requires BEGIN BULK. Use the source solution for a punch deck."))
    cend=findfirst(line->uppercase(strip(first(split(line,'$';limit=2))))=="CEND",lines[1:bulk-1])
    cend===nothing&&throw(ArgumentError("Changing an imported solution requires CEND before BEGIN BULK"))
    body,method,source_follower,rot_sets=imported_overlay_bulk(lines[bulk+1:end],options)
    options["follower"]=="source"&&imported_check_source_followers(m,sol,source_follower,rot_sets)
    io=IOBuffer();executive=join(lines[1:cend],"\n")
    executive=replace(executive,r"(?im)^\s*SOL\s+\d+[^\r\n]*"=>"SOL $sol")
    occursin(r"(?im)^SOL\s",executive)||throw(ArgumentError("Imported executive section has no SOL statement"))
    println(io,executive)
    blocks=Dict{Int,Vector{String}}();order=Int[];globals=String[];target=globals
    for line in lines[cend+1:bulk-1]
        matchcase=match(r"^\s*SUBCASE\s+(\d+)"i,line)
        if matchcase!==nothing
            id=parse(Int,matchcase[1]);haskey(blocks,id)&&throw(ArgumentError("Duplicate source SUBCASE $id"))
            target=blocks[id]=String[];push!(order,id)
        else
            push!(target,String(line))
        end
    end
    isempty(order)&&(push!(order,1);blocks[1]=String[])
    control=imported_source_case_control(source)
    # Existing buckling eigen-subcases are analysis companions, not new loads.
    if options["solution"]!="source"
        filter!(id->get(get(control["subcases"],id,Dict()),"STATSUB",nothing)===nothing,order)
    end
    isempty(order)&&throw(ArgumentError("No source static/preload subcase is available for the selected solution"))
    clean(row)=options["solution"]=="source" ? row : filter(line->!occursin(r"^\s*(METHOD|CMETHOD|STATSUB|NLPARM|TSTEP)(?:\s*\([^)]*\))?\s*="i,line),row)
    for line in clean(globals);println(io,line);end
    println(io,"DISPLACEMENT(PRINT) = ALL\nSTRESS(PRINT) = ALL\nFORCE(PRINT) = ALL\nSPCFORCES(PRINT) = ALL")
    mapping=Dict{Int,Int}();nextsid=maximum(keys(blocks))+1
    cases=Any[]
    for id in order
        println(io,"SUBCASE $id")
        for line in clean(blocks[id]);println(io,line);end
        sol=="103"&&options["solution"]!="source"&&println(io,"  METHOD = $method")
        mapping[id]=id
        original=only(filter(c->Int(c["id"])==id,m.params["imported.cases"]))
        push!(cases,merge(original,Dict("result_required"=>true)))
        if sol=="105"&&options["solution"]!="source"
            mapping[id]=nextsid
            println(io,"SUBCASE $nextsid\n  LABEL = Buckling of source subcase $id\n  STATSUB = $id\n  METHOD = $method")
            # Copy constraint selectors to the eigenproblem too.
            effective=merge(control["globals"],get(control["subcases"],id,Dict()))
            for key in ("SPC","MPC");haskey(effective,key)&&println(io,"  $key = ",effective[key]);end
            nextsid+=1
        end
    end
    println(io,"BEGIN BULK");write(io,body)
    if sol in ("103","105")&&options["solution"]!="source"
        println(io,"EIGRL,$method,",sol=="105" ? "1.e-6" : "",",",sol=="105" ? options["buckling_max_factor"] : "",",",options["modes"],",,,,MASS")
    end
    println(io,"ENDDATA")
    deck=String(take!(io));params=copy(m.params)
    params["output.solution"]=sol;params["imported.analysis"]=options;params["imported.analysis_deck"]=deck
    params["imported.analysis_signature"]=bytes2hex(SHA.sha256(IOBuffer(deck)));params["imported.analysis_cases"]=mapping
    params["imported.cases"]=cases;params["imported.analysis_control"]=imported_source_case_control(Dict("flattened"=>deck))
    # Restore/cache the source native graph only if results or sensitivities
    # actually require it. Run launch itself never deserializes or builds it.
    params["imported.analysis_native_pending"]=true
    Model((field===:params ? params : getfield(m,field) for field in fieldnames(Model))...)
end

function imported_analysis_native(params,native)
    get(params,"imported.analysis_native_pending",false)||return native
    model=copy(native);model["SOL"]=parse(Int,params["output.solution"])
    control=params["imported.analysis_control"];globals=copy(control["globals"]);delete!(globals,"SOL")
    subs=Dict{Int,Any}()
    for (id,row) in control["subcases"];subs[id]=merge(globals,row);end
    model["CASE_CONTROL"]=merge(globals,Dict("SUBCASES"=>subs))
    options=params["imported.analysis"]
    if options["follower"]!="source"
        model["PARAM_JFFOLLOW"]=options["follower"]=="force" ? 1 : 0
        model["FORCEs"]=[merge(force,Dict("FLLW"=>options["follower"]=="force" ? "ROT" : "")) for force in get(native,"FORCEs",[])]
    end
    params["imported.analysis_native_pending"]=false
    model
end
