# Abaqus text input interoperability. This reader preserves source labels and
# topology; supported mechanics are translated to JFEM's native formulations.
# It never supplies a material, constraint, load or analysis absent in the input.
import SHA
import CodecZlib

const ABAQUS_ELEMENT_NODES=Dict("C3D4"=>4,"C3D10"=>10,"C3D10M"=>10,"C3D10H"=>10,
    "C3D6"=>6,"C3D15"=>15,"C3D8"=>8,"C3D8R"=>8,"C3D8I"=>8,"C3D8H"=>8,"C3D20"=>20,"C3D20R"=>20,"C3D27"=>27,
    "S3"=>3,"S3R"=>3,"S4"=>4,"S4R"=>4,"S6"=>6,"S8"=>8,"S8R"=>8,
    "CPS3"=>3,"CPS4"=>4,"CPS4R"=>4,"CPS6"=>6,"CPS8"=>8,"CPE3"=>3,"CPE4"=>4,"CPE4R"=>4,"CPE6"=>6,"CPE8"=>8,
    "T3D2"=>2,"T3D3"=>3,"B31"=>2,"B32"=>3,"MASS"=>1,"R3D3"=>3,"R3D4"=>4)
const ABAQUS_NATIVE_ELEMENTS=Dict("C3D4"=>"CTETRA","C3D10"=>"CTETRA","C3D6"=>"CPENTA","C3D8"=>"CHEXA","S3"=>"CTRIA3","S4"=>"CQUAD4")
const ABAQUS_NONMECHANICAL=Set(["HEADING","PREPRINT","OUTPUT","NODE OUTPUT","ELEMENT OUTPUT","ENERGY OUTPUT","NODE PRINT","EL PRINT","NODE FILE","EL FILE","FILE OUTPUT"])

_abaqus_name(value)=uppercase(strip(strip(String(value)),['\"','\'']))
function _abaqus_fields(line::AbstractString)
    fields=String[];io=IOBuffer();quotechar='\0'
    for c in line
        if c in ('\"','\'')
            if quotechar=='\0';quotechar=c;elseif quotechar==c;quotechar='\0';else;print(io,c);end
        elseif c==','&&quotechar=='\0'
            push!(fields,strip(String(take!(io))))
        else
            print(io,c)
        end
    end
    quotechar=='\0'||throw(ArgumentError("Unclosed quote in input line: $line"))
    push!(fields,strip(String(take!(io))));return fields
end
function _abaqus_number(value,label;integer=false,positive=false)
    value===nothing&&throw(ArgumentError("$label must be supplied explicitly"))
    value isa Bool&&throw(ArgumentError("$label must be numeric"))
    n=value isa Real ? Float64(value) : tryparse(Float64,replace(strip(String(value)),'D'=>'E','d'=>'e'))
    n!==nothing&&isfinite(n)||throw(ArgumentError("$label must be finite: $(repr(value))"))
    integer&&(!isinteger(n)||n<typemin(Int)||n>typemax(Int))&&throw(ArgumentError("$label must be an integer"))
    positive&&n<=0&&throw(ArgumentError("$label must be positive"))
    return integer ? Int(n) : Float64(n)
end
function _abaqus_header(line)
    tokens=_abaqus_fields(strip(line)[2:end]);keyword=join(split(_abaqus_name(first(tokens)))," ");options=Dict{String,String}()
    for token in tokens[2:end]
        isempty(token)&&continue
        pair=split(token,'=';limit=2);key=_abaqus_name(first(pair))
        haskey(options,key)&&throw(ArgumentError("Duplicate *$keyword option $key"))
        options[key]=length(pair)==2 ? strip(last(pair)) : ""
    end
    return keyword,options
end
function _abaqus_diagnostic!(doc,severity,code,message;kwargs...)
    entry=Dict{String,Any}("severity"=>severity,"code"=>code,"message"=>message)
    for (key,value) in kwargs;entry[String(key)]=value;end
    push!(doc["diagnostics"],entry);return entry
end
function _abaqus_unsupported!(doc,message,strict;keyword="")
    _abaqus_diagnostic!(doc,"error","unsupported_keyword",message;keyword)
    strict&&throw(ArgumentError(message));return nothing
end
function _abaqus_read_text(path)
    bytes=read(path)
    lfs_header=Vector{UInt8}(codeunits("version https://git-lfs.github.com/spec/v1"))
    length(bytes)>=length(lfs_header)&&bytes[1:length(lfs_header)]==lfs_header&&throw(ArgumentError("Input is a Git LFS pointer, not the actual mesh/archive: $path. Fetch the actual large-file object with git lfs pull in its source repository, or download the resolved file before importing it."))
    if endswith(lowercase(String(path)),".gz")||(length(bytes)>1&&bytes[1]==0x1f&&bytes[2]==0x8b)
        bytes=CodecZlib.transcode(CodecZlib.GzipDecompressor,bytes)
    end
    text=String(bytes);isvalid(text)||throw(ArgumentError("Input is not valid UTF-8 text: $path"));return text
end

