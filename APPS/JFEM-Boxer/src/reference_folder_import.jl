# Read-only consolidation of loose Nastran deck fragments. Each semantic
# entity has one authoritative definition; equal IDs never imply overwrite.
import SHA
import CodecZlib

const REFERENCE_FOLDER_EXTENSIONS=Set((".bdf",".dat",".nas",".bulk",".blk",".fem",".pch",".inc",".include",".inp"))
const REFERENCE_FOLDER_MAX_FILES=20000
const REFERENCE_FOLDER_MAX_BYTES=2*1024^3
const REFERENCE_FOLDER_MAX_FILE_BYTES=512*1024^2

_reference_folder_key(path)=Sys.iswindows() ? lowercase(normpath(path)) : normpath(path)
function _reference_folder_contains(root,path)
    base=_reference_folder_key(root);candidate=_reference_folder_key(path)
    candidate==base||startswith(candidate,base*string(Base.Filesystem.path_separator))
end

function _reference_folder_root(directory)
    directory isa AbstractString&&!isempty(strip(directory))||throw(ArgumentError("Choose a folder containing Nastran model files."))
    isabspath(directory)||throw(ArgumentError("Use the full path to the Nastran model folder."))
    isdir(directory)||throw(ArgumentError("The model folder does not exist: $directory"))
    realpath(directory)
end

function _reference_folder_read(path;limit=REFERENCE_FOLDER_MAX_FILE_BYTES)
    text=if endswith(lowercase(path),".gz")
        open(path) do io
            stream=CodecZlib.GzipDecompressorStream(io)
            try
                bytes=read(stream,limit+1)
                length(bytes)<=limit||throw(ArgumentError("Expanded file exceeds $(div(limit,1024^2)) MiB: $path. Split or unpack a smaller model before importing."))
                String(bytes)
            finally
                close(stream)
            end
        end
    else
        filesize(path)<=limit||throw(ArgumentError("File exceeds $(div(limit,1024^2)) MiB: $path. Split it into smaller fragments before importing."))
        read(path,String)
    end
    isvalid(text)||throw(ArgumentError("The file is not valid UTF-8 text: $path. Convert it to a text Nastran deck before importing."))
    occursin('\0',text)&&throw(ArgumentError("The file contains binary data: $path"))
    startswith(text,"version https://git-lfs.github.com/spec/v1")&&throw(ArgumentError("The file is a Git LFS pointer rather than a model: $path. Download its actual contents first."))
    replace(text,"\r\n"=>"\n",'\r'=>'\n')
end

function _reference_folder_is_abaqus(text)
    for line in eachline(IOBuffer(text))
        s=strip(line);isempty(s)&&continue
        startswith(s,"**")&&continue
        startswith(s,'$')&&continue
        return occursin(r"^\*(HEADING|NODE|ELEMENT|PART|ASSEMBLY|PREPRINT|MATERIAL|INCLUDE)(?:\s|,|$)"i,s)
    end
    false
end

function _reference_folder_is_nastran(text)
    !_reference_folder_is_abaqus(text)&&occursin(r"(?im)^\s*(?:BEGIN\s+BULK|CEND|SOL\s+\d+|GRID\*?(?:\s|,)|(?:CQUAD4|CTRIA3|CHEXA|CTETRA|CBAR|CBEAM|PSHELL|PCOMP|MAT1|MAT8|INCLUDE)(?:\s|,))",text)
end

_reference_folder_bulk_start(line)=occursin(r"^\s*(?:GRID\*?|C[A-Z0-9]+\*?|P[A-Z0-9]+\*?|MAT[A-Z0-9]+\*?|RBE[123]|RBAR|FORCE[12]?|MOMENT[12]?|SPC[1D]?|MPC|BEGIN\s+BULK|ENDDATA|SOL|CEND|SUBCASE)(?:\s|,|$)"i,line)

