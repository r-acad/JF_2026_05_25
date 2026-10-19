# A parser-only service, deliberately separate from analysis workers. Keeping
# it warm avoids paying Julia compilation for every Open/Load Study operation.
const IMPORT_SERVICE=length(ARGS)==4&&ARGS[1]=="--serve"
(IMPORT_SERVICE||length(ARGS)==3)||error("Expected [--serve] import directory, native repository and generator root")
const IMPORT_DIR,IMPORT_REPO,IMPORT_APP=abspath.(IMPORT_SERVICE ? ARGS[2:4] : ARGS)
const IMPORT_BOOT_STARTED=time()
bootstrap_stage(label)=write(joinpath(IMPORT_DIR,"bootstrap_stage.txt"),label)
bootstrap_stage("Loading input parsers and model definitions; no solver is started")
include(joinpath(@__DIR__,"native_solver_loader.jl"))
include(joinpath(@__DIR__,"reference_import_native_runtime.jl"))
const IMPORT_NATIVE_SECONDS=time()-IMPORT_BOOT_STARTED
bootstrap_stage("Loading lightweight JFEM-Boxer geometry and viewport support")
include(joinpath(@__DIR__,"reference_import_runtime.jl"))
const W=WingFEGen
import_json_write(path,data)=write(path,W.JSON.json(data))
import_json_write(joinpath(IMPORT_DIR,"runtime.json"),Dict(
    "project"=>Base.active_project(),"image"=>unsafe_string(Base.JLOptions().image_file),
    "manifest_sha256"=>bytes2hex(W.SHA.sha256(read(joinpath(IMPORT_REPO,"Manifest.toml")))),
    "runtime"=>"import-only","repository"=>IMPORT_REPO,
    "packages"=>Dict("JSON"=>string(Base.pkgversion(W.JSON)),
        "MsgPack"=>string(Base.pkgversion(W.MsgPack)),"CodecZlib"=>string(Base.pkgversion(W.CodecZlib))),
    "loaded_packages"=>sort!([String(id.name) for id in keys(Base.loaded_modules)])))
const IMPORT_BOOT_TIMINGS=Dict("native_startup_seconds"=>IMPORT_NATIVE_SECONDS,
    "viewer_startup_seconds"=>time()-IMPORT_BOOT_STARTED-IMPORT_NATIVE_SECONDS,
    "bootstrap_seconds"=>time()-IMPORT_BOOT_STARTED)
import_json_write(joinpath(IMPORT_DIR,"bootstrap_timings.json"),IMPORT_BOOT_TIMINGS)

