# UIUC's standard Selig-order coordinate archive. Network access happens only
# in these explicit catalogue/profile requests; saved models embed the tables.
const UIUC_AIRFOIL_URL = "https://m-selig.ae.illinois.edu/ads/coord_seligFmt/"
const UIUC_DATABASE_URL = "https://m-selig.ae.illinois.edu/ads/coord_database.html"
const AIRFOIL_CACHE_LOCK = ReentrantLock()

valid_uiuc_id(id) = occursin(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.dat$", id) && !occursin("..",id)

function fetch_airfoil_text(url)
    response = HTTP.get(url; request_timeout=30, connect_timeout=10, retry=false, status_exception=false)
    response.status == 200 || throw(ArgumentError("UIUC returned HTTP $(response.status)"))
    length(response.body) <= 4_000_000 || throw(ArgumentError("UIUC response exceeds 4 MB"))
    return String(response.body)
end

function write_airfoil_cache(path, text)
    lock(AIRFOIL_CACHE_LOCK)
    try
        mkpath(dirname(path)); temporary, io = mktemp(dirname(path))
        try
            write(io,text); close(io); Base.Filesystem.rename(temporary,path)
        finally
            isopen(io) && close(io)
            isfile(temporary) && rm(temporary)
        end
    finally
        unlock(AIRFOIL_CACHE_LOCK)
    end
end

function uiuc_catalogue(cache_dir; refresh=false, fetcher=fetch_airfoil_text)
    path=joinpath(cache_dir,"catalogue.json")
    cached=try isfile(path) ? JSON.parsefile(path) : nothing catch; nothing; end
    if cached!==nothing && !(cached isa AbstractDict && get(cached,"items",nothing) isa AbstractVector)
        cached=nothing
    end
    cached !== nothing && !refresh && return merge(cached,Dict("cached"=>true))
    try
        html=fetcher(UIUC_AIRFOIL_URL)
        ids=String[]
        for match in eachmatch(r"(?i)href\s*=\s*[\"']([^\"']+\.dat)[\"']",html)
            id=HTTP.URIs.unescapeuri(match.captures[1])
            valid_uiuc_id(id) && push!(ids,id)
        end
        sort!(unique!(ids);by=lowercase)
        length(ids)>=100 || throw(ArgumentError("UIUC catalogue did not contain a usable coordinate listing"))
        result=Dict{String,Any}("source_url"=>UIUC_DATABASE_URL,"directory_url"=>UIUC_AIRFOIL_URL,
            "fetched_at"=>string(Dates.now(Dates.UTC))*"Z","items"=>[Dict("id"=>id,"label"=>id[1:end-4]) for id in ids])
        write_airfoil_cache(path,JSON.json(result))
        return merge(result,Dict("cached"=>false))
    catch error
        cached === nothing && throw(ArgumentError("Cannot load the UIUC catalogue. Check the network connection; saved embedded profiles still work offline. "*sprint(showerror,error)))
        return merge(cached,Dict("cached"=>true,"warning"=>"Catalogue refresh failed; using the saved catalogue. "*sprint(showerror,error)))
    end
end

"""Parse Selig or count-prefixed Lednicer coordinates into two monotone tables."""
function parse_uiuc_airfoil(text::AbstractString; id::AbstractString, source_url=UIUC_AIRFOIL_URL*id)
    sizeof(text)<=2_000_000 || throw(ArgumentError("airfoil coordinate file exceeds 2 MB"))
    name=""; points=Tuple{Float64,Float64}[]; counts=nothing
    for (number,line) in enumerate(split(replace(text,'\x1a'=>""),'\n'))
        clean=strip(first(split(line,'#';limit=2)))
        isempty(clean) && continue
        words=split(replace(clean,','=>' '))
        numbers=length(words)==2 ? [tryparse(Float64,replace(word,'D'=>'E','d'=>'e')) for word in words] : [nothing]
        if length(numbers)==2 && all(v->v!==nothing&&isfinite(v),numbers)
            x,z=Float64.(numbers)
            if isempty(points) && counts===nothing && x>=3 && z>=3 && isinteger(x)&&isinteger(z)
                counts=(Int(x),Int(z));continue
            end
            push!(points,(x,z))
        elseif isempty(points) && counts===nothing && isempty(name)
            name=clean
        else
            throw(ArgumentError("$(id): invalid coordinate line $number; expected two finite numbers"))
        end
    end
    7<=length(points)<=40000 || throw(ArgumentError("$(id): expected 7 to 40000 airfoil coordinates"))
    if counts!==nothing
        sum(counts)==length(points) || throw(ArgumentError("$(id): Lednicer surface counts do not match the data"))
        a=points[1:counts[1]];b=points[counts[1]+1:end]
        a[1][1]>a[end][1] && reverse!(a)
        b[1][1]>b[end][1] && reverse!(b)
        hypot((a[1].-b[1])...)<=1e-5*max(a[end][1]-a[1][1],b[end][1]-b[1][1]) ||
            throw(ArgumentError("$(id): surfaces do not meet at the leading edge"))
        points=vcat(reverse(a),b[2:end])
    end
    te=(points[1].+points[end])./2
    # Farthest sampled point from the TE midpoint is invariant under unit
    # changes, offsets and rigid in-plane rotation; raw minimum x is not.
    nose=argmax([sum(abs2,p.-te) for p in points])
    3<=nose<=length(points)-2 || throw(ArgumentError("$(id): not a single closed-nose airfoil in Selig order"))
    le=points[nose]
    dx,dz=te.-le;chord=hypot(dx,dz)
    chord>1e-10 || throw(ArgumentError("$(id): zero chord"))
    normalized=[((dx*(p[1]-le[1])+dz*(p[2]-le[2]))/chord^2,
                 (-dz*(p[1]-le[1])+dx*(p[2]-le[2]))/chord^2) for p in points]
    function surface(values)
        x=first.(values);z=last.(values)
        abs(first(x))<1e-8 && abs(last(x)-1)<0.01 || throw(ArgumentError("$(id): surface does not span a full chord"))
        x[1]=0.0;x[end]=1.0;z[1]=0.0
        # Exact duplicate points are common in exported files; remove them.
        keep=Int[1]
        for i in 2:length(x)
            if abs(x[i]-x[keep[end]])<1e-10 && abs(z[i]-z[keep[end]])<1e-10
                continue
            end
            x[i]>x[keep[end]] || throw(ArgumentError("$(id): overhanging or multiple-element surfaces cannot be represented as z(x/c)"))
            push!(keep,i)
        end
        return x[keep],z[keep]
    end
    xu,zu=surface(reverse(normalized[1:nose]));xl,zl=surface(normalized[nose:end])
    if table_interp(xu,zu,.5)<table_interp(xl,zl,.5)
        xu,xl=xl,xu;zu,zl=zl,zu
    end
    profile=Dict{String,Any}("version"=>1,"id"=>String(id),"name"=>isempty(name) ? String(id) : name,
        "source"=>"UIUC Airfoil Coordinates Database","source_url"=>source_url,
        "fetched_at"=>string(Dates.now(Dates.UTC))*"Z","raw_sha256"=>bytes2hex(SHA.sha256(text)),
        "normalization"=>"Unit chord from the sampled leading edge to the trailing-edge midpoint; TE x/c aligned to 1, original gap retained.",
        "xu"=>xu,"zu"=>zu,"xl"=>xl,"zl"=>zl)
    af=airfoil_from_profile(profile);profile["thickness_ratio"]=af.thickness
    return profile
end

function uiuc_profile(id::AbstractString,cache_dir;refresh=false,fetcher=fetch_airfoil_text)
    valid_uiuc_id(id) || throw(ArgumentError("Invalid UIUC profile filename"))
    path=joinpath(cache_dir,id*".json")
    if isfile(path)&&!refresh
        try
            profile=JSON.parsefile(path);airfoil_from_profile(profile)
            return profile,true
        catch
            # A corrupt cache entry may be downloaded again; it is never used
            # as a substitute geometry or allowed to break saved model data.
        end
    end
    catalogue=uiuc_catalogue(cache_dir;fetcher)
    any(item["id"]==id for item in catalogue["items"]) || throw(ArgumentError("The UIUC catalogue does not contain $id"))
    text=fetcher(UIUC_AIRFOIL_URL*id)
    profile=parse_uiuc_airfoil(text;id)
    write_airfoil_cache(joinpath(cache_dir,id),text)
    write_airfoil_cache(path,JSON.json(profile))
    return profile,false
end

function handle_airfoils(st,req;profile=false)
    try
        query=HTTP.queryparams(HTTP.URI(req.target));cache=joinpath(st.deck_store_dir,"airfoils")
        refresh=get(query,"refresh","false")=="true"
        if profile
            data,cached=uiuc_profile(get(query,"id",""),cache;refresh)
            return json_response(Dict("ok"=>true,"profile"=>data,"cached"=>cached))
        end
        return json_response(merge(Dict("ok"=>true),uiuc_catalogue(cache;refresh)))
    catch error
        return error_response(sprint(showerror,error))
    end
end