function _reference_folder_includes(text,path,root;ignore_unresolved_includes=false,warnings=String[])
    targets=Tuple{String,Int}[];pending="";start=0
    function reject(message)
        ignore_unresolved_includes||throw(ArgumentError(message))
        push!(warnings,"Ignored unresolved INCLUDE: "*message)
    end
    for (number,line) in enumerate(eachline(IOBuffer(text)))
        stripped=strip(line)
        if ignore_unresolved_includes&&!isempty(pending)&&_reference_folder_bulk_start(stripped)
            reject("Unterminated INCLUDE in $(relpath(path,root)):$start. The following model card was preserved; available fragments are collected independently.")
            pending=""
        end
        if !isempty(pending)||occursin(r"^INCLUDE(?:\s|,|$)"i,stripped)
            isempty(pending)&&(start=number)
            pending*=stripped
            matchfile=match(r"^INCLUDE\s*,?\s*(?:'([^']+)'|\"([^\"]+)\"|([^\s$'\"]+))\s*(?:\$.*)?$"i,pending)
            if matchfile===nothing
                if !(count(==('\''),pending)%2==1||count(==('"'),pending)%2==1)
                    reject("Malformed INCLUDE in $(relpath(path,root)):$start: $pending");pending=""
                end
                continue
            end
            relative=strip(something(matchfile.captures...));relative=replace(relative,'\\'=>'/')
            target=isabspath(relative) ? normpath(relative) : normpath(joinpath(dirname(path),relative))
            if !_reference_folder_contains(root,abspath(target))
                reject("INCLUDE in $(relpath(path,root)):$start points outside the selected folder: $relative. Choose a common parent folder containing every fragment or move an independent copy of the dependency inside it.");pending="";continue
            end
            if !isfile(target)
                reject("Missing INCLUDE in $(relpath(path,root)):$start: $relative. Restore that file or deselect the referring fragment.");pending="";continue
            end
            canonical=realpath(target)
            if !_reference_folder_contains(root,canonical)
                reject("INCLUDE in $(relpath(path,root)):$start escapes through a symbolic link: $relative. Choose a folder containing the actual dependency.");pending="";continue
            end
            push!(targets,(canonical,start));pending=""
        end
    end
    isempty(pending)||reject("Unterminated INCLUDE in $(relpath(path,root)):$start")
    targets
end

function _reference_folder_has_header(text)
    occursin(r"(?im)^\s*(?:SOL(?:\s|,)|CEND(?:\s|$)|SUBCASE(?:\s|$)|(?:TITLE|SUBTITLE|LABEL|METHOD|SPC|MPC|LOAD|DLOAD|DISPLACEMENT|STRESS|FORCE)\s*=)",text)
end

function _reference_folder_header_key(text)
    result=String[]
    for line in eachline(IOBuffer(text))
        occursin(r"^\s*BEGIN\s+BULK\b"i,line)&&break
        meaningful=uppercase(strip(first(split(line,'$';limit=2))))
        isempty(meaningful)||push!(result,meaningful)
    end
    join(result,"\n")
end