"""Parse an Abaqus input string, resolving INCLUDEs through an explicit callback.

`include_resolver(requested, containing)` returns text or `(path=...,text=...)`.
The returned `expanded_source` is portable and needs no original INCLUDE files.
Unknown mechanical/geometry keywords throw by default; `strict=false` retains
blocking diagnostics for a read-only inspection. Units are kept unchanged.
"""
function abaqus_parse_input(text::AbstractString;source_path::AbstractString="model.inp",include_resolver=nothing,strict::Bool=true)
    doc=Dict{String,Any}("format"=>"abaqus-input-1","nodes"=>Dict{String,Any}(),"elements"=>Dict{String,Any}(),
        "node_sets"=>Dict{String,Any}(),"element_sets"=>Dict{String,Any}(),"surfaces"=>Dict{String,Any}(),
        "materials"=>Dict{String,Any}(),"sections"=>Any[],"steps"=>Any[],"boundaries"=>Any[],
        "diagnostics"=>Any[],"source_files"=>Any[],"source_path"=>String(source_path),"units"=>"Consistent source units; no conversion")
    expanded=String[];active=Set{String}();seen=Set{String}()
    function expand(source,path,depth=0)
        depth<=32||throw(ArgumentError("Input INCLUDE nesting exceeds 32 levels"))
        isvalid(source)&&!occursin('\0',source)||throw(ArgumentError("Input is not valid text: $path"))
        identity=normpath(String(path));identity in active&&throw(ArgumentError("Cyclic input INCLUDE: $path"));push!(active,identity)
        if !(identity in seen)
            push!(doc["source_files"],Dict("path"=>identity,"sha256"=>bytes2hex(SHA.sha256(source)),"bytes"=>sizeof(source)));push!(seen,identity)
        end
        for line in split(replace(source,r"^\ufeff"=>""),'\n')
            clean=strip(line)
            if startswith(uppercase(clean),"*INCLUDE")&&!startswith(clean,"**")
                keyword,opts=_abaqus_header(clean)
                keyword=="INCLUDE"||throw(ArgumentError("Invalid INCLUDE keyword at $path"))
                Set(keys(opts))==Set(["INPUT"])||throw(ArgumentError("*INCLUDE requires only INPUT=filename"))
                include_resolver===nothing&&throw(ArgumentError("*INCLUDE $(opts["INPUT"]) requires an include_resolver or abaqus_read_input"))
                requested=strip(opts["INPUT"],['\"','\'']);result=include_resolver(requested,identity)
                child=result isa AbstractString ? (path=normpath(joinpath(dirname(identity),requested)),text=result) : result
                hasproperty(child,:path)&&hasproperty(child,:text)||throw(ArgumentError("INCLUDE resolver must return text or (path=...,text=...)"))
                expand(String(child.text),String(child.path),depth+1)
            else
                push!(expanded,String(line))
            end
        end
        delete!(active,identity)
    end
    expand(String(text),String(source_path))
    doc["expanded_source"]=join(expanded,'\n')*"\n"
    blocks=Any[];current=nothing
    line_number=0
    while line_number<length(expanded)
        line_number+=1;clean=strip(expanded[line_number]);(isempty(clean)||startswith(clean,"**"))&&continue
        if startswith(clean,"*")
            while endswith(clean,',')&&line_number<length(expanded)
                following=strip(expanded[line_number+1]);startswith(following,"*")&&break
                (occursin('=',following)||_abaqus_name(following) in ("GENERATE","UNSORTED","PERTURBATION"))||break
                clean*=following;line_number+=1
            end
            keyword,opts=_abaqus_header(clean);current=Dict{String,Any}("keyword"=>keyword,"options"=>opts,"rows"=>Any[],"line"=>line_number);push!(blocks,current)
        else
            current===nothing&&throw(ArgumentError("Data before first keyword at expanded line $line_number"))
            push!(current["rows"],_abaqus_fields(clean))
        end
    end
    node_defs=Dict{String,Any}();element_defs=Dict{String,Any}();material=nothing;step=nothing
    addset!(definitions,name,values)=append!(get!(definitions,_abaqus_name(name),Any[]),values)
    for block in blocks
        key,opts,rows=block["keyword"],block["options"],block["rows"]
        context="*$key at expanded line $(block["line"])"
        allowed=key=="NODE" ? Set(["NSET","SYSTEM"]) : key=="ELEMENT" ? Set(["TYPE","ELSET"]) : nothing
        allowed!==nothing&&!issubset(Set(keys(opts)),allowed)&&_abaqus_unsupported!(doc,"$context has unsupported options $(join(setdiff(Set(keys(opts)),allowed),", "))",strict;keyword=key)
        if key=="NODE"
            get(opts,"SYSTEM","R")=="R"||throw(ArgumentError("$context supports rectangular coordinates only"))
            for row in rows
                2<=length(row)<=4||throw(ArgumentError("$context needs node ID and 1 to 3 coordinates"))
                id=_abaqus_number(row[1],"node ID";integer=true,positive=true);name=string(id)
                haskey(doc["nodes"],name)&&throw(ArgumentError("Duplicate node label $id"))
                xyz=Float64[isempty(v) ? 0. : _abaqus_number(v,"node $id coordinate") for v in row[2:end]];append!(xyz,zeros(3-length(xyz)));doc["nodes"][name]=xyz
                haskey(opts,"NSET")&&addset!(node_defs,opts["NSET"],[id])
            end
        elseif key=="ELEMENT"
            type=_abaqus_name(get(opts,"TYPE",""));haskey(ABAQUS_ELEMENT_NODES,type)||throw(ArgumentError("$context has unknown element TYPE=$type; connectivity cannot be guessed"))
            needed=ABAQUS_ELEMENT_NODES[type]+1;buffer=String[]
            for row in rows
                append!(buffer,filter(!isempty,row));length(buffer)>needed&&throw(ArgumentError("$context: $type needs exactly $(needed-1) nodes per element"))
                if length(buffer)==needed
                    values=[_abaqus_number(v,"$type connectivity";integer=true,positive=true) for v in buffer];id=first(values);name=string(id)
                    haskey(doc["elements"],name)&&throw(ArgumentError("Duplicate element label $id"))
                    doc["elements"][name]=Dict{String,Any}("id"=>id,"type"=>type,"nodes"=>values[2:end]);empty!(buffer)
                    haskey(opts,"ELSET")&&addset!(element_defs,opts["ELSET"],[id])
                end
            end
            isempty(buffer)||throw(ArgumentError("$context ends with an incomplete $type element"))
            haskey(ABAQUS_NATIVE_ELEMENTS,type)||_abaqus_diagnostic!(doc,"error","unsupported_element","$type topology is retained; its element formulation is unavailable for analysis";element_type=type)
        elseif key in ("NSET","ELSET")
            kind=key=="NSET" ? node_defs : element_defs;name=get(opts,key,"");isempty(name)&&throw(ArgumentError("$context requires $key=name"))
            permitted=key=="NSET" ? Set(["NSET","GENERATE","UNSORTED","ELSET"]) : Set(["ELSET","GENERATE","UNSORTED"])
            issubset(Set(keys(opts)),permitted)||_abaqus_unsupported!(doc,"$context has unsupported set options",strict;keyword=key)
            if key=="NSET"&&haskey(opts,"ELSET")
                isempty(rows)||throw(ArgumentError("$context NSET from ELSET does not take data"))
                haskey(opts,"GENERATE")&&throw(ArgumentError("$context ELSET and GENERATE are mutually exclusive"))
                source=_abaqus_name(opts["ELSET"]);haskey(element_defs,source)||throw(ArgumentError("$context references undefined or forward element set $source; only previously defined sets are available"))
                # The source set is a snapshot at this keyword, not a live
                # reference that grows when a later ELSET adds more elements.
                values=Int[]
                for eid in element_defs[source]
                    haskey(doc["elements"],string(eid))||throw(ArgumentError("$context references element $eid before its definition"))
                    append!(values,doc["elements"][string(eid)]["nodes"])
                end
                addset!(kind,name,values)
            elseif haskey(opts,"GENERATE")
                for row in rows
                    values=filter(!isempty,row);2<=length(values)<=3||throw(ArgumentError("$context GENERATE needs first,last[,increment]"))
                    a,b=(_abaqus_number(values[i],"set range";integer=true,positive=true) for i in 1:2);inc=length(values)==3 ? _abaqus_number(values[3],"set increment";integer=true,positive=true) : 1
                    b>=a||throw(ArgumentError("$context GENERATE range must ascend"));(b-a)%inc==0||throw(ArgumentError("$context GENERATE increment must divide the first-to-last label difference"));addset!(kind,name,collect(a:inc:b))
                end
            else
                values=Int[]
                for row in rows,token in row
                    isempty(token)&&continue
                    if tryparse(Int,token)!==nothing
                        push!(values,_abaqus_number(token,"set member";integer=true,positive=true))
                    else
                        source=_abaqus_name(token);haskey(kind,source)||throw(ArgumentError("$context references undefined or forward set $source; only previously defined sets are available"))
                        append!(values,kind[source])
                    end
                end
                addset!(kind,name,values)
            end
        elseif key=="SURFACE"
            name=_abaqus_name(get(opts,"NAME",""));isempty(name)&&throw(ArgumentError("$context needs NAME"));type=_abaqus_name(get(opts,"TYPE","ELEMENT"))
            type in ("ELEMENT","NODE")||throw(ArgumentError("$context supports ELEMENT or NODE surfaces"))
            issubset(Set(keys(opts)),Set(["NAME","TYPE"]))||_abaqus_unsupported!(doc,"$context has unsupported surface options",strict;keyword=key)
            surface=get!(doc["surfaces"],name,Dict{String,Any}("type"=>type,"entries"=>Any[]));surface["type"]==type||throw(ArgumentError("Surface $name changes type"))
            for row in rows
                1<=length(row)<=2||throw(ArgumentError("$context has an invalid surface row"));target=_abaqus_name(row[1]);isempty(target)&&throw(ArgumentError("$context needs a target"))
                face=type=="ELEMENT" ? (length(row)==2 ? _abaqus_name(row[2]) : "") : ""
                type=="ELEMENT"&&!occursin(r"^(S[1-6]|SPOS|SNEG)$",face)&&throw(ArgumentError("$context needs face S1..S6, SPOS or SNEG"))
                push!(surface["entries"],Dict{String,Any}("set_or_id"=>target,"face"=>face,"weight"=>type=="NODE"&&length(row)==2&&!isempty(row[2]) ? _abaqus_number(row[2],"surface weight") : 1.))
            end
        elseif key=="MATERIAL"
            Set(keys(opts))==Set(["NAME"])||_abaqus_unsupported!(doc,"$context requires only NAME",strict;keyword=key)
            name=_abaqus_name(get(opts,"NAME",""));isempty(name)&&throw(ArgumentError("$context requires NAME"));haskey(doc["materials"],name)&&throw(ArgumentError("Duplicate material $name"))
            material=Dict{String,Any}();doc["materials"][name]=material
        elseif key=="ELASTIC"
            material===nothing&&throw(ArgumentError("$context needs a preceding MATERIAL"))
            (issubset(Set(keys(opts)),Set(["TYPE"]))&&_abaqus_name(get(opts,"TYPE","ISOTROPIC"))=="ISOTROPIC")||_abaqus_unsupported!(doc,"$context supports isotropic temperature-independent elasticity only",strict;keyword=key)
            length(rows)==1&&length(rows[1])==2||throw(ArgumentError("$context requires one E,nu row; temperature/field dependence is unavailable"))
            E,nu=(_abaqus_number(v,"elastic constant") for v in rows[1]);E>0&&-1<nu<.5||throw(ArgumentError("$context requires E>0 and -1<nu<0.5"))
            material["elastic"]=Dict("type"=>"ISOTROPIC","E"=>E,"nu"=>nu)
        elseif key=="DENSITY"
            material===nothing&&throw(ArgumentError("$context needs a preceding MATERIAL"));isempty(opts)||_abaqus_unsupported!(doc,"$context has unsupported density options",strict;keyword=key)
            length(rows)==1&&length(rows[1])==1||throw(ArgumentError("$context requires one constant density"));rho=_abaqus_number(rows[1][1],"density");rho>=0||throw(ArgumentError("Density cannot be negative"));material["density"]=rho
        elseif key in ("SOLID SECTION","SHELL SECTION")
            issubset(Set(keys(opts)),Set(["ELSET","MATERIAL"]))||_abaqus_unsupported!(doc,"$context has unsupported section options (orientation, offsets and composites require explicit implementation)",strict;keyword=key)
            section=Dict{String,Any}("type"=>key=="SOLID SECTION" ? "SOLID" : "SHELL","elset"=>_abaqus_name(get(opts,"ELSET","")),"material"=>_abaqus_name(get(opts,"MATERIAL","")))
            isempty(section["elset"])||isempty(section["material"]) ? throw(ArgumentError("$context requires ELSET and MATERIAL")) : nothing
            values=Any[v for row in rows for v in row if !isempty(v)]
            if key=="SHELL SECTION"
                length(values)==1||throw(ArgumentError("$context supports a uniform thickness only"));section["thickness"]=_abaqus_number(only(values),"shell thickness";positive=true)
            else
                isempty(values)||throw(ArgumentError("$context 3-D solid section takes no numerical section data"))
            end
            push!(doc["sections"],section)
        elseif key=="STEP"
            step===nothing||throw(ArgumentError("Nested STEP definitions are invalid"));issubset(Set(keys(opts)),Set(["NAME","NLGEOM","INC","PERTURBATION"]))||_abaqus_unsupported!(doc,"$context has unsupported step options",strict;keyword=key)
            nl=_abaqus_name(get(opts,"NLGEOM","NO"));nl in ("YES","NO")||throw(ArgumentError("STEP NLGEOM must be YES or NO"))
            step=Dict{String,Any}("name"=>get(opts,"NAME","Step $(length(doc["steps"])+1)"),"procedure"=>"","nlgeom"=>nl=="YES","perturbation"=>haskey(opts,"PERTURBATION"),"boundaries"=>Any[],"cloads"=>Any[],"dloads"=>Any[]);push!(doc["steps"],step)
        elseif key=="END STEP"
            step===nothing&&throw(ArgumentError("END STEP without STEP"));step=nothing
        elseif key=="STATIC"
            step===nothing&&throw(ArgumentError("STATIC requires STEP"));isempty(step["procedure"])||throw(ArgumentError("A step has more than one procedure"));step["procedure"]="STATIC"
            isempty(opts)||_abaqus_unsupported!(doc,"$context supports ordinary static analysis only",strict;keyword=key)
            if !isempty(rows)
                length(rows)==1&&length(rows[1])<=4||throw(ArgumentError("STATIC needs at most initial,time,min,max increments"));step["static_increments"]=[isempty(v) ? nothing : _abaqus_number(v,"static increment";positive=true) for v in rows[1]]
            end
        elseif key=="FREQUENCY"
            step===nothing&&throw(ArgumentError("FREQUENCY requires STEP"));isempty(step["procedure"])||throw(ArgumentError("A step has more than one procedure"));step["procedure"]="FREQUENCY"
            issubset(Set(keys(opts)),Set(["EIGENSOLVER","NORMALIZATION","SIM"]))||_abaqus_unsupported!(doc,"$context has unsupported frequency options",strict;keyword=key)
            _abaqus_name(get(opts,"EIGENSOLVER","LANCZOS"))=="LANCZOS"||_abaqus_unsupported!(doc,"$context currently supports the Lanczos frequency data convention only",strict;keyword=key)
            sim=_abaqus_name(get(opts,"SIM","YES"));sim in ("YES","NO")||throw(ArgumentError("FREQUENCY SIM must be YES or NO"))
            normalization=_abaqus_name(get(opts,"NORMALIZATION",sim=="YES" ? "MASS" : "DISPLACEMENT"));normalization in ("MASS","DISPLACEMENT")||throw(ArgumentError("Unsupported frequency normalization $normalization"))
            length(rows)==1&&1<=length(rows[1])<=3||throw(ArgumentError("FREQUENCY needs number[,lower cycles/time,upper cycles/time]"));row=rows[1]
            step["frequency"]=Dict{String,Any}("modes"=>_abaqus_number(row[1],"number of modes";integer=true,positive=true),"lower"=>length(row)>=2&&!isempty(row[2]) ? _abaqus_number(row[2],"lower frequency") : nothing,"upper"=>length(row)>=3&&!isempty(row[3]) ? _abaqus_number(row[3],"upper frequency") : nothing,"normalization"=>normalization)
        elseif key=="BOUNDARY"
            issubset(Set(keys(opts)),Set(["OP"]))||_abaqus_unsupported!(doc,"$context has unsupported boundary options",strict;keyword=key)
            op=_abaqus_name(get(opts,"OP","MOD"));op in ("MOD","NEW")||throw(ArgumentError("BOUNDARY OP must be MOD or NEW"))
            target=step===nothing ? doc["boundaries"] : step["boundaries"]
            isempty(rows)&&op=="NEW"&&push!(target,Dict{String,Any}("clear"=>true,"op"=>"NEW"))
            for (ri,row) in enumerate(rows)
                2<=length(row)<=4||throw(ArgumentError("BOUNDARY requires target,first DOF[,last DOF,value]"))
                symbolic=Dict("ENCASTRE"=>collect(1:6),"PINNED"=>collect(1:3),"XSYMM"=>[1,5,6],"YSYMM"=>[2,4,6],"ZSYMM"=>[3,4,5]);label=_abaqus_name(row[2])
                dofs=if haskey(symbolic,label)
                    length(row)==2||throw(ArgumentError("Symbolic BOUNDARY takes no extra fields"));symbolic[label]
                else
                    first=_abaqus_number(row[2],"boundary first DOF";integer=true,positive=true);last=length(row)>=3&&!isempty(row[3]) ? _abaqus_number(row[3],"boundary last DOF";integer=true,positive=true) : first
                    1<=first<=last<=6||throw(ArgumentError("Mechanical boundary DOFs must be 1..6"));collect(first:last)
                end
                value=length(row)==4&&!isempty(row[4]) ? _abaqus_number(row[4],"boundary displacement") : 0.
                push!(target,Dict{String,Any}("target"=>_abaqus_name(row[1]),"dofs"=>dofs,"value"=>value,"op"=>ri==1 ? op : "MOD"))
            end
        elseif key in ("CLOAD","DLOAD","DSLOAD")
            step===nothing&&throw(ArgumentError("$key must occur within STEP"));issubset(Set(keys(opts)),Set(["OP"]))||_abaqus_unsupported!(doc,"$context has unsupported load options (amplitudes/follower laws cannot be discarded)",strict;keyword=key)
            op=_abaqus_name(get(opts,"OP","MOD"));op in ("MOD","NEW")||throw(ArgumentError("$key OP must be MOD or NEW"))
            isempty(rows)&&op=="NEW"&&push!(step[key=="CLOAD" ? "cloads" : "dloads"],Dict{String,Any}("clear"=>true,"op"=>"NEW","surface"=>key=="DSLOAD"))
            for (ri,row) in enumerate(rows)
                length(row)>=3||throw(ArgumentError("$context needs a target,component/type,value"))
                load=Dict{String,Any}("target"=>_abaqus_name(row[1]),"value"=>_abaqus_number(row[3],"load value"),"op"=>ri==1 ? op : "MOD")
                if key=="CLOAD"
                    length(row)==3||throw(ArgumentError("CLOAD requires target,DOF,value"));dof=_abaqus_number(row[2],"load DOF";integer=true,positive=true);dof<=6||throw(ArgumentError("CLOAD DOF must be 1..6"));load["dof"]=dof;push!(step["cloads"],load)
                else
                    load["type"]=_abaqus_name(row[2]);load["surface"]=key=="DSLOAD"
                    if load["type"]=="GRAV"
                        length(row)==6||throw(ArgumentError("DLOAD GRAV requires magnitude and 3 direction components"));load["direction"]=[_abaqus_number(v,"gravity direction") for v in row[4:6]]
                    else
                        length(row)==3||throw(ArgumentError("Pressure DLOAD requires target,Pn,value"))
                    end
                    push!(step["dloads"],load)
                end
            end
        elseif key=="RESTART"
            # READ supplies a previous model/history, rather than an output
            # request. Its state cannot be replaced with a fresh linear solve.
            if haskey(opts,"READ")||!haskey(opts,"WRITE")
                _abaqus_unsupported!(doc,"$context requires unsupported restart/model history; only RESTART,WRITE output requests may be ignored",strict;keyword=key)
            else
                _abaqus_diagnostic!(doc,"info","output_keyword","*RESTART,WRITE is retained in source; JFEM export controls choose its own result files";keyword=key)
            end
        elseif key in ABAQUS_NONMECHANICAL
            _abaqus_diagnostic!(doc,"info","output_keyword","*$key is retained in source; JFEM export controls choose its own result files";keyword=key)
        else
            _abaqus_unsupported!(doc,"$context is unsupported; its mechanics or geometry will not be silently ignored",strict;keyword=key)
        end
    end
    step===nothing||throw(ArgumentError("STEP has no END STEP"))
    for (id,element) in doc["elements"]
        all(n->haskey(doc["nodes"],string(n)),element["nodes"])||throw(ArgumentError("Element $id references an undefined node"))
        length(unique(element["nodes"]))==length(element["nodes"])||throw(ArgumentError("Element $id repeats a node"))
    end
    function resolve_sets(defs,entities;nodes=false)
        resolved=Dict{String,Any}();visiting=Set{String}()
        function one(name)
            haskey(resolved,name)&&return resolved[name];name in visiting&&throw(ArgumentError("Cyclic set reference $name"));haskey(defs,name)||throw(ArgumentError("Undefined set $name"));push!(visiting,name);values=Int[]
            for token in defs[name]
                if token isa Integer
                    haskey(entities,string(token))||throw(ArgumentError("Set $name references undefined label $token"));push!(values,token)
                elseif token isa AbstractDict
                    elset=get(doc["element_sets"],token["elset"],nothing);elset===nothing&&throw(ArgumentError("Undefined element set $(token["elset"])"))
                    append!(values,Int[n for eid in elset for n in doc["elements"][string(eid)]["nodes"]])
                else
                    append!(values,one(token))
                end
            end
            delete!(visiting,name);resolved[name]=sort!(unique(values));return resolved[name]
        end
        for name in keys(defs);one(name);end
        return resolved
    end
    doc["element_sets"]=resolve_sets(element_defs,doc["elements"]);doc["node_sets"]=resolve_sets(node_defs,doc["nodes"];nodes=true)
    used=Set(n for el in values(doc["elements"]) for n in el["nodes"])
    unused=sort!(Int[parse(Int,id) for id in keys(doc["nodes"]) if !(parse(Int,id) in used)])
    counts=Dict{String,Int}();for el in values(doc["elements"]);counts[el["type"]]=get(counts,el["type"],0)+1;end
    doc["inventory"]=Dict{String,Any}("node_count"=>length(doc["nodes"]),"element_count"=>length(doc["elements"]),
        "element_types"=>counts,"unused_node_ids"=>unused,"node_set_count"=>length(doc["node_sets"]),"element_set_count"=>length(doc["element_sets"]),
        "surface_count"=>length(doc["surfaces"]),"material_count"=>length(doc["materials"]),"section_count"=>length(doc["sections"]),"step_count"=>length(doc["steps"]))
    isempty(unused)||_abaqus_diagnostic!(doc,"info","unused_nodes","$(length(unused)) input nodes are not referenced by any element; their labels are retained";node_ids=unused)
    doc["analysis_assessment"]="Use abaqus_to_raw_model or abaqus_to_model to assess executable mechanics"
    return doc
