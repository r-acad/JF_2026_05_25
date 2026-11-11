# Lossless Nastran source adapter for the FE editing utilities. Geometry is
# edited in basic coordinates, while unmodified source records stay verbatim.

struct FEEditCard
    kind::String
    fields::Vector{String}
    raw::String
end

struct FEEditDeck
    name::String
    records::Vector{FEEditCard}
    nodes::Dict{Int,NTuple{3,Float64}}
    elements::Vector{Dict{String,Any}}
end

fe_edit_int(s, default=0) = something(tryparse(Int,strip(string(s))),default)
fe_edit_field(c::FEEditCard,i,default="") = i<=length(c.fields) ? c.fields[i] : default
fe_edit_real(s,default=0.) = isempty(strip(string(s))) ? default : begin
    value=replace(strip(string(s)),r"[dD]"=>"E")
    occursin(r"^[+-]?(?:\d+\.?\d*|\.\d+)[+-]\d+$",value)&&(value=replace(value,r"(?<=[\d.])([+-]\d+)$"=>s"E\1"))
    number=tryparse(Float64,value)
    number===nothing&&throw(ArgumentError("Invalid Nastran real value $(repr(s))"))
    number
end
fe_edit_number(x::Real) = x isa Integer ? string(x) : string(Float64(x))

"""An integer X1 is a G0 reference only when X2 and X3 are both blank."""
function fe_edit_orientation_grid(c::FEEditCard)
    c.kind in ("CBAR","CBEAM","CBUSH","CGAP")||return 0
    isempty(strip(fe_edit_field(c,6)))&&isempty(strip(fe_edit_field(c,7))) ? fe_edit_int(fe_edit_field(c,5)) : 0
end

function fe_edit_beam_default(deck::FEEditDeck,c::FEEditCard)
    kind=c.kind=="CBAR" ? "BAROR" : "BEAMOR"
    rows=filter(row->row.kind==kind,deck.records)
    length(rows)>1&&throw(ArgumentError("$(c.kind) $(fe_edit_field(c,1)) has multiple $kind default records. Resolve these defaults explicitly before changing its orientation."))
    isempty(rows) ? nothing : only(rows)
end

function fe_edit_beam_offt(deck::FEEditDeck,c::FEEditCard;defaults=missing)
    value=uppercase(strip(fe_edit_field(c,8)))
    if isempty(value)
        defaults===missing&&(defaults=fe_edit_beam_default(deck,c))
        defaults===nothing||(value=uppercase(strip(fe_edit_field(defaults,8))))
    end
    isempty(value)&&(value="GGG")
    if c.kind=="CBEAM"&&tryparse(Float64,replace(value,'D'=>'E'))!==nothing
        throw(ArgumentError("CBEAM $(c.fields[1]) uses numeric BIT (p-version built-in twist), not character OFFT. Automatic G0 conversion cannot replace that twist field safely. Define its orientation explicitly while retaining the p-version formulation before editing this beam."))
    end
    value=="B"&&(value="BGG")
    length(value)==3&&first(value) in ('B','G')&&all(ch->ch in ('B','G','O','E'),value[2:end])||throw(ArgumentError("$(c.kind) $(c.fields[1]) has unsupported OFFT $(repr(value)). Define an explicit three-character OFFT before changing its G0 reference."))
    value,"B"*value[2:end]
end

