using Test

module Sol106CoupledDispatchFixture
using Test, LinearAlgebra, OpenJFEM
const S=OpenJFEM.Solver

function checks()
    mktempdir() do dir
        deck=joinpath(dir,"coupled.bdf")
        write(deck,"""
SOL 101
CEND
BEGIN BULK
PARAM,K6ROT,100.
GRID,1,,-1.,-.5,0.
GRID,2,,1.,-.5,0.
GRID,3,,.7,.5,.005
GRID,4,,-.7,.5,0.
CQUAD4,1,10,1,2,3,4
MAT8,1,1.0E7,7.0E6,.25,3.0E6,2.0E6,1.3E6,1000.
PCOMP,10
+,1,.05,0.,YES,1,.05,45.,YES
ENDDATA
""")
        model=OpenJFEM.bdf_to_model(deck)
        K101,ids,X,ndof,R,_,mapping,normals,_=S.assemble_stiffness(model;sol101_context=true)
        legacy=deepcopy(model);legacy["SOL"]=106
        @test S.coupled_pcomp_legacy_nonlinear_enabled(legacy)
        @test !S.coupled_pcomp_legacy_nonlinear_enabled(model)
        cap=S.AnalyticShellCapture(legacy)
        K106,=S.assemble_stiffness(legacy;shell_capture=cap)
        @test K106≈K101 rtol=2e-13
        @test any(get(c.kwargs,:coupled_projected,false) for c in only(values(cap.contexts)).calls)
        u=1e-4sin.(collect(1.:ndof))
        kg(m,v)=S.assemble_geometric_stiffness(m,ids,X,R,ndof,v,normals,mapping)
        @test iszero(norm(kg(legacy,zeros(ndof))))
        @test kg(legacy,u)≈kg(model,u) rtol=2e-13
        # The legacy residual formula is unchanged. Its infinitesimal limit
        # must use the same coupled elastic energy as the linear static solve.
        h=1e-5
        fp=first(S._nonlinear_internal_force(K106,kg(legacy,h*u),h*u))
        fm=first(S._nonlinear_internal_force(K106,kg(legacy,-h*u),-h*u))
        @test (fp-fm)/(2h)≈K101*u rtol=2e-13
        function recovery(m)
            output=Dict{String,Any}(key=>Dict("quad4"=>Any[],"tria3"=>Any[])
                for key in ("forces","forces_bilin","stresses","strains"))
            S.recover_shell_stresses!(m,ids,X,R,u,normals,Dict{Int,Float64}(),output)
            output
        end
        @test recovery(legacy)==recovery(model)
        for method in ("formal","formal_shell_green_lagrange","green_lagrange",
                       "formal_shell_von_karman","formal_von_karman","formal_shell_vk")
            formal=deepcopy(legacy);formal["PARAM_NLMETHOD"]=method
            @test !S.coupled_pcomp_legacy_nonlinear_enabled(formal)
            capture=S.AnalyticShellCapture(formal)
            S.assemble_stiffness(formal;shell_capture=capture)
            @test all(!get(c.kwargs,:coupled_projected,false) for c in only(values(capture.contexts)).calls)
        end
        xy=X[:,1:2];B=model["PSHELLs"]["10"]["Bmb"]
        @test !S.coupled_pcomp_projected_enabled(xy,B;is_pcomp=true,sol_type=106)
        @test S.coupled_pcomp_projected_enabled(xy,B;is_pcomp=true,sol_type=106,legacy_nonlinear=true)
        @test !S.coupled_pcomp_projected_enabled(xy,nothing;is_pcomp=true,sol_type=106,
            legacy_nonlinear=true,require_coupling=false)
    end
end
end

@testset "Legacy nonlinear coupled laminate dispatch and linear limit" begin
    # This test exercises the optional projected formulation explicitly.
    withenv("JFEM_PCOMP_COUPLED_PROJECTED"=>"true",
            "JFEM_SOL105_PCOMP_MEMBRANE_SELC"=>"true") do
        Sol106CoupledDispatchFixture.checks()
    end
end