end

"""Read .inp or gzip-compressed .inp.gz with relative INCLUDE resolution."""
function abaqus_read_input(path::AbstractString;strict::Bool=true)
    filename=abspath(path);isfile(filename)||throw(ArgumentError("Input file does not exist: $path"))
    resolver=(requested,containing)->begin
        child=normpath(joinpath(dirname(containing),requested));isfile(child)||throw(ArgumentError("Input INCLUDE file does not exist: $child"));(path=child,text=_abaqus_read_text(child))
    end
    doc=abaqus_parse_input(_abaqus_read_text(filename);source_path=filename,include_resolver=resolver,strict)
    doc["container_sha256"]=bytes2hex(SHA.sha256(read(filename)));return doc
end

function _abaqus_selection(target,sets,entities;label="selection")
    name=_abaqus_name(target);id=tryparse(Int,name)
    values=id===nothing ? (haskey(sets,name) ? Int.(sets[name]) : name=="ALL" ? sort!(parse.(Int,collect(keys(entities)))) : throw(ArgumentError("Undefined $label $target"))) : [id]
    all(n->haskey(entities,string(n)),values)||throw(ArgumentError("$label $target contains an undefined label"))
    isempty(values)&&throw(ArgumentError("$label $target is empty"));return values
end

"""Resolve Abaqus element face labels, preserving quadratic face nodes."""
function abaqus_element_face(element::AbstractDict,face::AbstractString)
    type=element["type"];label=_abaqus_name(face);index=tryparse(Int,replace(label,r"^S"=>""))
    faces=if type in ("C3D4","C3D10","C3D10M","C3D10H")
        length(element["nodes"])==10 ? ([1,2,3,5,6,7],[1,4,2,8,9,5],[2,4,3,9,10,6],[3,4,1,10,8,7]) : ([1,2,3],[1,4,2],[2,4,3],[3,4,1])
    elseif startswith(type,"C3D8")||startswith(type,"C3D20")
        length(element["nodes"])>8&&throw(ArgumentError("Quadratic brick faces are not yet implemented"))
        ([1,2,3,4],[5,8,7,6],[1,5,6,2],[2,6,7,3],[3,7,8,4],[4,8,5,1])
    elseif type=="C3D6"
        ([1,2,3],[4,6,5],[1,4,5,2],[2,5,6,3],[3,6,4,1])
    elseif type in ("S3","S4")&&label in ("SPOS","SNEG")
        return label=="SPOS" ? copy(element["nodes"]) : reverse(element["nodes"])
    else
        throw(ArgumentError("Surface faces for $type are unavailable"))
    end
    index!==nothing&&1<=index<=length(faces)||throw(ArgumentError("Element $(element["id"]) $type has no face $label"))
    return element["nodes"][faces[index]]