"""Freeze affected G0 orientations using original BASIC points before an edit.

The first OFFT character becomes B; offset flags, offsets and releases stay
authored. This also catches stationary beams whose orientation GRID moves.
"""
function fe_edit_preserve_beam_orientations!(deck::FEEditDeck,mesh)
    nodes=mesh["nodes"];converted=Dict{String,Any}[];defaults=Dict{String,Any}()
    beamdefault(c)=get!(defaults,c.kind) do;fe_edit_beam_default(deck,c);end
    for element in mesh["elements"]
        c=fe_edit_parent_card(deck,element);c.kind in ("CBAR","CBEAM")||continue
        g0=fe_edit_orientation_grid(c);inherited=false
        if g0<=0&&all(i->isempty(strip(fe_edit_field(c,i))),5:7)
            inherited_default=beamdefault(c)
            if inherited_default!==nothing
                g0=isempty(fe_edit_field(inherited_default,6))&&isempty(fe_edit_field(inherited_default,7)) ? fe_edit_int(fe_edit_field(inherited_default,5)) : 0
                inherited=g0>0
            end
        end
        g0>0||continue
        ga=fe_edit_int(fe_edit_field(c,3));gb=fe_edit_int(fe_edit_field(c,4));original=[ga,gb];edited=Int.(element["nodes"])
        affected=Int(element["id"])!=fe_edit_int(fe_edit_field(c,1))||edited!=original
        affected=affected||any(i->collect(nodes[edited[i]])!=collect(deck.nodes[original[i]]),1:2)
        affected=affected||!haskey(nodes,g0)||collect(nodes[g0])!=collect(get(deck.nodes,g0,(NaN,NaN,NaN)))
        affected||continue
        inherited&&throw(ArgumentError("$(c.kind) $(c.fields[1]) inherits orientation GRID $g0 from $(c.kind=="CBAR" ? "BAROR" : "BEAMOR"). The current native parser does not resolve inherited G0 defaults. Put that G0 explicitly on the beam card before editing it; no geometry changes were committed."))
        haskey(deck.nodes,g0)&&haskey(deck.nodes,ga)||throw(ArgumentError("$(c.kind) $(c.fields[1]) has a missing source GA/G0 node; its orientation cannot be preserved."))
        a=collect(deck.nodes[ga]);b=collect(deck.nodes[g0]);vector=b-a;scale=maximum(abs,vector)
        isfinite(scale)&&scale>0||throw(ArgumentError("$(c.kind) $(c.fields[1]) has a zero or non-finite GA-to-G0 direction. Move its orientation GRID away from GA before editing."))
        normalized=vector/scale;scalednorm=norm(normalized);orientation_length=scale*scalednorm
        absolute=max(maximum(abs,a),maximum(abs,b),1.);resolution=64eps(absolute)
        orientation_length>=1e-6&&orientation_length>resolution||throw(ArgumentError("$(c.kind) $(c.fields[1]) has a GA-to-G0 distance of $orientation_length model units, below the reliable native orientation threshold or coordinate resolution. Move G0 farther along the same intended direction (at least $(max(1e-6,resolution)) model units) before editing; no arbitrary orientation has been substituted."))
        start=collect(deck.nodes[ga]);finish=collect(deck.nodes[gb])
        wa=[fe_edit_real(fe_edit_field(c,i)) for i in 11:13];wb=[fe_edit_real(fe_edit_field(c,i)) for i in 14:16]
        if sum(abs2,wa)>1e-20||sum(abs2,wb)>1e-20;start+=wa;finish+=wb;end
        axis=finish-start;axisscale=maximum(abs,axis)
        isfinite(axisscale)&&axisscale>0||throw(ArgumentError("$(c.kind) $(c.fields[1]) has coincident/non-finite effective ends GA $ga and GB $gb. Correct its GRID locations and end offsets before converting G0 $g0."))
        axisunit=axis/axisscale;axisnorm=norm(axisunit);axislength=axisscale*axisnorm;axisunit/=axisnorm
        axisfloor=64eps(max(maximum(abs,start),maximum(abs,finish),1.))
        axislength>=1e-9&&axislength>axisfloor||throw(ArgumentError("$(c.kind) $(c.fields[1]) has an effective GA-to-GB length below the native geometry threshold or coordinate resolution. Separate GA $ga and GB $gb before converting G0 $g0."))
        anglefloor=max(1e-12,resolution/orientation_length,axisfloor/axislength)
        norm(cross(axisunit,normalized/scalednorm))>anglefloor||throw(ArgumentError("$(c.kind) $(c.fields[1]) orientation GRID $g0 lies on or too close to the effective GA $(ga)–GB $gb beam axis. Move G0 away from that axis to define a stable section direction; no arbitrary frame was substituted."))
        before,after=fe_edit_beam_offt(deck,c;defaults=isempty(strip(fe_edit_field(c,8))) ? beamdefault(c) : nothing);unit=normalized/scalednorm
        element["_orientation_basic"]=unit;element["_orientation_offt"]=after
        push!(converted,Dict("eid"=>Int(element["id"]),"source_eid"=>fe_edit_int(c.fields[1]),"ga"=>ga,"g0"=>g0,"basic_vector"=>unit,"source_offt"=>before,"offt"=>after))
    end
    converted
end

function fe_edit_line_fields(line)
    plain=first(split(String(line),'$';limit=2))
    if occursin(',',plain)
        data=String.(strip.(split(plain,',';keepempty=true)))
        # A continuation label occupies field 10 rather than being card data.
        length(data)>=10&&!isempty(data[10])&&startswith(data[10],('+','*'))&&resize!(data,9)
        return first(data),data[2:end]
    end
    bytes=codeunits(rpad(plain,72));head=strip(String(bytes[1:8]));width=endswith(head,"*")||startswith(head,"*") ? 16 : 8
    head,String[strip(String(bytes[i:min(i+width-1,72)])) for i in 9:width:72]
end

function fe_edit_records(text::AbstractString)
    lines=split(replace(String(text),"\r\n"=>"\n"),'\n';keepempty=true)
    records=FEEditCard[];bulk=!any(line->occursin(r"^\s*BEGIN\s+BULK"i,line),lines);i=1
    while i<=length(lines)
        line=String(lines[i]);clean=strip(line)
        if occursin(r"^BEGIN\s+BULK"i,clean)
            bulk=true;push!(records,FEEditCard("",String[],line));i+=1;continue
        end
        if !bulk||isempty(clean)||startswith(clean,'$')||occursin(r"^ENDDATA\b"i,clean)
            push!(records,FEEditCard("",String[],line));i+=1;continue
        end
        head,fields=fe_edit_line_fields(line);kind=uppercase(replace(head,r"\*$"=>""))
        if isempty(kind)||startswith(kind,('+','*'))
            throw(ArgumentError("Orphan continuation in input near line $i; read and export a complete deck before editing."))
        end
        raw=String[line];i+=1
        while i<=length(lines)
            look=i
            while look<=length(lines)&&(isempty(strip(lines[look]))||startswith(strip(lines[look]),'$'));look+=1;end
            look>length(lines)&&break
            following=String(lines[look]);nextclean=strip(following)
            nexthead,nextfields=fe_edit_line_fields(following)
            (isempty(nexthead)||startswith(nexthead,('+','*')))||break
            append!(fields,nextfields);append!(raw,String.(lines[i:look]));i=look+1
        end
        while !isempty(fields)&&isempty(last(fields));pop!(fields);end
        push!(records,FEEditCard(kind,fields,join(raw,"\n")))
    end
    records