"""Preview recursively found model files, included dependencies and fingerprint."""
function reference_folder_scan(directory;ignore_unresolved_includes=false)
    root=_reference_folder_root(directory);warnings=String[];pending=String[];seen=Set{String}()
    for (current,dirs,files) in walkdir(root;follow_symlinks=false)
        filter!(dirs) do name
            path=joinpath(current,name)
            if islink(path)||!_reference_folder_contains(root,realpath(path))
                push!(warnings,"Skipped linked directory $(relpath(path,root)); folder scanning stays inside the selected physical directory.")
                false
            else
                true
            end
        end
        for file in sort(files)
            path=joinpath(current,file);plain=replace(lowercase(file),r"\.gz$"=>"")
            splitext(plain)[2] in REFERENCE_FOLDER_EXTENSIONS||continue
            canonical=realpath(path)
            if !_reference_folder_contains(root,canonical)
                push!(warnings,"Skipped linked file outside the selected folder: $(relpath(path,root))");continue
            end
            push!(pending,canonical)
        end
    end
    sort!(pending;by=p->_reference_folder_key(relpath(p,root)))
    files=Dict{String,Any}[];total=0;expanded=0;index=1
    while index<=length(pending)
        path=pending[index];index+=1;key=_reference_folder_key(path)
        key in seen&&continue
        push!(seen,key)
        length(seen)<=REFERENCE_FOLDER_MAX_FILES||throw(ArgumentError("More than $REFERENCE_FOLDER_MAX_FILES files were found. Select a smaller model-specific directory."))
        text=_reference_folder_read(path)
        if _reference_folder_is_abaqus(text)
            push!(warnings,"Skipped Abaqus file $(relpath(path,root)); this folder reader consolidates Nastran files.");continue
        end
        plain=replace(lowercase(path),r"\.gz$"=>"")
        if endswith(plain,".inp")&&!_reference_folder_is_nastran(text)
            push!(warnings,"Skipped $(relpath(path,root)): its .inp contents do not identify a Nastran deck.");continue
        end
        total+=filesize(path);expanded+=ncodeunits(text)
        total<=REFERENCE_FOLDER_MAX_BYTES&&expanded<=REFERENCE_FOLDER_MAX_BYTES||throw(ArgumentError("The folder exceeds the 2 GiB text import budget. Select a smaller model-specific folder or exclude unrelated campaigns."))
        statdata=stat(path)
        push!(files,Dict{String,Any}("path"=>replace(relpath(path,root),'\\'=>'/'),"name"=>basename(path),"bytes"=>filesize(path),
            "expanded_bytes"=>ncodeunits(text),"mtime"=>statdata.mtime,"format"=>"reference","has_case_control"=>_reference_folder_has_header(text),
            "header_signature"=>bytes2hex(SHA.sha256(_reference_folder_has_header(text) ? _reference_folder_header_key(text) : "")),
            "sha256"=>bytes2hex(SHA.sha256(codeunits(text)))))
        for (target,_) in _reference_folder_includes(text,path,root;ignore_unresolved_includes,warnings)
            _reference_folder_key(target) in seen||push!(pending,target)
        end
    end
    sort!(files;by=f->_reference_folder_key(f["path"]))
    isempty(files)&&throw(ArgumentError("No Nastran text models were found in $root. Supported extensions include .bdf, .dat, .nas, .bulk, .blk, .fem, .pch, .inc and gzip versions; .inp is accepted only when its contents are Nastran."))
    manifest=join((f["path"]*"\0"*string(f["bytes"])*"\0"*string(f["mtime"])*"\0"*f["sha256"] for f in files),"\n")
    fingerprint=bytes2hex(SHA.sha256(root*"\nignore_unresolved_includes="*string(ignore_unresolved_includes)*"\n"*manifest))
    Dict{String,Any}("directory"=>root,"path"=>root,"files"=>files,"total_bytes"=>total,"expanded_bytes"=>expanded,
        "warnings"=>unique(warnings),"primary_candidates"=>[f["path"] for f in files if f["has_case_control"]],
        "primary_required"=>length(unique(f["header_signature"] for f in files if f["has_case_control"]))>1,
        "ignore_unresolved_includes"=>ignore_unresolved_includes,
        "fingerprint"=>fingerprint,"scan_signature"=>fingerprint,"scan_id"=>fingerprint)
end

function _reference_folder_line_fields(line)
    plain=first(split(String(line),'$';limit=2))
    if occursin(',',plain)
        data=String.(strip.(split(plain,',';keepempty=true)))
        length(data)>=10&&!isempty(data[10])&&startswith(data[10],('+','*'))&&resize!(data,9)
        return uppercase(replace(first(data),r"\*$"=>"")),data[2:end]
    end
    padded=rpad(plain,72);head=strip(first(padded,8));width=endswith(head,"*")||startswith(head,"*") ? 16 : 8
    uppercase(replace(head,r"\*$"=>"")),String[strip(String(SubString(padded,i,min(i+width-1,lastindex(padded))))) for i in 9:width:72]
end

