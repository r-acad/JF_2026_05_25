module Sol106MembraneDispatchTests
using Test, LinearAlgebra, OpenJFEM
const S=OpenJFEM.Solver

function fixture(folder;rotated=false,permanent=false,release=0,unselected=false,cantilever=false,prescribed=0)
    Q=rotated ? S.CorotationalShell.rotation_exp([.29,-.37,.19]) : Matrix{Float64}(I,3,3)
    cid=rotated ? 73 : 0
    coord=rotated ? "CORD2R,73,0,0.,0.,0.,$(Q[1,3]),$(Q[2,3]),$(Q[3,3])\n+,$(Q[1,1]),$(Q[2,1]),$(Q[3,1])\n" : ""
    xy=[0. 0. 0.;1.7 0. 0.;1.7 .6 0.;0. .6 0.]
    grids=String[];constraints=String[]
    for n in 1:4
        p=Q*xy[n,:]
        ps=permanent ? "3456" : ""
        push!(grids,"GRID,$n,0,$(p[1]),$(p[2]),$(p[3]),$cid,$ps")
        comps=(n==3 && release!=0) ? join(c for c in 3:6 if c!=release) : "3456"
        !permanent && !cantilever && push!(constraints,"SPC1,11,$comps,$n")
    end
    append!(constraints,cantilever ? ["SPC1,11,123456,1,4"] : ["SPC1,11,1,1,4"])
    push!(constraints,"SPC1,12,2,1")
    unselected && push!(constraints,"SPC1,99,$release,3")
    prescribed!=0 && push!(constraints,"SPCD,1,3,$prescribed,.001")
    stretch=1.04;E=9e6;nu=.23;h=.03;W=.6;L=1.7
    force=E*stretch*(stretch^2-1)/2*W*h/2
    path=joinpath(folder,"membrane_dispatch.bdf")
    write(path,"""
SOL 106
CEND
SUBCASE 1
 SPC=1
 LOAD=1
 NLPARM=1
BEGIN BULK
PARAM,LGDISP,1
PARAM,NLMETHOD,AUTO
PARAM,AUTOSPC,YES
PARAM,SNORM,0.
PARAM,K6ROT,1.
$(coord)$(join(grids,"\n"))
CQUAD4,1,1,1,2,3,4
PSHELL,1,1,$h,1,,1
MAT1,1,$E,,$nu
SPCADD,1,11,12
$(join(constraints,"\n"))
FORCE,1,2,$cid,$force,1.,0.,0.
FORCE,1,3,$cid,$force,1.,0.,0.
NLPARM,1,4,,,1,40,PW,NO
+,1.e-9,1.e-10,1.e-9
ENDDATA
""")
    return OpenJFEM.bdf_to_model(path),(stretch=stretch,E=E,nu=nu,h=h,W=W,L=L)
end

function run_checks()
    @testset "Explicit membrane subspace preserves finite-strain AUTO semantics" begin
        mktempdir() do folder
            for rotated in (false,true),permanent in (false,true)
                model,p=fixture(folder;rotated=rotated,permanent=permanent)
                automatic=only(OpenJFEM.solve_model(deepcopy(model))["subcases"])
                formal_model=deepcopy(model);formal_model["PARAM_NLMETHOD"]="FORMAL"
                formal=only(OpenJFEM.solve_model(formal_model)["subcases"])
                diag=automatic["nonlinear_diagnostics"]
                @test diag["converged"]
                @test diag["nonlinear_method"]=="formal_shell_green_lagrange"
                @test diag["automatic_membrane_energy_preserved"]
                @test diag["nonlinear_selection_reason"]=="explicitly_constrained_planar_membrane_energy"
                @test isequal(automatic["u_analysis"],formal["u_analysis"])
                @test isequal(automatic["stresses"],formal["stresses"])
                @test automatic["nonlinear_rotation_coordinates"]===nothing
                u=automatic["u_analysis"]
                @test u[7]≈p.L*(p.stretch-1) rtol=2e-8
                @test u[20]≈p.W*(sqrt(1-p.nu*(p.stretch^2-1))-1) rtol=2e-8
                # Explicit COROT still requests its own engineering strain law.
                explicit=deepcopy(model);explicit["PARAM_NLMETHOD"]="COROT"
                corot=only(OpenJFEM.solve_model(explicit)["subcases"])
                @test corot["nonlinear_diagnostics"]["nonlinear_method"]=="corotational_shell"
                @test !corot["nonlinear_diagnostics"]["automatic_membrane_energy_preserved"]
                @test corot["nonlinear_diagnostics"]["converged"]
                engineering=p.stretch*(p.stretch^2-1)/2
                @test corot["u_analysis"][7]≈p.L*engineering rtol=2e-8
                @test corot["u_analysis"][20]≈-p.W*p.nu*engineering rtol=2e-8
            end
            # A free normal translation or bending rotation is sufficient to
            # retain shell work. Constraints from inactive sets cannot hide it.
            for release in (3,4),unselected in (false,true)
                model,_=fixture(folder;release=release,unselected=unselected)
                case=only(OpenJFEM.solve_model(model)["subcases"])
                @test case["nonlinear_diagnostics"]["converged"]
                @test !case["nonlinear_diagnostics"]["automatic_membrane_energy_preserved"]
                @test case["nonlinear_diagnostics"]["nonlinear_method"]=="corotational_shell"
            end
            model,_=fixture(folder;cantilever=true)
            case=only(OpenJFEM.solve_model(model)["subcases"])
            @test case["nonlinear_diagnostics"]["converged"]
            @test case["nonlinear_diagnostics"]["nonlinear_method"]=="corotational_shell"
            @test !case["nonlinear_diagnostics"]["automatic_membrane_energy_preserved"]
            # Fixed DOFs do not grant support to nonzero imposed normal motion.
            # The common SOL106 prescribed-motion preflight must reject it.
            for component in (3,4)
                prescribed,_=fixture(folder;prescribed=component)
                @test_throws ArgumentError OpenJFEM.solve_model(prescribed)
                nonzero,_=fixture(folder)
                push!(nonzero["SPC1s"],Dict("SID"=>11,"C"=>component,"NODES"=>[3],"D"=>.001))
                @test_throws ArgumentError OpenJFEM.solve_model(nonzero)
            end
        end
    end
end
end

Sol106MembraneDispatchTests.run_checks()