end

const FE_EDIT_ELEMENT_NODES=Dict(
    "CQUAD4"=>collect(3:6),"CQUADR"=>collect(3:6),"CTRIA3"=>collect(3:5),"CTRIAR"=>collect(3:5),"CSHEAR"=>collect(3:6),
    "CQUAD8"=>collect(3:10),"CTRIA6"=>collect(3:8),"CTETRA"=>collect(3:12),"CPENTA"=>collect(3:17),"CHEXA"=>collect(3:22),"CPYRAM"=>collect(3:15),
    "CBAR"=>[3,4],"CBEAM"=>[3,4],"CROD"=>[3,4],"CTUBE"=>[3,4],"CONROD"=>[2,3],
    "CBUSH"=>[3,4],"CBUSH1D"=>[3,4],"CGAP"=>[3,4],"CELAS1"=>[3,5],"CELAS2"=>[2,4],"CDAMP1"=>[3,5],"CDAMP2"=>[2,4],
    "CONM2"=>[2],"CONM1"=>[2],"CMASS1"=>[3,5],"CMASS2"=>[2,4])
const FE_EDIT_RIGID_TYPES=Set(["RBE1","RBE2","RBE3","RBAR","RBAR1","RROD","RSPLINE"])
const FE_EDIT_LOAD_CONSTRAINT_TYPES=Set(["FORCE","FORCE1","FORCE2","MOMENT","MOMENT1","MOMENT2","PLOAD","PLOAD1","PLOAD2","PLOAD4","SPC","SPC1","SPCD","MPC","SUPORT","SUPORT1","ASET","ASET1","BSET","BSET1","CSET","CSET1","QSET","QSET1","OMIT","OMIT1","USET","USET1","SESET","SET1","SET3"])

function fe_edit_expand_ids(fields;label="GRID list")
    ids=Int[];i=1
    while i<=length(fields)
        value=uppercase(strip(fields[i]));isempty(value)&&(i+=1;continue)
        id=fe_edit_int(value);id>0||throw(ArgumentError("$label contains unsupported token $value"))
        if i+2<=length(fields)&&uppercase(strip(fields[i+1]))=="THRU"
            stop=fe_edit_int(fields[i+2]);step=1;i+=3
            if i+1<=length(fields)&&uppercase(strip(fields[i]))=="BY";step=fe_edit_int(fields[i+1]);i+=2;end
            stop>=id&&step>0||throw(ArgumentError("$label has an invalid THRU range"))
            append!(ids,id:step:stop)
        else
            push!(ids,id);i+=1
        end
    end
    ids
end

"""Return exact GRID fields. Unknown cards are never guessed to be GRID lists."""
function fe_edit_node_fields(c::FEEditCard)
    k=c.kind;f=c.fields;n=length(f)
    if haskey(FE_EDIT_ELEMENT_NODES,k)
        result=Int[i for i in FE_EDIT_ELEMENT_NODES[k] if i<=n&&fe_edit_int(f[i])>0]
        if fe_edit_orientation_grid(c)>0;push!(result,5);end
        return result
    elseif k=="GRID";return [1]
    elseif k in ("CORD1R","CORD1C","CORD1S");return Int[i for i in (2,3,4,6,7,8) if i<=n]
    elseif k in ("FORCE","MOMENT","RFORCE","DAREA","DPHASE");return [2]
    elseif k=="TEMP";return collect(2:2:n)
    elseif k in ("FORCE1","MOMENT1");return [2,4,5]
    elseif k in ("FORCE2","MOMENT2");return [2,4,5,6,7]
    elseif k=="PLOAD";return Int[i for i in 3:6 if i<=n&&fe_edit_int(f[i])>0]
    elseif k=="PLOAD4";return Int[i for i in (7,8) if i<=n&&fe_edit_int(f[i])>0]
    elseif k in ("SPC","SPCD","MPC");return collect(2:3:n)
    elseif k in ("SUPORT","ASET","BSET","CSET","QSET","OMIT");return collect(1:2:n)
    elseif k=="SUPORT1"||k=="USET";return collect(2:2:n)
    elseif k in ("RBAR","RBAR1","RROD");return [2,3]
    elseif k=="RBE2"
        result=[2]
        for i in 4:n
            isempty(f[i])&&continue
            fe_edit_int(f[i])>0||break
            push!(result,i)
        end
        return result
    elseif k=="RBE3"
        result=[3];i=5
        while i<=n
            isempty(f[i])&&(i+=1;continue)
            marker=uppercase(f[i]);marker=="ALPHA"&&break
            if marker=="UM"
                i+=1
                while i<=n&&uppercase(f[i])!="ALPHA";fe_edit_int(f[i])>0&&push!(result,i);i+=2;end
                break
            end
            i+=2 # weight and component set
            while i<=n
                isempty(f[i])&&(i+=1;continue)
                fe_edit_int(f[i])>0||break
                push!(result,i);i+=1
            end
        end
        return result
    elseif k=="RBE1"
        result=Int[];i=2
        while i<=n
            uppercase(f[i])=="UM"&&(i+=1;continue)
            isempty(f[i])&&(i+=1;continue)
            fe_edit_int(f[i])>0||break
            push!(result,i);i+=2
        end
        return result
    elseif k=="RSPLINE";return vcat([3],collect(4:2:n))
    end
    Int[]