end

function _abaqus_face_pressure!(forces,doc,eid,face,pressure)
    el=doc["elements"][string(eid)];nids=abaqus_element_face(el,face);xyz=[Float64.(doc["nodes"][string(n)]) for n in nids]
    center=sum(Float64.(doc["nodes"][string(n)]) for n in el["nodes"])/length(el["nodes"])
    centroid=sum(xyz)/length(xyz);corner_count=length(nids)==6 ? 3 : length(nids)
    cross3(a,b)=[a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]]
    normal=cross3(xyz[2]-xyz[1],xyz[3]-xyz[1]);sum(abs2,normal)>0||throw(ArgumentError("Pressure face is collapsed on element $eid"))
    orientation=sum(normal.*(centroid-center))>=0 ? 1. : -1.
    if startswith(el["type"],"S")
        orientation=1. # shell SPOS/SNEG order explicitly defines the face normal
    end
    # Three-point triangle integration exactly integrates quadratic shape
    # functions on a planar face. Curved TET10 pressure needs a higher-order
    # surface rule and is rejected, rather than silently linearized.
    if length(nids)==6
        for (mid,(a,b)) in enumerate(((1,2),(2,3),(3,1)))
            normerr=sqrt(sum(abs2,xyz[mid+3]-(xyz[a]+xyz[b])/2));scale=maximum(sqrt(sum(abs2,p-xyz[1])) for p in xyz)
            normerr<=1e-9*scale||throw(ArgumentError("Pressure on curved C3D10 face $eid is unavailable; no midside nodes may be discarded"))
        end
    end
    if corner_count==3
        for (r,s) in ((1/6,1/6),(2/3,1/6),(1/6,2/3))
            L=1-r-s;N=length(nids)==6 ? [L*(2L-1),r*(2r-1),s*(2s-1),4L*r,4r*s,4s*L] : [L,r,s]
            for (j,nid) in enumerate(nids);get!(forces,nid,zeros(6))[1:3].+=(-pressure*orientation/6*N[j]).*normal;end
        end
    elseif corner_count==4
        for r in (-1/sqrt(3),1/sqrt(3)),s in (-1/sqrt(3),1/sqrt(3))
            N=[(1-r)*(1-s),(1+r)*(1-s),(1+r)*(1+s),(1-r)*(1+s)]./4
            dr=[-(1-s),(1-s),(1+s),-(1+s)]./4;ds=[-(1-r),-(1+r),(1+r),(1-r)]./4
            jac=cross3(sum(dr[j]*xyz[j] for j in 1:4),sum(ds[j]*xyz[j] for j in 1:4))
            for (j,nid) in enumerate(nids);get!(forces,nid,zeros(6))[1:3].+=(-pressure*orientation*N[j]).*jac;end
        end
    else
        throw(ArgumentError("Unsupported pressure face node count $(length(nids))"))
    end
