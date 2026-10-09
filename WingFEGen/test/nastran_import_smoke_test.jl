# Portable native-parser integration, without solver jobs or private fixtures.
# julia --project=. WingFEGen/test/nastran_import_smoke_test.jl
using Test
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
repo,_=W.find_jfem(dirname(@__DIR__));repo===nothing&&error("Place WingFEGen inside the JFEM checkout")
push!(LOAD_PATH,repo)
include(joinpath(@__DIR__,"..","src","native_solver_loader.jl"))
const N=load_cached_jfem(repo)
const MAIN="SOL 101\nCEND\nSUBCASE 17\n SPC = 2\n LOAD = 4\nBEGIN BULK\nINCLUDE 'cards/panel.inc'\nENDDATA\n"
const BULK="""
GRID,11,,0.,0.,0.
GRID,25,,1.,0.,0.
GRID,38,,1.,.5,0.
GRID,49,,0.,.5,0.
CQUAD4,701,123,11,25,38,49
PSHELL,123,8,.02,8,,8
MAT1,8,7.0E10,,.3,2700.
SPC1,2,123456,11,49
FORCE,4,25,0,100.,0.,0.,1.
"""
@testset "Portable imported Nastran" begin
    raw=Dict("name"=>"main.bdf","text"=>MAIN,"includes"=>[Dict("name"=>"cards/panel.inc","text"=>BULK)])
    source=W.imported_source(raw)
    @test source["name"]=="main.bdf"&&source["text"]==MAIN&&source["includes"]==raw["includes"]
    @test startswith(source["flattened"],"SOL 101")&&endswith(source["flattened"],"ENDDATA\n")
    @test !occursin("INCLUDE",source["flattened"])
    @test_throws ArgumentError W.imported_source(Dict("name"=>"main.bdf","text"=>"INCLUDE '../secret.inc'"))
    mktempdir() do directory
        path=joinpath(directory,"main.bdf");write(path,source["flattened"])
        native=Base.invokelatest(N.bdf_to_model,path)
        m=W.imported_model(native,source,W.default_params())
        Base.invokelatest(W.imported_prepare_loads!,N,m)
        payload=W.imported_mesh_payload(m)
        @test m.node_ids==[11,25,38,49]
        @test only(m.groups).eids==[701]&&only(m.groups).pid==123
        @test only(payload["imported_deck"]["cases"])["id"]==17
        @test only(payload["imported_deck"]["cases"])["result_required"]
        @test only(payload["groups"])["card_types"]==Dict("701"=>"CQUAD4")
        @test only(payload["groups"])["properties"]["material"]["id"]==8
        @test payload["spc"]["node_components"]==["123456","123456"]
        @test only(payload["loads"]["force_stations"])["force"]==[0.,0.,100.]
        descriptor=only(filter(d->d["id"]=="nastran.MAT1#8#E",W.sensitivity_catalog(m)["variables"]))
        for marker in ("E1","G11")
            anisotropic=deepcopy(m);anisotropic.params["imported.native"]["MATs"]["8"][marker]=7e10
            @test !any(d->startswith(d["id"],"nastran.MAT1"),W.sensitivity_catalog(anisotropic)["variables"])
        end
        @test W.imported_derivative_coverage(m,descriptor)===nothing
        @test Base.invokelatest(W.imported_stress_fibers_supported,N,native["PSHELLs"]["123"])===nothing
        explicit=merge(native["PSHELLs"]["123"],Dict("Z1"=>-.01,"Z1_DEFAULT"=>false))
        @test_throws ArgumentError Base.invokelatest(W.imported_stress_fibers_supported,N,explicit)
        @test length(W.imported_section(Dict("TYPE"=>"ROD","DIMS"=>[.02]))["polygon_yz_m"])==4
        native["CRODs"]=Dict("900"=>Dict("ID"=>900,"PID"=>900,"TYPE"=>"CROD"));native["PRODs"]=Dict("900"=>Dict("MID"=>8))
        @test_throws ArgumentError W.imported_derivative_coverage(m,descriptor)
        native["PRODs"]["900"]["MID"]=9
        @test W.imported_derivative_coverage(m,descriptor)===nothing
        input=joinpath(directory,"input.toml");write(input,W.params_to_toml(W.default_params()))
        st=W.AppState(dirname(@__DIR__),input;deck_store_dir=joinpath(directory,"cache"))
        written,snapshot=W.imported_written_deck(st,m)
        @test read(written,String)==source["flattened"]
        @test W.read_deck_snapshot(st)["imported_signature"]==source["signature"]
        @test W.deck_metadata(snapshot)["imported_signature"]==source["signature"]
        # Native large-field coordinates must not be reinterpreted by the
        # small-field generated-wing topology reader during saved restoration.
        field(value)=rpad(string(value),16)
        grid="GRID*   "*field(11)*field(41)*field(0.)*field(0.)*"\n*       "*field(0.)*"\n"
        text=replace(source["flattened"],"GRID,11,,0.,0.,0.\n"=>grid)
        text=replace(text,"BEGIN BULK\n"=>"BEGIN BULK\nCORD2R,41,,2.,3.,4.,2.,3.,5.\n,3.,3.,4.\n")
        large_source=W.imported_source(Dict("name"=>"large.bdf","text"=>text));largepath=joinpath(directory,"baseline.bdf");write(largepath,text)
        large_native=Base.invokelatest(N.bdf_to_model,largepath);large=W.imported_model(large_native,large_source,W.default_params())
        @test large.xyz[1:3]≈[2.,3.,4.]
        metadata=Dict("format"=>"wingfegen-sensitivity-baseline-1","baseline_model_signature"=>W.sensitivity_model_signature(large),"baseline_model_signature_version"=>2,"baseline_topology_signature"=>W.sensitivity_topology_signature(large),"sha256"=>Dict("baseline.bdf"=>bytes2hex(W.SHA.sha256(text))))
        W.sensitivity_json_write(joinpath(directory,"baseline_manifest.json"),metadata)
        @test W.imported_saved_topology_matches(directory,large,metadata)
        write(largepath,text*"\n\$ changed\n")
        @test !W.imported_saved_topology_matches(directory,large,metadata)
    end
end