end

function fe_edit_list_start(c::FEEditCard)
    c.kind in ("SPC1","ASET1","BSET1","CSET1","QSET1","OMIT1")&&return c.kind=="SPC1" ? 3 : 2
    c.kind=="USET1"&&return 3
    c.kind=="SESET"&&return 2
    nothing
end

function fe_edit_grid_ids(c::FEEditCard)
    start=fe_edit_list_start(c)
    start===nothing ? Int[fe_edit_int(fe_edit_field(c,i)) for i in fe_edit_node_fields(c) if fe_edit_int(fe_edit_field(c,i))>0] : fe_edit_expand_ids(c.fields[start:end];label="$(c.kind) GRID list")
end

function fe_edit_deck(name,text;coordinates=Dict())
    records=fe_edit_records(text);nodes=Dict{Int,NTuple{3,Float64}}();elements=Dict{String,Any}[]
    for (index,c) in enumerate(records)
        if c.kind=="GRID"
            id=fe_edit_int(fe_edit_field(c,1));id>0||throw(ArgumentError("Invalid GRID identifier"))
            haskey(nodes,id)&&throw(ArgumentError("Duplicate GRID $id prevents editing"))
            if haskey(coordinates,id)
                nodes[id]=Tuple(Float64.(coordinates[id]))
            else
                fe_edit_int(fe_edit_field(c,2))==0||throw(ArgumentError("GRID $id uses CP; initialize from the native imported model to resolve it."))
                nodes[id]=ntuple(i->fe_edit_real(fe_edit_field(c,i+2)),3)
            end
        elseif haskey(FE_EDIT_ELEMENT_NODES,c.kind)
            indices=FE_EDIT_ELEMENT_NODES[c.kind]
            conn=Int[fe_edit_int(fe_edit_field(c,i)) for i in indices if fe_edit_int(fe_edit_field(c,i))>0]
            isempty(conn)&&continue
            push!(elements,Dict{String,Any}("id"=>fe_edit_int(fe_edit_field(c,1)),"type"=>c.kind,"pid"=>(c.kind=="CONROD" ? 0 : fe_edit_int(fe_edit_field(c,2))),"nodes"=>conn,"_node_fields"=>[i for i in indices if fe_edit_int(fe_edit_field(c,i))>0],"_card_index"=>index))
        end
    end
    isempty(nodes)&&throw(ArgumentError("The current deck has no GRID nodes to edit"))
    all(isfinite(x) for xyz in values(nodes) for x in xyz)||throw(ArgumentError("Non-finite GRID coordinates prevent editing"))
    for el in elements,id in el["nodes"];haskey(nodes,id)||throw(ArgumentError("$(el["type"]) $(el["id"]) references missing GRID $id"));end
    FEEditDeck(String(name),records,nodes,elements)
end

fe_edit_rigid_links(deck::FEEditDeck)=Dict{String,Any}[Dict("id"=>fe_edit_int(fe_edit_field(c,1)),"type"=>c.kind,"nodes"=>fe_edit_grid_ids(c),"_card_index"=>index) for (index,c) in enumerate(deck.records) if c.kind in FE_EDIT_RIGID_TYPES]

function fe_edit_mesh(deck::FEEditDeck;copy_geometry=true)
    maxid=maximum((fe_edit_int(fe_edit_field(c,1)) for c in deck.records if (startswith(c.kind,"C")&&!startswith(c.kind,"CORD"))||c.kind in FE_EDIT_RIGID_TYPES);init=0)
    links=fe_edit_rigid_links(deck)
    Dict{String,Any}("nodes"=>(copy_geometry ? deepcopy(deck.nodes) : deck.nodes),"elements"=>(copy_geometry ? deepcopy(deck.elements) : deck.elements),"rigid_links"=>links,"next_element_id"=>maxid+1,"next_node_id"=>maximum(keys(deck.nodes))+1)
end

function fe_edit_card_text(kind,fields)
    data=String[string(value) for value in fields]
    while !isempty(data)&&isempty(last(data));pop!(data);end
    isempty(data)&&return kind
    rows=String[]
    for start in 1:8:length(data)
        push!(rows,join(vcat(start==1 ? kind : "+",data[start:min(start+7,length(data))]),','))
    end
    join(rows,"\n")