end

"""Translate a parsed document to JFEM's raw JSON model schema.

Mesh-only conversion (`require_analysis=false`) leaves unassigned PID=0 and no
invented material. Such models carry a blocking readiness flag in to_model.
Only flat, isotropic, small-displacement STATIC and unprestressed FREQUENCY
procedures are currently executable. Input labels and all C3D10 nodes survive.
"""
function abaqus_to_raw_model(doc::AbstractDict;require_analysis::Bool=true)
    get(doc,"format",nothing)=="abaqus-input-1"||throw(ArgumentError("Not a parsed Abaqus input document"))
    nodes,elements=doc["nodes"],doc["elements"];isempty(nodes)&&throw(ArgumentError("Input has no nodes"));isempty(elements)&&throw(ArgumentError("Input has no elements"))
    diagnostics=deepcopy(get(doc,"diagnostics",Any[]));missing=String[];bd=Dict{String,Any}();cc=Dict{String,Any}("SUBCASES"=>Dict{Int,Any}())
    bd["GRID"]=Dict{String,Any}(id=>Dict{String,Any}("ID"=>parse(Int,id),"X"=>Float64.(xyz),"CP"=>0,"CD"=>0,"PS"=>"","SEID"=>0) for (id,xyz) in nodes)
    mids=Dict(name=>i for (i,name) in enumerate(sort!(collect(keys(doc["materials"])))));bd["MAT1"]=Dict{String,Any}()
    for (name,mat) in doc["materials"]
        elastic=get(mat,"elastic",nothing)
        if elastic===nothing;push!(missing,"Material $name has no elastic constants");continue;end
        E,nu=Float64(elastic["E"]),Float64(elastic["nu"]);rho=Float64(get(mat,"density",0.))
        E>0&&-1<nu<.5&&rho>=0&&all(isfinite,(E,nu,rho))||throw(ArgumentError("Invalid material $name"))
        mid=mids[name];bd["MAT1"][string(mid)]=Dict("MID"=>mid,"E"=>E,"G"=>E/(2*(1+nu)),"NU"=>nu,"RHO"=>rho)
    end
    assignments=Dict{Int,Int}();bd["PSOLID"]=Dict{String,Any}();bd["PSHELL"]=Dict{String,Any}()
    for (pid,section) in enumerate(doc["sections"])
        name=_abaqus_name(section["material"])
        if !haskey(mids,name)||!haskey(bd["MAT1"],string(mids[name]));push!(missing,"Section $pid references undefined/incomplete material $name");continue;end
        ids=_abaqus_selection(section["elset"],doc["element_sets"],elements;label="section element set");kind=uppercase(section["type"])
        for id in ids
            haskey(assignments,id)&&throw(ArgumentError("Element $id has overlapping section assignments"));assignments[id]=pid
            type=elements[string(id)]["type"];(kind=="SOLID"&&startswith(type,"C3D")||kind=="SHELL"&&type in ("S3","S4"))||throw(ArgumentError("Section $pid does not match $type element $id"))
        end
        if kind=="SOLID"
            bd["PSOLID"][string(pid)]=Dict("PID"=>pid,"MID"=>mids[name])
        elseif kind=="SHELL"
            t=Float64(section["thickness"]);t>0&&isfinite(t)||throw(ArgumentError("Shell thickness must be positive"))
            bd["PSHELL"][string(pid)]=Dict("PID"=>pid,"MID"=>mids[name],"MID2"=>mids[name],"MID3"=>mids[name],"T"=>t,"BEND_RATIO"=>1.,"TS_T"=>5/6)
        end
    end
    unassigned=Int[]
    for (id,el) in elements
        type=el["type"];native=get(ABAQUS_NATIVE_ELEMENTS,type,nothing)
        if native===nothing
            # Retain unsupported topology in metadata/IR; do not disguise a
            # reduced/hybrid/plane-strain element as a supported formulation.
            continue
        end
        eid=Int(el["id"]);pid=get(assignments,eid,0);pid==0&&push!(unassigned,eid)
        get!(bd,native,Dict{String,Any}())[id]=Dict{String,Any}("ID"=>eid,"PID"=>pid,"NODES"=>Int.(el["nodes"]),"TYPE"=>native,"ABAQUS_TYPE"=>type)
    end
    isempty(unassigned)||push!(missing,"$(length(unassigned)) elements have no material/section assignment")
    steps=doc["steps"];isempty(steps)&&push!(missing,"No analysis STEP/procedure is defined")
    procedures=unique([get(step,"procedure","") for step in steps]);length(procedures)>1&&push!(missing,"Mixed analysis procedures require separate explicitly defined models; prestress/history cannot be discarded")
    any(step->get(step,"nlgeom",false),steps)&&push!(missing,"NLGEOM=YES finite-kinematics analysis is not implemented by this input translator")
    any(step->get(step,"perturbation",false)&&get(step,"procedure","")=="STATIC",steps)&&push!(missing,"Static perturbation/base-state analysis is unavailable; no prior state may be discarded")
    any(p->!(p in ("STATIC","FREQUENCY")),procedures)&&push!(missing,"A step has no supported STATIC or FREQUENCY procedure")
    bd["SPC1"]=Any[];bd["FORCE"]=Any[];bd["MOMENT"]=Any[];bd["GRAV"]=Any[];bd["EIGRL"]=Dict{String,Any}()
    boundaries=Dict{Tuple{Int,Int},Float64}();cloads=Dict{Tuple{Int,Int},Float64}();dloads=Dict{String,Any}()
    # Continuum nodes have translations only. Native six-DOF storage must not
    # turn a source moment/rotation into an artificial AUTOSPC reaction/motion.
    # A node shared with a shell can legitimately carry rotational DOFs.
    solid_only_nodes=Set{Int}();other_nodes=Set{Int}()
    for element in values(elements)
        union!(startswith(element["type"],"C3D") ? solid_only_nodes : other_nodes,Int.(element["nodes"]))
    end
    setdiff!(solid_only_nodes,other_nodes)
    function validate_solid_rotation(nid,dof,value,label)
        dof>3&&!iszero(value)&&nid in solid_only_nodes&&throw(ArgumentError("$label applies nonzero rotational DOF $dof at solid-only node $nid; continuum elements have active DOFs 1,2,3 only"))
    end
    function apply_boundaries!(records)
        reset=false
        for row in records
            if get(row,"op","MOD")=="NEW"&&!reset;empty!(boundaries);reset=true;end
            get(row,"clear",false)&&continue
            dofs=get(row,"dofs",nothing)
            if dofs===nothing;first=Int(get(row,"first",get(row,"dof_first",1)));last=Int(get(row,"last",get(row,"dof_last",first)));dofs=collect(first:last);end
            all(d->d isa Integer&&1<=d<=6,dofs)||throw(ArgumentError("Boundary DOFs must be 1..6"))
            value=Float64(get(row,"value",0.))
            for nid in _abaqus_selection(row["target"],doc["node_sets"],nodes;label="boundary set"),dof in dofs
                validate_solid_rotation(nid,dof,value,"BOUNDARY");boundaries[(nid,dof)]=value
            end
        end
    end
    apply_boundaries!(get(doc,"boundaries",Any[]))
    for (sid,step) in enumerate(steps)
        apply_boundaries!(get(step,"boundaries",Any[]));proc=get(step,"procedure","")
        sub=Dict{String,Any}("LABEL"=>get(step,"name","Step $sid"),"SPC"=>sid,"LOAD"=>sid)
        for ((nid,dof),value) in sort!(collect(boundaries);by=first);push!(bd["SPC1"],Dict("SID"=>sid,"C"=>string(dof),"NODES"=>[nid],"D"=>value));end
        proc=="STATIC"&&isempty(boundaries)&&push!(missing,"Static step $sid has no boundary constraints")
        reset_cloads=false;new_cloads=Set{Tuple{Int,Int}}()
        for load in get(step,"cloads",Any[])
            if get(load,"op","MOD")=="NEW"&&!reset_cloads;empty!(cloads);reset_cloads=true;end
            get(load,"clear",false)&&continue
            for nid in _abaqus_selection(load["target"],doc["node_sets"],nodes;label="load set")
                dof=Int(load["dof"]);value=Float64(load["value"]);validate_solid_rotation(nid,dof,value,"CLOAD")
                (nid,dof) in new_cloads&&throw(ArgumentError("Repeated CLOAD on node $nid DOF $dof in one step must be combined explicitly"));push!(new_cloads,(nid,dof));cloads[(nid,dof)]=value
            end
        end
        reset_dloads=Set{Bool}()
        for load in get(step,"dloads",Any[])
            surface=Bool(get(load,"surface",false))
            if get(load,"op","MOD")=="NEW"&&!(surface in reset_dloads)
                # DLOAD and DSLOAD have independent OP=NEW histories. Clearing
                # surface pressure must preserve an inherited body gravity load.
                for (key,previous) in collect(dloads)
                    Bool(get(previous,"surface",false))==surface&&delete!(dloads,key)
                end
                push!(reset_dloads,surface)
            end
            get(load,"clear",false)&&continue
            dloads[string(load["target"],"|",load["type"],"|",get(load,"surface",false))]=load
        end
        forces=Dict{Int,Vector{Float64}}()
        for ((nid,dof),value) in cloads;get!(forces,nid,zeros(6))[dof]+=value;end
        for load in values(dloads)
            type=load["type"];value=Float64(load["value"])
            if type=="GRAV"
                ids=_abaqus_selection(load["target"],doc["element_sets"],elements;label="gravity element set")
                if Set(ids)!=Set(parse.(Int,collect(keys(elements))));push!(missing,"Element-set-limited GRAV is unavailable; global gravity must select all elements");continue;end
                dir=Float64.(load["direction"]);length(dir)==3&&sum(abs2,dir)>0||throw(ArgumentError("Gravity direction must be nonzero"));dir./=sqrt(sum(abs2,dir))
                push!(bd["GRAV"],Dict("TYPE"=>"GRAV","SID"=>sid,"CID"=>0,"A"=>value,"N"=>dir))
            elseif get(load,"surface",false)
                surface=get(doc["surfaces"],_abaqus_name(load["target"]),nothing);surface===nothing&&throw(ArgumentError("Undefined pressure surface $(load["target"])"))
                surface["type"]=="ELEMENT"&&type=="P"||throw(ArgumentError("DSLOAD supports element-surface pressure P only"))
                for entry in surface["entries"],eid in _abaqus_selection(entry["set_or_id"],doc["element_sets"],elements;label="surface element set")
                    _abaqus_face_pressure!(forces,doc,eid,entry["face"],value)
                end
            elseif occursin(r"^P[1-6]$",type)
                for eid in _abaqus_selection(load["target"],doc["element_sets"],elements;label="pressure element set");_abaqus_face_pressure!(forces,doc,eid,"S"*type[2:end],value);end
            else
                push!(missing,"Unsupported distributed load $type")
            end
        end
        for (nid,vector) in sort!(collect(forces);by=first),axis in 1:6
            vector[axis]==0&&continue;direction=zeros(3);direction[axis<=3 ? axis : axis-3]=1.;kind=axis<=3 ? "FORCE" : "MOMENT"
            push!(bd[kind],Dict("TYPE"=>kind,"SID"=>sid,"GID"=>nid,"CID"=>0,"Mag"=>vector[axis],"Dir"=>direction))
        end
        if proc=="FREQUENCY"
            freq=get(step,"frequency",nothing)
            if freq===nothing;push!(missing,"Frequency step $sid has no eigenvalue request");continue;end
            any(m->!haskey(m,"density")||m["density"]<=0,values(doc["materials"]))&&push!(missing,"Frequency analysis requires positive material density")
            (!isempty(cloads)||!isempty(dloads))&&push!(missing,"Prestressed/loaded frequency extraction is unavailable; no load state may be silently discarded")
            lo,hi=get(freq,"lower",nothing),get(freq,"upper",nothing);lo!==nothing&&hi!==nothing&&hi<=lo&&throw(ArgumentError("Upper frequency must exceed lower frequency"))
            bd["EIGRL"][string(sid)]=Dict("SID"=>sid,"TYPE"=>"EIGRL","ND"=>Int(freq["modes"]),"ND_SPECIFIED"=>true,"V1"=>lo===nothing ? 0. : Float64(lo),"V2"=>hi===nothing ? 0. : Float64(hi),"V1_SPECIFIED"=>lo!==nothing,"V2_SPECIFIED"=>hi!==nothing,"NORM"=>get(freq,"normalization","MASS")=="DISPLACEMENT" ? "MAX" : "MASS")
            sub["METHOD"]=sid
        end
        cc["SUBCASES"][sid]=sub
    end
    if length(procedures)==1&&only(procedures) in ("STATIC","FREQUENCY");cc["SOL"]=only(procedures)=="FREQUENCY" ? 103 : 101;end
    for item in diagnostics;item["severity"]=="error"&&push!(missing,item["message"]);end
    unique!(missing)
    for message in missing;push!(diagnostics,Dict("severity"=>"error","code"=>"missing_or_unsupported_analysis","message"=>message));end
    metadata=Dict{String,Any}("format"=>"abaqus-input-1","analysis_ready"=>isempty(missing),"diagnostics"=>diagnostics,"missing_analysis"=>missing,
        "nsets"=>deepcopy(doc["node_sets"]),"elsets"=>deepcopy(doc["element_sets"]),"surfaces"=>deepcopy(doc["surfaces"]),
        "original_types"=>Dict(id=>el["type"] for (id,el) in elements),"source_files"=>get(doc,"source_files",Any[]),"units"=>get(doc,"units","consistent source units"),
        "unsupported_elements"=>Dict(id=>deepcopy(el) for (id,el) in elements if !haskey(ABAQUS_NATIVE_ELEMENTS,el["type"])),"material_ids"=>mids,"inventory"=>get(doc,"inventory",Dict()))
    raw=Dict{String,Any}("case_control"=>cc,"parameters"=>Dict{String,Any}("COUPMASS"=>1),"bulk_data"=>bd,"abaqus_import"=>metadata)
    require_analysis&&!isempty(missing)&&throw(ArgumentError("Input is available for mesh inspection but cannot be analyzed:\n - "*join(missing,"\n - ")))
    return raw