function _reference_folder_parts(text,path;ignore_unresolved_includes=false)
    lines=split(text,'\n';keepempty=true);beginline=findfirst(line->occursin(r"^\s*BEGIN\s+BULK\b"i,line),lines)
    header=String[]
    if beginline!==nothing
        append!(header,lines[1:beginline-1]);firstbulk=beginline+1
    else
        _reference_folder_has_header(text)&&throw(ArgumentError("$path has executive/case-control statements but no BEGIN BULK marker. Supply a complete header or a bulk-only fragment."))
        firstbulk=1
    end
    cards=Any[];i=firstbulk
    while i<=length(lines)
        line=String(lines[i]);clean=strip(line)
        if isempty(clean)||startswith(clean,'$')
            push!(cards,(kind="",fields=String[],raw=line,line=i));i+=1;continue
        elseif occursin(r"^ENDDATA\b"i,clean)
            i+=1;continue
        elseif occursin(r"^INCLUDE(?:\s|,|$)"i,clean)
            pending=clean;i+=1
            while count(==('\''),pending)%2==1||count(==('"'),pending)%2==1
                if i>length(lines)
                    ignore_unresolved_includes&&break
                    throw(ArgumentError("Unterminated INCLUDE in $path"))
                end
                ignore_unresolved_includes&&_reference_folder_bulk_start(lines[i])&&break
                pending*=strip(lines[i]);i+=1
            end
            continue
        end
        kind,fields=_reference_folder_line_fields(line)
        (isempty(kind)||startswith(kind,('+','*')))&&throw(ArgumentError("Orphan card continuation in $path:$i. Include the file containing its parent card."))
        start=i;raw=String[line];i+=1
        while i<=length(lines)
            nextline=String(lines[i]);nextclean=strip(nextline)
            isempty(nextclean)&&break
            startswith(nextclean,'$')&&break
            nextkind,nextfields=_reference_folder_line_fields(nextline)
            (isempty(nextkind)||startswith(nextkind,('+','*')))||break
            append!(fields,nextfields);push!(raw,nextline);i+=1
        end
        while !isempty(fields)&&isempty(last(fields));pop!(fields);end
        push!(cards,(kind=kind,fields=fields,raw=join(raw,"\n"),line=start))
    end
    header,cards
end

function _reference_folder_token(field)
    value=strip(field)
    isempty(value)&&return ""
    integer=tryparse(Int,value);integer!==nothing&&return "I:"*string(integer)
    realtext=replace(value,r"[dD]"=>"E")
    occursin(r"^[+-]?(?:\d+\.?\d*|\.\d+)[+-]\d+$",realtext)&&(realtext=replace(realtext,r"(?<=[\d.])([+-]\d+)$"=>s"E\1"))
    number=tryparse(Float64,realtext)
    number!==nothing&&isfinite(number)&&return "R:"*string(number==0 ? 0.0 : number)
    uppercase(value)
end

function _reference_folder_entities(card)
    k=card.kind;f=card.fields;isempty(k)&&return Tuple{String,String}[]
    id=isempty(f) ? "" : uppercase(strip(f[1]))
    if k=="GRID";return [("GRID",id)]
    elseif startswith(k,"CORD")
        keys=[("coordinate",id)]
        startswith(k,"CORD1")&&length(f)>=5&&!isempty(f[5])&&push!(keys,("coordinate",f[5]))
        return keys
    elseif any(prefix->startswith(k,prefix),("MATS","MATT","MATDMG","MATF"))||k=="CREEP";return [(k,id)]
    elseif startswith(k,"MAT");return [("material",id)]
    elseif startswith(k,"P")&&k!="PARAM"&&!startswith(k,"PLOAD");return [("property",id)]
    elseif startswith(k,"C")||k in ("RBE1","RBE2","RBE3","RBAR","RBAR1","RROD","RSPLINE","PLOTEL","GENEL");return [("element",id)]
    elseif k in ("PARAM","MDLPRM");return [(k,id)]
    elseif k in ("SET1","SET3","SPCADD","MPCADD","EIGR","EIGRL","EIGB","TSTEP","TSTEPNL","NLPARM","NLPCI");return [(k,id)]
    elseif startswith(k,"TABLE");return [("table",id)]
    elseif k in ("GRDSET","DTABLE");return [(k,"global")]
    end
    Tuple{String,String}[]