end

function fe_edit_replace_nodes(c::FEEditCard,mapping::AbstractDict)
    isempty(mapping)&&return c.raw
    f=copy(c.fields);start=fe_edit_list_start(c)
    if start!==nothing
        ids=fe_edit_grid_ids(c);mapped=unique([get(mapping,id,id) for id in ids]);mapped==ids&&return c.raw
        return fe_edit_card_text(c.kind,vcat(f[1:start-1],string.(mapped)))
    end
    changed=false
    for i in fe_edit_node_fields(c)
        i>length(f)&&continue
        id=fe_edit_int(f[i]);new=get(mapping,id,id)
        if new!=id;f[i]=string(new);changed=true;end
    end
    changed||return c.raw
    if c.kind=="RBE2"
        master=fe_edit_int(f[2]);dep=Int[];tail=String[];thermal=false
        for x in f[4:end]
            isempty(x)&&continue
            id=fe_edit_int(x)
            if !thermal&&id>0;id!=master&&push!(dep,id)
            else;thermal=true;push!(tail,x);end
        end
        isempty(dep)&&return "\$ FE Utils removed RBE2 $(f[1]): all dependent nodes became its independent node"
        f=vcat(f[1:3],string.(unique(dep)),tail)
    end
    fe_edit_card_text(c.kind,f)
end

function fe_edit_node_free(c::FEEditCard)
    k=c.kind
    property=k in ("PSHELL","PCOMP","PCOMPG","PSOLID","PLSOLID","PBAR","PBARL","PBEAM","PBEAML","PROD","PTUBE","PBUSH","PBUSH1D","PELAS","PDAMP","PMASS","PGAP","PSHEAR","PAERO1","PAERO2","PAERO3","PAERO4","PAERO5")
    isempty(k)||property||any(prefix->startswith(k,prefix),("MAT","CORD2","TABLE","EIG","TSTEP","NLPARM","NLPCI","DLOAD","LOAD","SPCADD","MPCADD","DESVAR","DVPREL","DVMREL","DCONSTR","PARAM","MDLPRM","SPOINT","EPOINT","GRAV"))
end

function fe_edit_check_remap(deck,mapping)
    isempty(mapping)&&return
    for c in deck.records
        isempty(c.kind)||c.kind=="GRID"||!isempty(fe_edit_node_fields(c))||fe_edit_list_start(c)!==nothing||fe_edit_node_free(c)||begin
            touched=sort!(unique([fe_edit_int(f) for f in c.fields if haskey(mapping,fe_edit_int(f))&&get(mapping,fe_edit_int(f),fe_edit_int(f))!=fe_edit_int(f)]))
            isempty(touched)||throw(ArgumentError("Cannot safely remap $(c.kind) $(fe_edit_field(c,1)): its identifiers $(join(touched,", ")) may refer to merged GRID nodes. This card has no declared node-field adapter. Review or remove it from an exported copy before retrying; the current model is unchanged."))
        end
    end
end

function fe_edit_element_load_guard(deck,changed_ids)
    isempty(changed_ids)&&return
    for c in deck.records
        refs=if c.kind in ("PLOAD1","PLOAD4");[fe_edit_int(fe_edit_field(c,2))]
        elseif c.kind=="PLOAD2";fe_edit_expand_ids(c.fields[3:end];label="PLOAD2 element list")
        elseif c.kind in ("SET1","SET3");Int[fe_edit_int(f) for f in c.fields[2:end] if fe_edit_int(f)>0]
        elseif startswith(c.kind,"PLOAD");Int[fe_edit_int(f) for f in c.fields[2:end] if fe_edit_int(f)>0]
        elseif !isempty(c.kind)&&!haskey(FE_EDIT_ELEMENT_NODES,c.kind)&&isempty(fe_edit_node_fields(c))&&fe_edit_list_start(c)===nothing&&!fe_edit_node_free(c)
            # Unsupported dependency cards are not guessed. A matching EID
            # can be an output/optimization/contact membership, so stop before
            # retaining an identifier that would represent only one fragment.
            Int[fe_edit_int(f) for f in c.fields[2:end] if fe_edit_int(f)>0]
        else;Int[];end
        isempty(refs)&&continue
        overlap=intersect(Set(refs),changed_ids)
        isempty(overlap)||throw(ArgumentError("The cut splits element(s) $(join(sort!(collect(overlap)),", ")) referenced by $(c.kind) $(fe_edit_field(c,1)). Element loads/ambiguous sets cannot be reassigned automatically. Move the cut away from these elements or recreate that card on the edited deck; no edit has been applied."))
    end
end

function fe_edit_parent_card(deck,el)
    i=Int(get(el,"_card_index",0));1<=i<=length(deck.records)||throw(ArgumentError("An edited element lost its source-card association"));deck.records[i]
end

