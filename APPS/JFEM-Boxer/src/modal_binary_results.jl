# SOL103 metadata JSON refers to its companion viewer binary. Read only the
# required displacement blocks; never expand them into per-GRID dictionaries.
function modal_binary_result_path(jsonpath,data)
    get(data,"mode_shape_status",nothing)=="available_binary" || return nothing
    storage=get(data,"mode_shape_storage",nothing)
    storage isa AbstractDict && get(storage,"format",nothing)=="jfem" ||
        throw(ArgumentError("Unsupported modal vector storage"))
    name=get(storage,"path",nothing)
    name isa AbstractString && !isempty(name) && basename(name)==name &&
        !occursin('/',name) && !occursin('\\',name) ||
        throw(ArgumentError("The modal binary must be a companion file in the results folder"))
    path=joinpath(dirname(jsonpath),name)
    isfile(path) || throw(ArgumentError("Modal vectors are missing: $path. Keep the .jfem file alongside its .BUCKLING.JSON metadata."))
    path
end

function modal_binary_vectors(jsonpath,data,idx::Dict{Int,Int},n::Int)
    path=modal_binary_result_path(jsonpath,data)
    path===nothing && return nothing
    open(path,"r") do io
        filebytes=filesize(path)
        function skip(count,width=1)
            bytes=Int128(count)*width
            0<=bytes<=filebytes-position(io) || throw(ArgumentError("Truncated modal binary: $path"))
            seek(io,position(io)+Int(bytes))
        end
        u32()=Int(ltoh(read(io,UInt32)))
        String(read(io,4))=="JFEM" || throw(ArgumentError("Invalid modal binary signature"))
        version=u32();version in 3:7 || throw(ArgumentError("Unsupported modal binary version $version"))
        nn,nq,nt,nb,nr,nm=[u32() for _ in 1:6]
        nc,nr2,nr3=[u32() for _ in 1:3]
        nte,nh,np=version>=4 ? [u32() for _ in 1:3] : (0,0,0)
        nn==n && nn==length(idx) || throw(ArgumentError("Modal binary GRID count does not match the displayed model"))
        nn<=div(filebytes-position(io),16) || throw(ArgumentError("Truncated modal binary node table"))
        records=read!(io,Vector{UInt32}(undef,4nn))
        order=Vector{Int}(undef,nn);seen=falses(n)
        for i in 1:nn
            nid=Int(reinterpret(Int32,ltoh(records[4i-3])))
            target=get(idx,nid,0)
            1<=target<=n && !seen[target] || throw(ArgumentError("Modal binary GRID $nid does not match the displayed model"))
            order[i]=target;seen[target]=true
        end
        skip(nq,28);skip(nt,24);skip(nb+nr,20);skip(nc,28)
        for _ in 1:(nr2+nr3)
            skip(12);skip(u32(),4)
        end
        if version>=6
            for _ in 1:nte
                skip(8);count=u32()
                count in (4,10) || throw(ArgumentError("Unsupported modal binary tetrahedron"))
                skip(count,4)
            end
        else
            skip(nte,24)
        end
        skip(nh,40);skip(np,32)
        nm==length(get(data,"frequencies",Any[])) || throw(ArgumentError("Modal metadata and binary mode counts differ"))
        offsets=Vector{Int64}(undef,nm)
        for m in 1:nm
            u32()==m || throw(ArgumentError("Modal binary mode ordering is invalid"))
            offsets[m]=position(io)
            skip(nn,24);skip(nq+nt+nb,28);skip(nr,8);skip(nte+nh+np,4)
            skip(u32(),8);skip(u32(),16);skip(u32(),16)
        end
        String(read(io,4))=="EVAL" && u32()==nm || throw(ArgumentError("Missing modal binary frequency trailer"))
        frequencies=Float64[ltoh(read(io,Float64)) for _ in 1:nm]
        all(i->isfinite(frequencies[i]) && isapprox(frequencies[i],Float64(data["frequencies"][i]);rtol=1e-12,atol=1e-12),1:nm) ||
            throw(ArgumentError("Modal metadata frequencies do not match the companion binary"))
        vectors=Dict{Int,Any}()
        workspace=Vector{Float32}(undef,6nn)
        for md in get(data,"modes",Any[])
            m=Int(md["binary_mode_index"])
            1<=m<=nm || throw(ArgumentError("Modal vector index $m is outside its companion binary"))
            seek(io,offsets[m]);read!(io,workspace)
            shape=Vector{Float32}(undef,3n);rotation=similar(shape);maxsq=0.
            for i in 1:nn
                target=3(order[i]-1);source=6(i-1);squared=0.
                for d in 1:3
                    value=ltoh(workspace[source+d]);spin=ltoh(workspace[source+3+d])
                    isfinite(value) && isfinite(spin) || throw(ArgumentError("Nonfinite modal vector in mode $m"))
                    shape[target+d]=value;rotation[target+d]=spin;squared+=Float64(value)^2
                end
                maxsq=max(maxsq,squared)
            end
            vectors[Int(md["mode_number"])]=(shape=shape,rotation=rotation,max_disp=sqrt(maxsq))
        end
        vectors
    end
end
