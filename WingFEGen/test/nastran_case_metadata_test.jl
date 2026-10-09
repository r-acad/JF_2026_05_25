using Test, LinearAlgebra, SparseArrays
using OpenJFEM
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen
const N=OpenJFEM
const IMPORT_CASE_SOURCE="""
SOL 101
CEND
TITLE = Boundary inspection study
SPC = 100
SUBCASE 7
    LABEL = Root clamps
    SUBTITLE = Main support and imposed rotation
    LOAD = 30
    DISPLACEMENT(PRINT,PLOT) = ALL
SUBCASE 23
    LABEL = Alternate supports
    SPC = 3
    LOAD = 31
BEGIN BULK
PARAM,AUTOSPC,NO
GRID,11,,0.,0.,0.,,3
GRID,25,,1.,0.,0.,7
GRID,38,,1.,.5,0.
GRID,49,,0.,.5,0.
CORD2R,7,0,0.,0.,0.,0.,0.,1.
+,0.,1.,0.
CQUAD4,701,123,11,25,38,49
PSHELL,123,8,.02,8,,8
MAT1,8,7.0E10,,.3,2700.
SPC1,1,126,11
SPC,2,25,4,.02
SPC1,100,5,49
SPCADD,100,1,2
SPC1,3,56,38
FORCE,10,25,0,100.,0.,0.,1.
MOMENT,11,38,0,5.,0.,1.,0.
LOAD,30,2.,.5,10,3.,11,.25,32
FORCE,31,38,0,-40.,0.,0.,1.
SPCD,32,25,4,.01
PLOTEL,900,11,25
ENDDATA
"""
function imported_case_test_model(directory)
    source=W.imported_source(Dict("name"=>"case_boundaries.bdf","text"=>IMPORT_CASE_SOURCE))
    lines=readlines(IOBuffer(source["flattened"]));cc,bulk=N.NastranParser.read_bulk_and_case(lines);cards=N.NastranParser.process_cards(bulk)
    native=N.build_model(cards,cc);N.resolve_nested_coords!(native);N.transform_geometry!(native)
    model=W.imported_model(native,source,W.default_params();cards)
    W.imported_prepare_inventory!(N,model,cards,joinpath(directory,"inventory.log"))
    W.imported_prepare_loads!(N,model)
    model,W.imported_mesh_payload(model)
end