function fe_edit_corner_thickness(c,id,provenance)
    parentnodes=Int[fe_edit_int(fe_edit_field(c,i)) for i in FE_EDIT_ELEMENT_NODES[c.kind]]
    old=findfirst(==(id),parentnodes);start=10
    old!==nothing&&return fe_edit_field(c,start+old)
    info=get(provenance,id,nothing);info===nothing&&return ""
    haskey(info,"original")&&return fe_edit_corner_thickness(c,Int(info["original"]),provenance)
    ends=Int.(info["edge"]);t=Float64(info["fraction"])
    a=fe_edit_corner_thickness(c,ends[1],provenance);b=fe_edit_corner_thickness(c,ends[2],provenance)
    isempty(a)&&isempty(b)&&return ""
    isempty(a)||isempty(b) ? throw(ArgumentError("$(c.kind) $(c.fields[1]) has partially specified corner thicknesses; define all thicknesses before cutting.")) : string((1-t)*fe_edit_real(a)+t*fe_edit_real(b))
end

function fe_edit_element_text(deck,el,nodes;provenance=Dict(),material_cid=nothing)
    c=fe_edit_parent_card(deck,el);kind=String(el["type"]);conn=Int.(el["nodes"]);f=copy(c.fields)
    if kind==c.kind
        indices=get(el,"_node_fields",FE_EDIT_ELEMENT_NODES[kind]);needed=maximum(indices[1:length(conn)])
        while length(f)<needed;push!(f,"");end
        f[1]=string(el["id"])
        for (i,id) in zip(indices,conn);f[i]=string(id);end
        if kind=="CONM2"&&fe_edit_int(fe_edit_field(c,3))==-1
            old=fe_edit_int(fe_edit_field(c,2));delta=Float64.(collect(nodes[first(conn)]))-Float64.(collect(deck.nodes[old]))
            while length(f)<7;push!(f,"");end
            for i in 1:3;f[i+4]=string(fe_edit_real(fe_edit_field(c,i+4))+delta[i]);end
        end
        if haskey(el,"_orientation_basic")
            while length(f)<8;push!(f,"");end
            f[5:7]=string.(Float64.(el["_orientation_basic"]));f[8]=String(el["_orientation_offt"])
        elseif fe_edit_orientation_grid(c)>0
            g0=fe_edit_orientation_grid(c);mapping=get(el,"_orientation_node_map",Dict{Int,Int}())
            f[5]=string(get(mapping,g0,g0))
        end
        if kind in ("CQUAD4","CQUADR","CTRIA3","CTRIAR")&&!isempty(provenance)
            start=10
            any(i->!isempty(fe_edit_field(c,start+i)),1:length(conn))&&begin
                while length(f)<start+length(conn);push!(f,"");end
                for (i,id) in enumerate(conn);f[start+i]=fe_edit_corner_thickness(c,id,provenance);end
            end
        end
    elseif kind in ("CTRIA3","CTRIAR","CQUAD4","CQUADR")&&c.kind in ("CTRIA3","CTRIAR","CQUAD4","CQUADR")
        sourcetheta=c.kind in ("CQUAD4","CQUADR") ? 7 : 6
        f=vcat(string(el["id"]),fe_edit_field(c,2),string.(conn),fe_edit_field(c,sourcetheta),fe_edit_field(c,sourcetheta+1))
        while length(f)<9;push!(f,"");end
        push!(f,fe_edit_field(c,10))
        append!(f,[fe_edit_corner_thickness(c,id,provenance) for id in conn])
    else
        throw(ArgumentError("Cannot preserve $(c.kind) attributes when converting it to $kind"))
    end
    if material_cid!==nothing
        index=kind in ("CQUAD4","CQUADR") ? 7 : 6
        while length(f)<index;push!(f,"");end
        f[index]=string(material_cid)
    end
    fe_edit_card_text(kind,f)
end

function fe_edit_material_index(deck)
    properties=Dict{Int,FEEditCard}();anisotropic=Set{Int}()
    for row in deck.records
        if row.kind in ("PSHELL","PCOMP","PCOMPG")
            get!(properties,fe_edit_int(fe_edit_field(row,1)),row)
        elseif row.kind in ("MAT8","MAT9","MAT2")
            push!(anisotropic,fe_edit_int(fe_edit_field(row,1)))
        end
    end
    (properties=properties,anisotropic=anisotropic)
end