end

"""Build a native model; mesh-only models remain explicitly non-runnable."""
function abaqus_to_model(input;require_analysis::Bool=true,strict::Bool=true)
    doc=input isa AbstractDict ? input : abaqus_read_input(String(input);strict)
    raw=abaqus_to_raw_model(doc;require_analysis)
    model=build_model_from_json(raw);model["abaqus_import"]=raw["abaqus_import"]
    # The generic card builder historically clamps negative MAT1 Poisson
    # ratios. Preserve the validated isotropic source constants exactly here.
    for (name,mid) in raw["abaqus_import"]["material_ids"]
        mat=get(doc["materials"],name,nothing);mat===nothing&&continue;elastic=get(mat,"elastic",nothing);elastic===nothing&&continue
        entry=get(model["MATs"],string(mid),nothing);entry===nothing&&continue
        entry["E"]=Float64(elastic["E"]);entry["NU"]=Float64(elastic["nu"]);entry["G"]=entry["E"]/(2*(1+entry["NU"]))
    end
    raw["abaqus_import"]["analysis_ready"]||(model["SOL"]=0)
    return model
end

"""Append only explicitly requested homogeneous physics to an original mesh.

The returned text is reparsed by the same importer used for execution. Existing
authored materials, sections or steps are never overwritten. `total_force` is
distributed over the selected nodes, unlike an Abaqus set CLOAD's per-node value.
"""
function abaqus_complete_input(doc::AbstractDict,settings::AbstractDict)
    get(settings,"enabled",false)===true||return doc["expanded_source"]
    all(isempty,(doc["materials"],doc["sections"],doc["steps"],get(doc,"boundaries",Any[])))||throw(ArgumentError("Explicit completion is restricted to mesh-only files without authored materials, sections, constraints or steps"))
    E=_abaqus_number(get(settings,"E",nothing),"completion E";positive=true);nu=_abaqus_number(get(settings,"nu",nothing),"completion nu");rho=_abaqus_number(get(settings,"rho",nothing),"completion density");-1<nu<.5&&rho>=0||throw(ArgumentError("Completion requires -1<nu<0.5 and nonnegative density"))
    ids=_abaqus_selection(get(settings,"element_set","ALL"),doc["element_sets"],doc["elements"];label="completion element set")
    length(ids)==length(doc["elements"])||throw(ArgumentError("Homogeneous completion must assign every element; partial element sets leave unassigned physics"))
    all(id->doc["elements"][string(id)]["type"] in ("C3D4","C3D10","C3D6","C3D8"),ids)||throw(ArgumentError("Homogeneous completion currently supports solid C3D4/C3D10/C3D6/C3D8 meshes"))
    constraints=unique(_abaqus_name.(split(String(get(settings,"constraint_set","")),';')))
    all(!isempty,constraints)||throw(ArgumentError("Supply one or more constraint sets separated by semicolons"))
    for constraint in constraints;_abaqus_selection(constraint,doc["node_sets"],doc["nodes"];label="completion constraint set");end
    dofs=String(get(settings,"constraint_dofs","123"));!isempty(dofs)&&all(c->c in '1':'6',dofs)&&length(unique(dofs))==length(dofs)||throw(ArgumentError("Constraint DOFs must be distinct digits 1..6"))
    sol=string(get(settings,"solution","101"));sol in ("101","103")||throw(ArgumentError("Mesh completion supports SOL101 or SOL103"))
    reserved="JFEM_COMPLETION_ALL";haskey(doc["element_sets"],reserved)&&throw(ArgumentError("Input already uses reserved set $reserved"))
    io=IOBuffer();print(io,doc["expanded_source"]);println(io,"\n** Explicit JFEM mesh completion; consistent source units retained\n*ELSET, ELSET=$reserved")
    for i in 1:16:length(ids);println(io,join(ids[i:min(i+15,length(ids))],", "));end
    println(io,"*MATERIAL, NAME=JFEM_COMPLETION_MATERIAL\n*ELASTIC\n$E, $nu\n*DENSITY\n$rho\n*SOLID SECTION, ELSET=$reserved, MATERIAL=JFEM_COMPLETION_MATERIAL\n*BOUNDARY")
    for constraint in constraints,dof in sort!(collect(dofs));println(io,"$constraint, $dof, $dof, 0");end
    println(io,"*STEP, NAME=Explicit mesh completion")
    if sol=="103"
        rho>0||throw(ArgumentError("Modal completion requires positive density"));modes=_abaqus_number(get(settings,"modes",nothing),"completion mode count";integer=true,positive=true);println(io,"*FREQUENCY\n$modes")
    else
        force_set=_abaqus_name(get(settings,"force_set",""));load_nodes=_abaqus_selection(force_set,doc["node_sets"],doc["nodes"];label="completion force set")
        direction=get(settings,"force_direction",nothing);direction isa AbstractVector&&length(direction)==3||throw(ArgumentError("Completion needs a three-component force direction"));dir=[_abaqus_number(v,"force direction") for v in direction];lengthdir=sqrt(sum(abs2,dir));lengthdir>0||throw(ArgumentError("Force direction must be nonzero"));total=_abaqus_number(get(settings,"total_force",nothing),"total force");total!=0||throw(ArgumentError("Static completion requires a nonzero total force"));dir.*=total/(lengthdir*length(load_nodes))
        println(io,"*STATIC\n*CLOAD")
        for axis in 1:3;dir[axis]!=0&&println(io,"$force_set, $axis, $(dir[axis])");end
    end
    println(io,"*END STEP");return String(take!(io))
end