end

function _reference_folder_chosen(scan,selected_files)
    available=Dict(_reference_folder_key(f["path"])=>f for f in scan["files"])
    selected_files===nothing&&return scan["files"]
    selected_files isa AbstractVector||throw(ArgumentError("The selected fragment list must be an array of paths from the folder scan."))
    chosen=Dict{String,Any}[];seen=Set{String}()
    for path in selected_files
        path isa AbstractString||throw(ArgumentError("Every selected fragment path must be text."))
        normalized=replace(normpath(path),'\\'=>'/');key=_reference_folder_key(normalized)
        haskey(available,key)||throw(ArgumentError("The selected file $path was not present in the folder scan. Scan again; only files inside the selected directory are accepted."))
        key in seen&&continue
        push!(seen,key);push!(chosen,available[key])
    end
    isempty(chosen)&&throw(ArgumentError("Select at least one model fragment."))
    sort!(chosen;by=f->_reference_folder_key(f["path"]))
end

"""Consolidate a reviewed folder scan into one source, preserving original files.

An explicit primary chooses the analysis header only. It never overrides a
conflicting GRID, element, property, coordinate system or material definition.
"""
function reference_folder_source(directory;primary=nothing,primary_file=nothing,selected_files=nothing,expected_scan=nothing,ignore_unresolved_includes=false)
    primary!==nothing&&primary_file!==nothing&&primary!=primary_file&&throw(ArgumentError("Choose only one primary analysis file."))
    primary=primary_file===nothing ? primary : primary_file
    scan=reference_folder_scan(directory;ignore_unresolved_includes);root=scan["directory"]
    expected=expected_scan isa AbstractDict ? get(expected_scan,"fingerprint",get(expected_scan,"scan_signature",get(expected_scan,"scan_id",nothing))) : expected_scan
    expected===nothing||String(expected)==scan["fingerprint"]||throw(ArgumentError("The folder contents changed since the preview. Scan again and review the file list before importing."))
    chosen=_reference_folder_chosen(scan,selected_files);selected=Set(_reference_folder_key(f["path"]) for f in chosen)
    sources=Any[];headers=Dict{String,String}();warnings=String.(scan["warnings"])
    for f in chosen
        path=joinpath(root,f["path"]);text=_reference_folder_read(path)
        bytes2hex(SHA.sha256(codeunits(text)))==f["sha256"]||throw(ArgumentError("$(f["path"]) changed while preparing the import. Scan again."))
        for (target,line) in _reference_folder_includes(text,path,root;ignore_unresolved_includes,warnings)
            relative=replace(relpath(target,root),'\\'=>'/')
            _reference_folder_key(relative) in selected||throw(ArgumentError("$(f["path"]):$line includes $relative, which is excluded from the selected fragments. Include that file in the selection or deselect its parent."))
        end
        header,cards=_reference_folder_parts(text,f["path"];ignore_unresolved_includes)
        meaningful=join((uppercase(strip(first(split(line,'$';limit=2)))) for line in header if !isempty(strip(first(split(line,'$';limit=2))))),"\n")
        isempty(meaningful)||(headers[f["path"]]=meaningful)
        push!(sources,(file=f["path"],header=header,cards=cards))
    end
    candidates=sort!(collect(keys(headers)))
    chosen_primary=nothing
    if primary!==nothing&&!isempty(strip(String(primary)))
        key=_reference_folder_key(replace(normpath(String(primary)),'\\'=>'/'))
        chosen_primary=findfirst(path->_reference_folder_key(path)==key,candidates)
        chosen_primary===nothing&&throw(ArgumentError("The primary file must be a selected file containing an analysis header. Available choices: $(join(candidates,", "))."))
        chosen_primary=candidates[chosen_primary]
    elseif !isempty(candidates)
        if length(unique(values(headers)))>1
            throw(ArgumentError("The folder contains different executive/case-control headers in $(join(candidates,", ")). Select the primary analysis file in the folder preview. Other headers will be omitted; their bulk cards will still be checked for conflicts."))
        end
        chosen_primary=first(candidates)
    end
    length(candidates)>1&&primary!==nothing&&push!(warnings,"Analysis header taken from $chosen_primary. Headers from $(length(candidates)-1) other complete decks were omitted; their bulk data were still checked.")
    definitions=Dict{Tuple{String,String},Any}();seen_nonunique=Dict{String,String}();deduplicated=0;kept=0;chunks=String[]
    for source in sources
        rows=String["\$ Folder fragment: "*source.file]
        for card in source.cards
            isempty(card.kind)&&(push!(rows,card.raw);continue)
            canonical=card.kind*"\0"*join(_reference_folder_token.(card.fields),"\0")
            entities=_reference_folder_entities(card)
            for entity in entities
                if haskey(definitions,entity)
                    previous=definitions[entity]
                    previous.canonical==canonical||throw(ArgumentError("Conflicting $(entity[1]) ID $(entity[2]): $(previous.file):$(previous.line) ($(previous.kind)) and $(source.file):$(card.line) ($(card.kind)). Both definitions cannot be combined. Deselect one conflicting file, correct/renumber the conflicting entity and its references in an independent copy, or import the models separately. Choosing a primary header never overwrites model entities."))
                end
            end
            if !isempty(entities)&&all(entity->haskey(definitions,entity),entities)
                deduplicated+=1;continue
            end
            for entity in entities
                definitions[entity]=(canonical=canonical,file=source.file,line=card.line,kind=card.kind)
            end
            if isempty(entities)
                if haskey(seen_nonunique,canonical)&&seen_nonunique[canonical]!=source.file
                    push!(warnings,"Identical $(card.kind) cards occur in $(seen_nonunique[canonical]) and $(source.file):$(card.line). Both were retained because repeated load/constraint cards may intentionally add; review their combined effect.")
                end
                get!(seen_nonunique,canonical,source.file)
            end
            push!(rows,card.raw);kept+=1
        end
        push!(chunks,join(rows,"\n"))
    end
    header=chosen_primary===nothing ? String[] : only(source.header for source in sources if source.file==chosen_primary)
    # INCLUDE lines in a header are also fulfilled by the collected file union.
    cleanheader=String[];pending=false
    for line in header
        stripped=strip(line)
        ignore_unresolved_includes&&pending&&_reference_folder_bulk_start(stripped)&&(pending=false)
        if pending||occursin(r"^INCLUDE(?:\s|,|$)"i,stripped)
            pending=(count(==('\''),stripped)%2==1||count(==('"'),stripped)%2==1) ? !pending : pending
            continue
        end
        push!(cleanheader,line)
    end
    provenance=String["\$ JFEM-Boxer folder collection: $(length(chosen)) source files; $kept retained cards; $deduplicated identical entity definitions removed.",
        "\$ Folder scan SHA256: $(scan["fingerprint"])","\$ Primary analysis file: $(something(chosen_primary,"bulk data only; no analysis header selected"))"]
    append!(provenance,["\$ Collection source: "*f["path"] for f in chosen])
    append!(provenance,["\$ Collection warning: "*replace(warning,'\n'=>' ') for warning in unique(warnings)])
    text=join(vcat(provenance,cleanheader,["BEGIN BULK"],chunks,["ENDDATA",""]),"\n")
    summary=Dict{String,Any}("files"=>length(chosen),"source_files"=>[f["path"] for f in chosen],"cards"=>kept,
        "deduplicated_cards"=>deduplicated,"primary_file"=>chosen_primary,"warnings"=>unique(warnings),"scan_signature"=>scan["fingerprint"],"ignore_unresolved_includes"=>ignore_unresolved_includes)
    Dict{String,Any}("kind"=>"reference","format"=>"reference","name"=>basename(root)*"_consolidated.bdf","text"=>text,
        "flattened"=>text,"includes"=>Any[],"summary"=>summary,"source_file_count"=>length(chosen),
        "source_bytes"=>sum(f["expanded_bytes"] for f in chosen),"signature"=>bytes2hex(SHA.sha256(text)))
end