function fe_edit_material_coordinate(deck,c,cid;material_index=nothing)
    ids=Int[fe_edit_int(fe_edit_field(c,i)) for i in FE_EDIT_ELEMENT_NODES[c.kind]]
    p=[collect(deck.nodes[id]) for id in ids];u=p[2]-p[1]
    normal=length(p)==4 ? cross(-p[1]+p[2]+p[3]-p[4],-p[1]-p[2]+p[3]+p[4]) : cross(u,p[3]-p[1]);normal/=norm(normal)
    scale=maximum(norm(x-p[1]) for x in p)
    warped=any(abs(dot(x-p[1],normal))>max(scale*1e-8,1e-12) for x in p)
    material_index===nothing&&(material_index=fe_edit_material_index(deck))
    pid=fe_edit_int(fe_edit_field(c,2));prop=get(material_index.properties,pid,nothing)
    anisotropic=prop===nothing
    if prop!==nothing
        anisotropic=prop.kind in ("PCOMP","PCOMPG")
        if prop.kind=="PSHELL"
            mids=Set(fe_edit_int(fe_edit_field(prop,i)) for i in (2,4,6,11))
            anisotropic=!isdisjoint(mids,material_index.anisotropic)
        end
    end
    warped&&anisotropic&&throw(ArgumentError("$(c.kind) $(c.fields[1]) is warped and has an element-relative anisotropic material angle. Preserving its spatial material direction across fragments needs an explicit MCID. Define a CORD2 material axis for that element or move the cut to its boundary; the current model is unchanged."))
    if length(p)==4
        a=p[3]-p[1];a/=norm(a);b=p[4]-p[2];b/=norm(b);u=a-b
    end
    u-=dot(u,normal)*normal;u/=norm(u);v=cross(normal,u)
    angle=deg2rad(fe_edit_real(fe_edit_field(c,length(p)==4 ? 7 : 6)))
    material=cos(angle)*u+sin(angle)*v
    note=warped ? "\$ FE Utils: warped isotropic shell $(c.fields[1]); fragments use the parent central stress/material frame.\n" : ""
    note*fe_edit_card_text("CORD2R",vcat(string(cid),"0",["0.","0.","0."],string.(normal),string.(material)))
end

function fe_edit_summary(mesh;warnings=String[])
    nodes=mesh["nodes"];lo=[minimum(p[i] for p in values(nodes)) for i in 1:3];hi=[maximum(p[i] for p in values(nodes)) for i in 1:3]
    Dict{String,Any}("nodes"=>length(nodes),"elements"=>length(mesh["elements"]),"bounds"=>Dict("min"=>lo,"max"=>hi),"warnings"=>warnings)
end

function fe_edit_shell_geometry_unchanged(deck,c,element,nodes)
    String(element["type"])==c.kind||return false
    original=Int[fe_edit_int(fe_edit_field(c,i)) for i in FE_EDIT_ELEMENT_NODES[c.kind]]
    edited=Int.(element["nodes"]);length(original)==length(edited)||return false
    oldpoints=[collect(deck.nodes[id]) for id in original];newpoints=[collect(nodes[id]) for id in edited]
    scale=maximum(norm(point-first(oldpoints)) for point in oldpoints)
    absolute=maximum(abs(value) for point in vcat(oldpoints,newpoints) for value in point)
    tolerance=max(scale*1e-11,eps(max(absolute,1.))*64)
    all(norm((newpoints[i]-first(newpoints))-(oldpoints[i]-first(oldpoints)))<=tolerance for i in eachindex(original))
end