function import_one(directory)
    started=time();timings=Dict{String,Float64}()
    queued=joinpath(directory,"queued_at.txt")
    isfile(queued)&&(timings["queue_and_initial_compile_seconds"]=started-parse(Float64,read(queued,String)))
    stage(label)=write(joinpath(directory,"stage.txt"),label)
    try
        stage("Reading captured model source")
        source,params=if isfile(joinpath(directory,"input.jls"))
            W.Serialization.deserialize(joinpath(directory,"input.jls"))
        else
            (W.JSON.parsefile(joinpath(directory,"source.json")),W.JSON.parsefile(joinpath(directory,"params.json")))
        end
        # Parse once, retaining the same native inventory used to build the model.
        # bdf_to_model followed by process_cards parsed the full deck twice.
        t=time();abaqus=get(source,"format","reference")=="abaqus";cards=Dict();analysis_text=source["flattened"]
        stage(abaqus ? "Parsing Abaqus nodes, elements, sets and analysis steps" : "Parsing Reference cards and case control")
        if abaqus
            document=Base.invokelatest(ImportNative.abaqus_parse_input,analysis_text;source_path=source["name"],strict=false)
            completion=get(source,"completion",nothing)
            if completion!==nothing&&get(completion,"enabled",false)
                analysis_text=Base.invokelatest(ImportNative.abaqus_complete_input,document,completion)
                document=Base.invokelatest(ImportNative.abaqus_parse_input,analysis_text;source_path=source["name"],strict=false)
            end
            timings["parse_seconds"]=time()-t;t=time();stage("Building native Abaqus geometry and section assignments")
            model=Base.invokelatest(ImportNative.abaqus_to_model,document;require_analysis=false)
            model["abaqus_import"]["inventory"]=get(document,"inventory",Dict())
            for el in values(document["elements"])
                card=String(el["type"]);push!(get!(cards,card,Any[]),el)
            end
        else
            lines=readlines(IOBuffer(analysis_text))
            lines=Base.invokelatest(ImportNative.ReferenceParser.convert_mystran_to_reference,lines)
            cc,bulk=Base.invokelatest(ImportNative.ReferenceParser.read_bulk_and_case,lines)
            cards=Base.invokelatest(ImportNative.ReferenceParser.process_cards,bulk)
            timings["parse_seconds"]=time()-t;t=time();stage("Building native geometry, materials and properties")
            model=Base.invokelatest(ImportNative.build_model,cards,cc)
            Base.invokelatest(ImportNative.resolve_nested_coords!,model)
            Base.invokelatest(ImportNative.transform_geometry!,model)
        end
        timings["native_model_seconds"]=time()-t
        t=time();stage("Preparing viewport geometry and element axes")
        imported=Base.invokelatest(W.imported_model,model,source,params;cards)
        if abaqus
            imported.params["imported.analysis_ready"]=get(model["abaqus_import"],"analysis_ready",false)
            imported.params["imported.abaqus"]=model["abaqus_import"]
            imported.params["imported.analysis_deck"]=analysis_text
        else
            Base.invokelatest(W.imported_prepare_inventory!,ImportNative,imported,cards,joinpath(directory,"card_inventory.log"))
        end
        timings["viewer_model_seconds"]=time()-t
        t=time();stage("Preparing source load vectors (no analysis is run)")
        load_runtime=if Base.invokelatest(ImportNative.needs_numerical_load_runtime,model)
            stage("Loading numerical mass/beam operators for selected source load arrows; no analysis is run")
            load_cached_jfem(IMPORT_REPO)
        else
            ImportNative
        end
        Base.invokelatest(W.imported_prepare_loads!,load_runtime,imported)
        timings["loads_seconds"]=time()-t
        t=time();stage("Preparing complete viewport properties and binary geometry")
        payload=Base.invokelatest(W.imported_mesh_payload,imported)
        timings["payload_seconds"]=time()-t
        token=bytes2hex(W.SHA.sha256(source["signature"]*directory))
        imported.params["imported.token"]=token;payload["imported_deck"]["token"]=token
        payload["model_source"]=Dict(key=>source[key] for key in ("kind","name","text","includes","format","completion") if haskey(source,key))
        for key in ("source_file_count","source_bytes");payload["imported_deck"][key]=get(source,key,key=="source_file_count" ? 1 : sizeof(source["text"]));end
        t=time();stage("Caching authoritative native cards for later analysis")
        nativepath=joinpath(directory,"native.jls")
        W.Serialization.serialize(nativepath,model)
        timings["native_cache_seconds"]=time()-t
        t=time();stage("Caching lightweight viewer model")
        imported.params["imported.native"]=nothing;imported.params["imported.native_path"]=nativepath
        W.Serialization.serialize(joinpath(directory,"model.jls"),imported)
        timings["viewer_cache_seconds"]=time()-t
        t=time();stage("Encoding complete model for the browser")
        payload["generate_seconds"]=time()-started
        payload["import_timings"]=merge(copy(IMPORT_BOOT_TIMINGS),timings)
        # Encode once in the worker. The HTTP server sends these bytes directly;
        # it must not deserialize and re-encode 150,000 property dictionaries.
        write(joinpath(directory,"payload.msgpack"),W.MsgPack.pack(payload))
        timings["encode_seconds"]=time()-t;timings["worker_seconds"]=time()-started
        import_json_write(joinpath(directory,"timings.json"),merge(copy(IMPORT_BOOT_TIMINGS),timings))
    catch err
        import_json_write(joinpath(directory,"error.json"),Dict("error"=>sprint(showerror,err,catch_backtrace())))
        showerror(stderr,err,catch_backtrace());println(stderr)
    finally
        write(joinpath(directory,"done.txt"),"done")
    end
end

function serve_imports()
    lastused=time();request=joinpath(IMPORT_DIR,"request.txt")
    write(joinpath(IMPORT_DIR,"ready.txt"),"ready")
    # The parser expires after 30 idle minutes; analysis workers are separate.
    while time()-lastused<1800
        if isfile(request)
            directory=strip(read(request,String));rm(request);lastused=time()
            open(joinpath(directory,"import.log"),"w") do output
                redirect_stdout(output) do
                    redirect_stderr(output) do
                        Base.invokelatest(import_one,directory)
                    end
                end
            end
            lastused=time()
        else
            sleep(.1)
        end
    end
end

if IMPORT_SERVICE
    serve_imports()
else
    import_one(IMPORT_DIR)
    isfile(joinpath(IMPORT_DIR,"error.json"))&&exit(1)
end