@testset "Imported source cases and native boundary selections" begin
 mktempdir() do directory
    model,payload=imported_case_test_model(directory);native=W.imported_native(model)
    firstcase,secondcase=payload["load_cases"]
    @test model.spc==[1,2,3] # Selected-case union includes permanent PS, excludes unused SID100 GRID49.
    @test firstcase["label"]=="Root clamps"
    @test secondcase["label"]=="Alternate supports"
    @test firstcase["case_control"]["TITLE"]=="Boundary inspection study"
    @test firstcase["case_control"]["DISPLACEMENT_MODIFIER"]=="PRINT,PLOT"
    @test firstcase["spc"]["expanded_sets"]==[1,2]
    @test firstcase["spc"]["count"]==2
    @test firstcase["spc"]["constrained_dofs"]==5
    @test [row["grid"] for row in firstcase["spc"]["assignments"]]==[11,25]
    @test firstcase["spc"]["assignments"][1]["components"]=="1236"
    @test firstcase["spc"]["assignments"][2]["values"]["4"]==.005
    @test firstcase["spc"]["assignments"][2]["coordinate_id"]==7
    @test firstcase["spc"]["assignments"][2]["axes"][1]≈[0.,1.,0.]
    @test secondcase["spc"]["expanded_sets"]==[3]
    @test [row["grid"] for row in secondcase["spc"]["assignments"]]==[11,38]
    @test secondcase["spc"]["node_components"]==["3","56"]
    @test firstcase["loads"]["force_stations"][1]["force"]==[0.,0.,100.]
    @test firstcase["loads"]["moment_stations"][1]["moment"]==[0.,30.,0.]
    @test only(filter(row->row["type"]=="SPCD",firstcase["load_cards"]))["scale"]==.5
    @test only(payload["imported_deck"]["unprocessed_cards"])["name"]=="PLOTEL"
    @test occursin("PLOTEL,900",model.params["imported.source"]["flattened"])

    # Native static and eigen boundary paths share the same selected sets.
    # A diagonal positive matrix makes the constrained partition unambiguous.
    index=Dict(gid=>i for (i,gid) in enumerate(model.node_ids));K=spdiagm(0=>ones(24));mapping=Dict{Int,Any}()
    @test N.Solver.selected_spc_sets(native,100)==Set([1,2]) # SPCADD overrides SPC1 SID100.
    free,fixed=N.Solver.compute_free_dofs(K,24,native,index,100,mapping;allow_factorization_autospc=false)
    @test fixed==Set([1,2,3,6,10])
    @test length(free)==19
    native["_spc_id"]=100
    u,staticfixed,spc,diagnostics=N.Solver.apply_bc_and_solve(K,24,native,index,ones(24),[Matrix{Float64}(I,3,3) for _ in 1:4],mapping,ones(24),ones(24))
    @test staticfixed==fixed
    @test u[10]==.02 # Direct SPC value; SPCD is handled by the selected-load solve.
    @test all(u[i]==1 for i in free)

    # A selected SPCD must replace the nonzero SPC, not add a second
    # equivalent RHS. Couple its DOF to a free coordinate so the old bug
    # cannot hide behind a diagonal matrix. Exercise varying values through
    # the same factorization cache, including zero and a case without SPCD.
    Kcoupled=spdiagm(0=>fill(2.,24));Kcoupled[10,9]=Kcoupled[9,10]=.4
    rotations=[Matrix{Float64}(I,3,3) for _ in 1:4]
    positions=permutedims(reshape(model.xyz,3,:))
    cache=N.Solver.create_linear_solve_cache()
    recovery=Dict{Int,Vector{Tuple{Int,Float64}}}(24=>[(10,2.)])
    withenv("JFEM_LINEAR_CACHE_MIN_NDOF"=>"0") do
        for (iteration,prescribed) in enumerate((.005,.015,0.))
            native["SPCDs"][1]["D"]=2prescribed # LOAD30 has scale .5 on SPCD32.
            _,_,_,displacement,_=N.Solver.solve_case(Kcoupled,24,native,index,positions,30,100,rotations;
                rbe3_map=recovery,linear_cache=cache,build_results=false)
            @test displacement[10]≈prescribed
            @test displacement[9]≈(100.0 - 0.4*prescribed)/2
            @test displacement[24]≈2prescribed # Recovery sees the actual prescribed motion.
            @test length(cache)==1
        end
        entry=only(values(cache));factor=entry.factor
        _,_,_,plain,_=N.Solver.solve_case(Kcoupled,24,native,index,positions,11,100,rotations;
            rbe3_map=recovery,linear_cache=cache,build_results=false)
        @test plain[10]≈.02
        @test plain[9]≈-.004
        @test length(cache)==2
        @test entry.factor===factor
        # Direct cached BC calls report cache hits and refresh each value.
        _,_,_,cached_diag=N.Solver.apply_bc_and_solve(Kcoupled,24,native,index,zeros(24),rotations,recovery,0.,Float64[];
            linear_cache=cache,enforced_overrides=Dict(10=>.007))
        @test cached_diag["linear_solver"]["cache_hit"]
        @test_throws ArgumentError N.Solver.apply_bc_and_solve(Kcoupled,24,native,index,zeros(24),rotations,recovery,0.,Float64[];
            linear_cache=cache,enforced_overrides=Dict(9=>.01))

        # Selecting a zero-scaled or cancelled SPCD is still an explicit
        # zero prescription; it must override the base SPC=.02.
        native["SPCDs"][1]["D"]=.01
        _,_,_,zero_scaled,_=N.Solver.solve_case(Kcoupled,24,native,index,positions,30,100,rotations;
            rbe3_map=recovery,linear_cache=cache,load_scale=0.,build_results=false)
        @test zero_scaled[10]==0.
        @test zero_scaled[9]==0.
        push!(native["LOAD_COMBOS"],Dict("SID"=>99,"S"=>1.,"COMPS"=>[Dict("LID"=>32,"S"=>1.),Dict("LID"=>32,"S"=>-1.)]))
        @test !haskey(N.Solver._load_sid_scales(native,99),32) # Ordinary force semantics unchanged.
        zero_scales=N.Solver._load_sid_scales(native,99;include_zero=true)
        @test zero_scales[32]==0.
        _,_,_,cancelled,_=N.Solver.solve_case(Kcoupled,24,native,index,positions,99,100,rotations;
            rbe3_map=recovery,linear_cache=cache,build_results=false)
        @test cancelled[10]==0.
        @test cancelled[9]==0.
        supports=W.imported_case_supports(N,model,Dict("SPC"=>100,"LOAD"=>99),zero_scales)
        @test supports["assignments"][2]["values"]["4"]==0.
        @test only(supports["enforced_displacements"])["value"]==0.
    end

    # SOL106 has no prescribed-motion kinematics: fail explicitly instead
    # of reporting a solution with the requested motion silently ignored.
    @test_throws ArgumentError N.Solver.solve_nonlinear_static(Kcoupled,24,native,index,positions,30,100,rotations)
    zero_spc=deepcopy(native)
    for entry in zero_spc["SPC1s"];haskey(entry,"D")&&(entry["D"]=0.);end
    @test_throws ArgumentError N.Solver._assert_nonlinear_prescribed_supported(zero_spc,30,100)
    @test N.Solver._assert_nonlinear_prescribed_supported(zero_spc,31,100)===nothing # Unselected SPCD.
    @test N.Solver._assert_nonlinear_prescribed_supported(zero_spc,99,100)===nothing # Cancelled net motion.
    zero_spc["SPCDs"][1]["D"]=0.
    @test N.Solver._assert_nonlinear_prescribed_supported(zero_spc,30,100)===nothing
    N._ensure_export_extensions!()
    @test Base.invokelatest(N.collect_spc_data,native,100)==Dict(11=>1236,25=>4)
    @test Base.invokelatest(N.collect_spc_data,native,nothing)==Dict(11=>3)
    @test_throws ArgumentError N.Solver.selected_spc_sets(native,999)
    native["SPCADDs"][200]=[100]
    @test_throws ArgumentError N.Solver.selected_spc_sets(native,200)
    native["SPCADDs"][201]=[201]
    @test_throws ArgumentError N.Solver.selected_spc_sets(native,201)
    native["SPCADDs"][202]=[999]
    @test_throws ArgumentError N.Solver.selected_spc_sets(native,202)
 end
end
