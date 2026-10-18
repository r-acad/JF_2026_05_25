using Test
if !isdefined(@__MODULE__,:W)
    include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
    const W=WingFEGen
end
if !isdefined(@__MODULE__,:N)
    repo,_=W.find_jfem(dirname(@__DIR__))
    include(joinpath(@__DIR__,"..","src","native_solver_loader.jl"))
    const N=load_cached_jfem(repo)
end

@testset "Geometric nonlinear activation in generated and converted decks" begin
    mktempdir() do folder
        text="""
SOL 101
CEND
SUBCASE 17
 SPC=2
 LOAD=4
BEGIN BULK
GRID,11,,0.,0.,0.
GRID,25,,1.,0.,0.
GRID,38,,1.,.5,0.
GRID,49,,0.,.5,0.
CQUAD4,701,123,11,25,38,49
PSHELL,123,8,.02,8,,8
MAT1,8,7.e10,,.3,2700.
SPC1,2,123456,11,49
FORCE,4,25,0,100.,0.,0.,1.
FORCE,4,38,0,100.,0.,0.,1.
ENDDATA
"""
        for explicit in (nothing,-1,0,1)
            source_text=explicit===nothing ? text : replace(text,"BEGIN BULK"=>"BEGIN BULK\nPARAM,LGDISP,$explicit")
            path=joinpath(folder,"source.bdf");write(path,source_text)
            parsed=Base.invokelatest(N.bdf_to_model,path)
            source=W.imported_source(Dict("name"=>"source.bdf","text"=>source_text))
            model=W.imported_model(parsed,source,W.default_params())
            Base.invokelatest(W.imported_prepare_loads!,N,model)
            expected=explicit===nothing ? 1 : explicit
            variant=W.imported_analysis_model(model,Dict("solution"=>"106","follower"=>"fixed"))
            analysis=variant.params["imported.analysis_deck"]
            sensitivity=W.imported_sensitivity_deck(model,17,"106")
            for (name,deck) in (("analysis",analysis),("sensitivity",sensitivity))
                destination=joinpath(folder,name*".bdf");write(destination,deck)
                native=Base.invokelatest(N.bdf_to_model,destination)
                @test native["SOL"]==106
                @test native["PARAM_LGDISP"]==expected
                @test native["GRIDs"]==parsed["GRIDs"]
                @test native["CSHELLs"]==parsed["CSHELLs"]
                @test length(collect(eachmatch(r"PARAM\s*,\s*LGDISP"i,deck)))==1
            end
            @test model.params["imported.source"]["flattened"]==source_text
        end
        p=merge(W.default_params(),Dict{String,Any}(
            "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
            "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
            "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.3,
            "mesh.elements_between_ribs"=>1,"mesh.elements_between_stringers"=>1,
            "fuel.enabled"=>false,"loads.cases"=>Any[],"output.solution"=>"106"))
        model=W.build_model(p)
        io=IOBuffer();W.write_deck(IOContext(io,:full_precision=>true),model;frozen_load_cases=Any[])
        generated=String(take!(io));path=joinpath(folder,"generated.bdf");write(path,generated)
        native=Base.invokelatest(N.bdf_to_model,path)
        @test native["SOL"]==106
        @test native["PARAM_LGDISP"]==1
        @test length(collect(eachmatch(r"PARAM\s*,?\s*LGDISP"i,generated)))==1
        bundled=joinpath(@__DIR__,"..","..","..","utils","examples","precompile","sol106_quad_nonlinear.bdf")
        warmup=Base.invokelatest(N.bdf_to_model,bundled)
        @test warmup["PARAM_LGDISP"]==1
        result=Base.invokelatest(N.solve_model,warmup)
        diag=only(result["subcases"])["nonlinear_diagnostics"]
        @test diag["converged"]
        @test diag["nonlinear_method"]=="formal_shell_green_lagrange"
    end
end
