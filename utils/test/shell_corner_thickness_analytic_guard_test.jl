using Test, OpenJFEM

@testset "Corner-thickness analytic entry guards" begin
    S=OpenJFEM.Solver
    function model_for_ti(raw; flag=0, kind="CQUAD4")
        n=kind=="CTRIA3" ? 3 : 4
        el=Dict{String,Any}("ID"=>37,"PID"=>1,"TYPE"=>kind,"NODES"=>collect(1:n),"TFLAG"=>flag)
        raw===nothing || (el["CORNER_THICKNESSES"]=raw)
        Dict{String,Any}("SOL"=>101,"CSHELLs"=>Dict("37"=>el),
            "PSHELLs"=>Dict("1"=>Dict{String,Any}("TYPE"=>"PSHELL","T"=>.003,"MID"=>1)),
            "MATs"=>Dict("1"=>Dict("TYPE"=>"MAT1","E"=>70e9,"NU"=>.3)))
    end
    function failure_of(f)
        try f(); nothing catch err; err end
    end
    methods=(
        (:static_compliance_thickness_gradient,0),
        (:static_displacement_thickness_gradient,1),
        (:static_compliance_design_gradient,2),
        (:static_displacement_design_gradient,3),
        (:static_ks_displacement_design_gradient,3),
        (:static_ks_von_mises_design_gradient,3),
        (:static_ks_ply_failure_design_gradient,3),
        (:structural_mass_design_gradient,2),
        (:buckling_load_factor_thickness_gradient,0),
        (:buckling_load_factor_design_gradient,2),
        (:buckling_load_factor_ks_design_gradient,2),
        (:modal_eigenvalue_design_gradient,2))
    extra(kind)=kind==0 ? () : kind==1 ? (Dict{String,Any}(),) :
        kind==2 ? (Any[],) : (Dict{String,Any}(),Any[])
    explicit_models=[model_for_ti(fill(.004,4)),
        model_for_ti([.002,.003,.004,.005]),
        model_for_ti(fill(1.3,4);flag=1),
        model_for_ti([1.,1.2,.8,1.5];flag=1),
        model_for_ti([nothing,.004,nothing,nothing]),
        model_for_ti(fill(.004,3);kind="CTRIA3")]
    for model in explicit_models
        snapshot=deepcopy(model)
        callbacks=Function[()->S.assert_no_corner_thickness_analytic(model),
            ()->S.AnalyticShellCapture(model),
            ()->S.solve_adjoint(Dict{String,Any}("model"=>model,"sol_type"=>101),"unused.json"),
            ()->S.solve_adjoint_buckling(Dict{String,Any}("model"=>model,"sol_type"=>105),"unused.json")]
        result=Dict{String,Any}("model"=>model)
        for (name,kind) in methods
            f=getfield(OpenJFEM,name);args=extra(kind)
            push!(callbacks,()->f(result,args...))
            push!(callbacks,()->f(OpenJFEM.TACSFormulationBackend(),result,args...))
        end
        for f in callbacks
            err=failure_of(f)
            @test err isa ArgumentError
            @test occursin("shell 37 with explicit corner thickness Ti",sprint(showerror,err))
        end
        err=failure_of(()->OpenJFEM._tacs_validate_shell_slice(model))
        @test err isa ArgumentError
        @test occursin("forward analysis does not support explicit corner thickness Ti",sprint(showerror,err))
        @test model==snapshot
    end
    for model in (model_for_ti(nothing),model_for_ti(fill(nothing,4)),
                  model_for_ti(fill(nothing,4);flag=1),Dict{String,Any}())
        @test S.assert_no_corner_thickness_analytic(model)===nothing
        @test S.AnalyticShellCapture(model).model===model
        if haskey(model,"CSHELLs")
            @test OpenJFEM._tacs_validate_shell_slice(model)===nothing
        end
        # Each ordinary wrapper must still reach its established backend route.
        result=Dict{String,Any}("model"=>model)
        for (name,kind) in methods
            err=failure_of(()->getfield(OpenJFEM,name)(result,extra(kind)...))
            @test err isa ErrorException
            @test occursin("not implemented for backend",sprint(showerror,err))
        end
    end
end
