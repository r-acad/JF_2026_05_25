length(ARGS)==3||error("Expected import directory, native repository and generator root")
const IMPORT_DIR,IMPORT_REPO,IMPORT_APP=abspath.(ARGS)
push!(LOAD_PATH,IMPORT_APP)
include(joinpath(IMPORT_APP,"src","WingFEGen.jl"))
const W=WingFEGen
try
    include(joinpath(@__DIR__,"native_solver_loader.jl"))
    ImportNative=load_cached_jfem(IMPORT_REPO)
    source=W.JSON.parsefile(joinpath(IMPORT_DIR,"source.json"));params=W.JSON.parsefile(joinpath(IMPORT_DIR,"params.json"))
    path=joinpath(IMPORT_DIR,"imported.bdf");write(path,source["flattened"])
    model=Base.invokelatest(ImportNative.bdf_to_model,path)
    lines=readlines(path);cc,bulk=Base.invokelatest(ImportNative.NastranParser.read_bulk_and_case,lines)
    cards=Base.invokelatest(ImportNative.NastranParser.process_cards,bulk)
    imported=W.imported_model(model,source,params;cards)
    Base.invokelatest(W.imported_prepare_loads!,ImportNative,imported)
    W.Serialization.serialize(joinpath(IMPORT_DIR,"model.jls"),imported)
    write(joinpath(IMPORT_DIR,"payload.msgpack"),W.MsgPack.pack(W.imported_mesh_payload(imported)))
catch err
    W.sensitivity_json_write(joinpath(IMPORT_DIR,"error.json"),Dict("error"=>sprint(showerror,err,catch_backtrace())))
    rethrow()
end