"""Render a candidate working deck without writing the original user's file."""
function fe_edit_render(deck::FEEditDeck,mesh;node_mapping=Dict{Int,Int}(),element_parents=Dict{Int,Int}(),node_provenance=Dict(),duplicate_nodes=Dict{Int,Int}(),copied_node_maps=Any[],copied_element_maps=Any[])
    fe_edit_check_remap(deck,node_mapping)
    node_provenance=Dict{Int,Any}(Int(id)=>info for (id,info) in node_provenance)
    for (old,new) in duplicate_nodes;node_provenance[Int(new)]=Dict("original"=>Int(old));end
    nodes=mesh["nodes"];elements=mesh["elements"];bycard=Dict{Int,Vector{Any}}()
    for el in elements;push!(get!(bycard,Int(el["_card_index"]),Any[]),el);end
    rigidbycard=Dict{Int,Vector{Any}}()
    for link in get(mesh,"rigid_links",Any[]);push!(get!(rigidbycard,Int(link["_card_index"]),Any[]),link);end
    elementcards=Set(Int(el["_card_index"]) for el in deck.elements)
    original_elements=Set(Int(el["id"]) for el in deck.elements)
    split=Set{Int}()
    for (child,parent) in element_parents;child!=parent&&parent in original_elements&&push!(split,parent);end
    # Copies intentionally do not transfer element-based loading.
    isempty(copied_node_maps)&&fe_edit_element_load_guard(deck,split)
    for el in elements
        c=fe_edit_parent_card(deck,el)
        if c.kind in ("CBAR","CBEAM")&&Int(el["id"])!=fe_edit_int(fe_edit_field(c,1))&&isempty(copied_node_maps)
            any(i->!isempty(fe_edit_field(c,i))&&fe_edit_real(fe_edit_field(c,i))!=0.,9:18)&&throw(ArgumentError("$(c.kind) $(c.fields[1]) has end releases, offsets or warping-point fields; a cut would change their meaning. Move the cut to an end GRID or simplify the beam in a copy first."))
        end
    end
    rows=String[];written=Set{Int}();gridcards=Dict(fe_edit_int(fe_edit_field(c,1))=>c for c in deck.records if c.kind=="GRID")
    coordinatecards=String[];materialcids=Dict{Int,Int}();materialindex=nothing
    nextcid=maximum((fe_edit_int(fe_edit_field(c,i)) for c in deck.records if startswith(c.kind,"CORD") for i in (startswith(c.kind,"CORD1") ? (1,5) : (1,)));init=0)+1
    if isempty(copied_node_maps)
        for (index,children) in bycard
            c=deck.records[index];c.kind in ("CQUAD4","CQUADR","CTRIA3","CTRIAR")||continue
            oldnodes=fe_edit_grid_ids(c)
            any(el->Int.(el["nodes"])!=oldnodes,children)||continue
            all(el->fe_edit_shell_geometry_unchanged(deck,c,el,nodes),children)&&continue
            angle=fe_edit_field(c,c.kind in ("CQUAD4","CQUADR") ? 7 : 6)
            isempty(angle)||tryparse(Int,angle)===nothing||continue # explicit MCID is invariant
            materialindex===nothing&&(materialindex=fe_edit_material_index(deck))
            materialcids[index]=nextcid;push!(coordinatecards,fe_edit_material_coordinate(deck,c,nextcid;material_index=materialindex));nextcid+=1
        end
    end
    inversecopies=Dict{Int,Int}(Int(new)=>Int(old) for mapping in copied_node_maps for (old,new) in mapping)
    inverseduplicates=Dict(Int(new)=>Int(old) for (old,new) in duplicate_nodes)
    function gridtext(id)
        original=get(inversecopies,id,get(inverseduplicates,id,id));c=get(gridcards,original,nothing)
        xyz=nodes[id]
        if c!==nothing&&id==original&&fe_edit_int(fe_edit_field(c,2))==0&&all(i->fe_edit_real(fe_edit_field(c,i+2))==xyz[i],1:3)
            return c.raw
        end
        f=c===nothing ? [string(id),"0","0.","0.","0."] : copy(c.fields)
        while length(f)<5;push!(f,"");end
        f[1]=string(id);f[2]="0";f[3:5]=string.(Float64.(collect(xyz)))
        # Permanent GRID constraints are boundary conditions too. Copies and
        # detached structural aliases retain CD, but PS stays on source GRIDs.
        (haskey(inversecopies,id)||haskey(inverseduplicates,id))&&length(f)>=7&&(f[7]="")
        fe_edit_card_text("GRID",f)
    end
    for (index,c) in enumerate(deck.records)
        if c.kind=="GRID"
            id=fe_edit_int(fe_edit_field(c,1));haskey(nodes,id)&&(push!(rows,gridtext(id));push!(written,id));continue
        elseif haskey(bycard,index)
            for el in bycard[index]
                original=fe_edit_int(fe_edit_field(c,1));originalnodes=Int[fe_edit_int(fe_edit_field(c,i)) for i in FE_EDIT_ELEMENT_NODES[c.kind] if fe_edit_int(fe_edit_field(c,i))>0]
                same=Int(el["id"])==original&&String(el["type"])==c.kind&&Int.(el["nodes"])==originalnodes
                haskey(el,"_orientation_basic")&&(same=false)
                if same&&c.kind=="CONM2"&&fe_edit_int(fe_edit_field(c,3))==-1
                    gid=fe_edit_int(fe_edit_field(c,2));same=collect(nodes[gid])==collect(deck.nodes[gid])
                end
                renderel=el
                if !same&&!isempty(copied_node_maps)&&c.kind in ("CBAR","CBEAM","CBUSH","CGAP")
                    oldnodes=Int[fe_edit_int(fe_edit_field(c,i)) for i in get(el,"_node_fields",FE_EDIT_ELEMENT_NODES[c.kind])]
                    found=findfirst(mapping->[get(mapping,id,id) for id in oldnodes]==Int.(el["nodes"]),copied_node_maps)
                    if found!==nothing;renderel=copy(el);renderel["_orientation_node_map"]=copied_node_maps[found];end
                end
                push!(rows,same ? c.raw : fe_edit_element_text(deck,renderel,nodes;provenance=node_provenance,material_cid=get(materialcids,index,nothing)))
            end
            continue
        elseif haskey(rigidbycard,index)
            originalnodes=fe_edit_grid_ids(c)
            for rigid in rigidbycard[index]
                map=Dict{Int,Int}(old=>Int(new) for (old,new) in zip(originalnodes,rigid["nodes"]) if old!=new)
                text=fe_edit_replace_nodes(c,map)
                if Int(rigid["id"])!=fe_edit_int(fe_edit_field(c,1))
                    copied=only(filter(row->!isempty(row.kind),fe_edit_records(text)));fields=copy(copied.fields);fields[1]=string(rigid["id"])
                    text=fe_edit_card_text(c.kind,fields)
                end
                push!(rows,text)
            end
            continue
        elseif index in elementcards
            continue
        end
        push!(rows,fe_edit_replace_nodes(c,node_mapping))
    end
    extra=vcat(coordinatecards,String[gridtext(id) for id in sort!(collect(setdiff(Set(keys(nodes)),written)))])
    # Preserve end-of-file cards and emit new entities immediately before ENDDATA.
    insertion=findfirst(row->occursin(r"^\s*ENDDATA\b"im,row),rows);insertion===nothing&&(insertion=length(rows)+1)
    if !isempty(extra);splice!(rows,insertion:insertion-1,extra);end
    result=join(rows,"\n");endswith(result,"\n") ? result : result*"\n"
end
