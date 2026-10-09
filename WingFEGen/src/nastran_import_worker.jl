# A parser-only service, deliberately separate from analysis workers. Keeping
# it warm avoids paying Julia compilation for every Open/Load Study operation.
const IMPORT_SERVICE=length(ARGS)==4&&ARGS[1]=="--serve"
(IMPORT_SERVICE||length(ARGS)==3)||error("Expected [--serve] import directory, native repository and generator root")
const IMPORT_DIR,IMPORT_REPO,IMPORT_APP=abspath.(IMPORT_SERVICE ? ARGS[2:4] : ARGS)
include(joinpath(@__DIR__,"native_solver_loader.jl"))
const ImportNative=load_cached_jfem(IMPORT_REPO)
push!(LOAD_PATH,IMPORT_APP)
include(joinpath(IMPORT_APP,"src","WingFEGen.jl"))
const W=WingFEGen

function import_one(directory)
    started=time();timings=Dict{String,Float64}()
    stage(label)=write(joinpath(directory,"stage.txt"),label)
    try
        stage("Reading captured Nastran source")
        source,params=if isfile(joinpath(directory,"input.jls"))
            W.Serialization.deserialize(joinpath(directory,"input.jls"))
        else
            (W.JSON.parsefile(joinpath(directory,"source.json")),W.JSON.parsefile(joinpath(directory,"params.json")))
        end
        # Parse once, retaining the same native inventory used to build the model.
        # bdf_to_model followed by process_cards parsed the full deck twice.
        t=time();stage("Parsing Nastran cards and case control")
        lines=readlines(IOBuffer(source["flattened"]))
        lines=Base.invokelatest(ImportNative.NastranParser.convert_mystran_to_nastran,lines)
        cc,bulk=Base.invokelatest(ImportNative.NastranParser.read_bulk_and_case,lines)
        cards=Base.invokelatest(ImportNative.NastranParser.process_cards,bulk)
        timings["parse_seconds"]=time()-t
        t=time();stage("Building native geometry, materials and properties")
        model=Base.invokelatest(ImportNative.build_model,cards,cc)
        Base.invokelatest(ImportNative.resolve_nested_coords!,model)
        Base.invokelatest(ImportNative.transform_geometry!,model)
        timings["native_model_seconds"]=time()-t
        t=time();stage("Preparing viewport geometry and element axes")
        imported=W.imported_model(model,source,params;cards)
        W.imported_prepare_inventory!(ImportNative,imported,cards,joinpath(directory,"card_inventory.log"))
        timings["viewer_model_seconds"]=time()-t
        t=time();stage("Preparing source load vectors (no analysis is run)")
        Base.invokelatest(W.imported_prepare_loads!,ImportNative,imported)
        timings["loads_seconds"]=time()-t
        t=time();stage("Packing imported geometry")
        W.Serialization.serialize(joinpath(directory,"model.jls"),imported)
        payload=W.imported_mesh_payload(imported)
        # Preserve Blob wrappers across the worker boundary. Unpacking and then
        # repacking MessagePack converts bin buffers into arrays of byte values,
        # corrupting every browser Float32/Int32 coordinate/connectivity array.
        W.Serialization.serialize(joinpath(directory,"payload.jls"),payload)
        write(joinpath(directory,"payload.msgpack"),W.MsgPack.pack(payload))
        timings["payload_seconds"]=time()-t;timings["worker_seconds"]=time()-started
        W.sensitivity_json_write(joinpath(directory,"timings.json"),timings)
    catch err
        W.sensitivity_json_write(joinpath(directory,"error.json"),Dict("error"=>sprint(showerror,err,catch_backtrace())))
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
