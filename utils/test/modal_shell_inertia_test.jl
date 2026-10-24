using Test

module ModalShellInertiaFixture
using Test, LinearAlgebra, OpenJFEM
const S=OpenJFEM.Solver

function fixture(path;warp=0.0,thickness=.002,z0=-.0015)
    write(path,"""
SOL 103
CEND
SUBCASE 1
 SPC=1
 METHOD=1
BEGIN BULK
PARAM,COUPMASS,1
PARAM,K6ROT,100.
GRID,1,,0.,0.,0.
GRID,2,,.23,0.,0.
GRID,3,,.30,.70,$warp
GRID,4,,.07,.70,0.
CQUAD4,21,77,1,2,3,4,17.5
PCOMP,77,$z0,.8
,80,$(thickness*.2),0.,YES,80,$(thickness*.3),37.,YES
,80,$(thickness*.25),90.,YES,80,$(thickness*.25),-23.,YES
MAT8,80,135.0E9,9.5E9,.28,4.7E9,4.5E9,3.5E9,1600.
SPC1,1,123456,1,2
EIGRL,1,,,6
ENDDATA
""")
    OpenJFEM.bdf_to_model(path)
end

function checks()
    # A high-frequency root must never turn sizeable negative numerical roots
    # into apparently valid rigid-body modes. Ordinary roundoff around an
    # actual zero mode remains admissible at the local elastic/mass scale.
    unresolved=S._sol103_dense_spectrum_resolution([-1e8,-1e5,3e5,5e27],1e10)
    @test unresolved.unresolved_negative
    @test unresolved.zero_tolerance<1e-2
    @test unresolved.spectral_error_bound>1e14
    resolved=S._sol103_dense_spectrum_resolution([-1e-10,1e4,1e8],1e7)
    @test !resolved.unresolved_negative
    mktempdir() do dir
        for warp in (0.0,.001)
            model=fixture(joinpath(dir,"coupled.bdf");warp)
            cap=S.AnalyticShellCapture(model)
            K,ids,X,ndof,R,emax,mapping,_,diag0=S.assemble_stiffness(model;shell_capture=cap)
            @test any(get(call.kwargs,:coupled_projected,false) for call in only(values(cap.contexts)).calls)
            static=deepcopy(model);static["SOL"]=101
            Ks,=S.assemble_stiffness(static;sol101_context=true)
            @test K≈Ks rtol=2e-13
            @test !S.coupled_pcomp_projected_enabled([0. 0.;.23 0.;.30 .7;.07 .7],
                model["PSHELLs"]["77"]["Bmb"];is_pcomp=true,sol_type=106)

            physical=S.assemble_mass(model,ids,X,R,ndof)
            modal=S.assemble_modal_mass(model,ids,X,R,ndof)
            rotations=vcat((collect(6i-2:6i) for i in 1:4)...)
            translations=setdiff(1:ndof,rotations)
            @test norm(physical[translations,rotations])>0
            @test norm(physical[rotations,rotations])>0
            @test iszero(norm(modal[rotations,:]))
            @test iszero(norm(modal[:,rotations]))
            @test modal[translations,translations]≈physical[translations,translations] rtol=2e-14
            @test S.assemble_mass(model,ids,X,R,ndof) == physical
            # Modal assembly must follow output-coordinate congruence, and must
            # retain total surface mass including NSM without extra shell modes.
            a=.37;Q=[cos(a) -sin(a) 0.;sin(a) cos(a) 0.;0. 0. 1.]
            RR=[Q for _ in 1:4];T=kron(Matrix{Float64}(I,8,8),Q)
            @test S.assemble_modal_mass(model,ids,X,RR,ndof)≈T'*modal*T rtol=1e-13
            if iszero(warp)
                translation=zeros(ndof);translation[1:6:end].=1
                @test dot(translation,modal*translation)≈.23*.70*(1600*.002+.8) rtol=1e-13
            end
            mass=OpenJFEM._sol103_modal_mass_matrices(model,ids,X,R,ndof,mapping,nothing)
            @test mass.physical==modal
            @test mass.eigensolve==modal
            eigenvalues,_,modes=S.solve_modes(K,modal,ndof,model,ids,X,1,R,6;
                rbe3_map=mapping,max_elem_stiff=emax,orig_diag=diag0)
            @test length(eigenvalues)==6
            @test all(isfinite,eigenvalues)&&all(>(0),eigenvalues)
            @test modes'*modal*modes≈Matrix{Float64}(I,6,6) rtol=2e-7 atol=2e-7
        end
    end
end
end

@testset "Modal laminate elastic energy and reference-surface inertia" begin
    # Exercise modal inertia with the optional projected elastic law.
    withenv("JFEM_PCOMP_COUPLED_PROJECTED"=>"true",
            "JFEM_SOL105_PCOMP_MEMBRANE_SELC"=>"true") do
        ModalShellInertiaFixture.checks()
    end
end
