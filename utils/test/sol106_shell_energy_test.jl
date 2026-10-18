module Sol106ShellEnergyTests
using Test, LinearAlgebra, SparseArrays, StaticArrays, OpenJFEM, ForwardDiff
const VK_S=OpenJFEM.Solver

function physical_affine_pattern(xy)
    v=zeros(6size(xy,1))
    for i in axes(xy,1)
        x,y=xy[i,:];b=6(i-1)
        v[b+1]=.011x-.003y
        v[b+2]=.007x-.009y
        v[b+3]=.043x+.017y
        v[b+4:b+6].=[.003,-.007,.011]
    end
    v
end

function polygon_area(xy)
    abs(sum(xy[i,1]*xy[mod1(i+1,size(xy,1)),2]-xy[mod1(i+1,size(xy,1)),1]*xy[i,2] for i in axes(xy,1)))/2
end

@testset "Physical affine Green-Lagrange energy, force, consistent tangent" begin
    Cm=1e5*[7. 2. .3;2. 5. -.2;.3 -.2 3.]
    e=[.011,-.009,.004]
    q=[.5*(.011^2+.007^2+.043^2),
       .5*((-.003)^2+(-.009)^2+.017^2),
       .011*(-.003)+.007*(-.009)+.043*.017]
    for xy in ([0. 0.;2. 0.;2. 1.;0. 1.],
               [0. 0.;1.5 .1;1.9 .8;.4 .7],
               [0. 0.;10. 0.;10. .001;0. .001],
               [0. 0.;1.7 .2;.3 .8])
        n=size(xy,1);v=physical_affine_pattern(xy);t=.7;u=t*v;A=polygon_area(xy)
        energy=n==4 ? VK_S._formal_vk_quad4_extra_energy : VK_S._formal_vk_tria3_extra_energy
        localfun=n==4 ? VK_S._formal_vk_quad4_extra_local : VK_S._formal_vk_tria3_extra_local
        c3=A*dot(e,Cm*q);c4=.5A*dot(q,Cm*q)
        f,K,U=localfun(xy,u,Cm)
        @test U≈c3*t^3+c4*t^4 rtol=2e-10 atol=1e-11
        @test dot(f,v)≈3c3*t^2+4c4*t^3 rtol=2e-10 atol=1e-10
        # Extreme aspect ratios produce large matrix entries whose affine
        # quadratic work cancels. Bound roundoff by the absolute quadratic
        # sum, while keeping a tight tolerance for well-conditioned shapes.
        # A matrix-vector product followed by a dot product uses at most 4n
        # elementary operations per accumulated work contribution.
        operation_count=4length(v)
        gamma=operation_count*eps(Float64)/(1-operation_count*eps(Float64))
        work_roundoff=gamma*dot(abs.(v),abs.(K)*abs.(v))
        @test all(isfinite,K)
        @test dot(v,K*v)≈6c3*t+12c4*t^2 rtol=2e-10 atol=max(1e-9,work_roundoff)
        @test K≈K' rtol=1e-13
        f0,K0,U0=localfun(xy,zeros(6n),Cm)
        @test iszero(U0)
        @test iszero(norm(f0))
        @test iszero(norm(K0))
        for c in 1:3
            translation=zeros(6n);translation[c:6:end].=1.
            @test abs(dot(f,translation))<1e-11max(norm(f),1.)
            @test norm(K*translation)<1e-11max(norm(K),1.)
            @test energy(xy,u+.013translation,Cm)≈U rtol=2e-10 atol=1e-10
        end
        # In-plane gradients contribute their own exact quadratic strain.
        # Omitting them can preserve transverse displacement while corrupting
        # the in-plane response and shell rotations.
        membrane=copy(u);membrane[3:6:end].=.004
        qm=[.5*(.011^2+.007^2),.5*((-.003)^2+(-.009)^2),
            .011*(-.003)+.007*(-.009)]
        expected=A*(dot(e,Cm*qm)*t^3+.5dot(qm,Cm*qm)*t^4)
        @test energy(xy,membrane,Cm)≈expected rtol=2e-10 atol=1e-10
        # An arbitrary finite rigid rotation has F'F=I. The complete affine
        # membrane energy must vanish, including a rotation out of the plane.
        axis=normalize([1.,2.,3.]);ax,ay,az=axis
        W=[0. -az ay;az 0. -ax;-ay ax 0.];angle=.37
        rotation=Matrix{Float64}(I,3,3)+sin(angle)*W+(1-cos(angle))*W^2
        increment=rotation-Matrix{Float64}(I,3,3)
        rigid=zeros(6n)
        for i in axes(xy,1)
            rigid[6(i-1)+1:6(i-1)+3].=increment*[xy[i,1],xy[i,2],0.]
        end
        linear_strain=[increment[1,1],increment[2,2],increment[1,2]+increment[2,1]]
        linear_energy=.5A*dot(linear_strain,Cm*linear_strain)
        @test abs(linear_energy+energy(xy,rigid,Cm))<1e-10max(linear_energy,1.)
    end
end

@testset "Fixed constraint pullback and virtual work" begin
    xy=[0. 0.;1.3 .1;1.5 .9;.2 .8]
    Cm=[7. 2. .3;2. 5. -.2;.3 -.2 3.]*1e5
    # A fixed MPC, including dependent structural translations, maps q -> u=Tq.
    T=zeros(24,18);T[1:18,:].=Matrix{Float64}(I,18,18)
    T[19:24,1:6].=.25Matrix{Float64}(I,6,6)
    T[19:24,7:12].=.75Matrix{Float64}(I,6,6)
    q=.002sin.(collect(1.:18));u=T*q
    f,K,U=VK_S._formal_vk_quad4_extra_local(xy,u,Cm)
    reduced_energy=v->VK_S._formal_vk_quad4_extra_energy(xy,T*v,Cm)
    @test reduced_energy(q)≈U
    @test ForwardDiff.gradient(reduced_energy,q)≈T'*f rtol=3e-13
    @test ForwardDiff.hessian(reduced_energy,q)≈T'*K*T rtol=3e-13
    variation=cos.(collect(1.:18))
    @test dot(T'*f,variation)≈dot(f,T*variation) rtol=3e-13
    @test dot(variation,(T'*K*T)*variation)≈dot(T*variation,K*(T*variation)) rtol=3e-13
    # A centered independent force-difference check tests the tangent action.
    direction=variation/norm(variation);h=1e-7
    plus=first(VK_S._formal_vk_quad4_extra_local(xy,T*(q+h*direction),Cm))
    minus=first(VK_S._formal_vk_quad4_extra_local(xy,T*(q-h*direction),Cm))
    @test T'*(plus-minus)/(2h)≈(T'*K*T)*direction rtol=2e-7 atol=1e-6
end

function energy_fixture(folder)
    path=joinpath(folder,"planar_shell.bdf")
    write(path,"""
SOL 106
CEND
SUBCASE 1
 SPC=1
 LOAD=1
 NLPARM=1
BEGIN BULK
PARAM,LGDISP,1
PARAM,AUTOSPC,YES
PARAM,K6ROT,100.
GRID,1,,0.,0.,0.
GRID,2,,1.3,.1,0.
GRID,3,,1.5,.9,0.
GRID,4,,.2,.8,0.
CQUAD4,1,1,1,2,3,4
PSHELL,1,1,.05,1,,1
MAT1,1,7.e7,,.3
SPC1,1,123456,1,4
FORCE,1,2,0,1.,0.,0.,1.
FORCE,1,3,0,1.,0.,0.,1.
NLPARM,1,2,,,1,25,P,NO
+,1.e-6,1.e-8,1.e-6
ENDDATA
""")
    OpenJFEM.bdf_to_model(path)
end

@testset "Nested constraint transpose and actual nonlinear evaluator" begin
    mktempdir() do folder
        model=energy_fixture(folder)
        ids=Dict(i=>i for i in 1:4)
        X=[0. 0. 0.;1.3 .1 0.;1.5 .9 0.;.2 .8 0.]
        R=[Matrix{Float64}(I,3,3) for _ in 1:4]
        normals=Dict{Int,SVector{3,Float64}}()
        # Both dependent DOFs lie on the shell. A nested relation must be
        # flattened before pulling back either forces or tangent entries.
        mapping=Dict(21=>[(3,.25),(9,.75)],15=>[(21,.4),(9,.6)])
        T=Matrix{Float64}(I,24,24)
        T[21,:].=0.;T[21,3]=.25;T[21,9]=.75
        T[15,:].=0.;T[15,3]=.1;T[15,9]=.9
        q=.002sin.(collect(1.:24));q[[15,21]].=0.;u=T*q
        fullforce=cos.(collect(1.:24))
        fullmatrix=Matrix{Float64}(I,24,24)+fullforce*fullforce'
        @test VK_S._apply_constraint_transpose(fullforce,mapping)≈T'*fullforce rtol=3e-14
        @test VK_S._apply_constraint_congruence(fullmatrix,mapping)≈T'*fullmatrix*T rtol=3e-14
        @test VK_S._apply_constraint_transpose(fullforce,Dict())===fullforce
        @test VK_S._apply_constraint_congruence(fullmatrix,Dict())===fullmatrix
        Klinear=sparse(T'*fullmatrix*T)
        state(v)=VK_S._evaluate_nonlinear_state_formal(Klinear,zeros(24),24,model,ids,X,nothing,R,v,normals,mapping)
        current=state(u)
        direction=sin.(collect(1.:24).+.3);direction[[15,21]].=0.;direction/=norm(direction)
        h=1e-7
        plus=state(u+h*T*direction);minus=state(u-h*T*direction)
        @test (plus.residual_vector-minus.residual_vector)/(2h)≈current.K_eff*direction rtol=2e-7 atol=1e-6
        @test (plus.internal_energy-minus.internal_energy)/(2h)≈dot(current.residual_vector,direction) rtol=2e-7 atol=1e-7
        @test current.K_eff≈current.K_eff' rtol=1e-13
        @test iszero(norm(current.residual_vector[[15,21]]))
    end
end

@testset "Automatic energy scope and explicit legacy selection" begin
    mktempdir() do folder
        model=energy_fixture(folder)
        ids=Dict(i=>i for i in 1:4)
        X=[0. 0. 0.;1.3 .1 0.;1.5 .9 0.;.2 .8 0.]
        normals=Dict{Int,SVector{3,Float64}}()
        support(m,x=X,n=normals)=VK_S._automatic_shell_energy_support(m,ids,x,n)
        @test support(model).supported
        # A linear CBAR can accompany the shells without adding a fictitious
        # geometric beam energy. Nonlinear beam and rod families stay outside.
        bars=deepcopy(model);bars["CBARs"]=Dict("1"=>Dict("PID"=>1))
        @test support(bars).supported
        warped=copy(X);warped[3,3]=.01
        @test !support(model,warped).supported
        @test !support(model,X,Dict(1=>SVector(0.,0.,1.))).supported
        for family in ("CSOLIDs","CBEAMs","CRODs","CONRODs","CTUBEs","CBUSHs")
            other=deepcopy(model);other[family]=Dict("1"=>Dict())
            @test !support(other).supported
        end
        offset=deepcopy(model);only(values(offset["CSHELLs"]))["ZOFFS"]=.001
        @test !support(offset).supported
        composite=deepcopy(model);composite["PSHELLs"]["1"]["TYPE"]="PCOMP_CLT"
        composite["PSHELLs"]["1"]["Cm"]=Matrix{Float64}(I,3,3)
        @test !support(composite).supported
        coupled=deepcopy(model);coupled["PSHELLs"]["1"]["MID4"]=1
        @test !support(coupled).supported
        anisotropic=deepcopy(model)
        anisotropic["MATs"]=Dict(k=>Dict{String,Any}(v) for (k,v) in anisotropic["MATs"])
        anisotropic["MATs"]["1"]["TYPE"]="MAT8"
        @test !support(anisotropic).supported
        solved=OpenJFEM.solve_model(deepcopy(model))
        diag=only(solved["subcases"])["nonlinear_diagnostics"]
        @test diag["converged"]
        @test diag["nonlinear_method"]=="formal_shell_green_lagrange"
        @test diag["requested_nonlinear_method"]=="auto"
        @test diag["correction_tangent_model"]=="formal_consistent_tangent"
        @test diag["requested_load_step_count"]==2
        legacy=deepcopy(model);legacy["PARAM_NLMETHOD"]="legacy_geometric"
        old=only(OpenJFEM.solve_model(legacy)["subcases"])["nonlinear_diagnostics"]
        @test old["converged"]
        @test old["nonlinear_method"]=="legacy_geometric"
        @test old["requested_nonlinear_method"]=="legacy_geometric"
        explicit_residual=deepcopy(model);explicit_residual["PARAM_NLRESMODEL"]="tangent_operator"
        explicit=only(OpenJFEM.solve_model(explicit_residual)["subcases"])["nonlinear_diagnostics"]
        @test explicit["nonlinear_method"]=="legacy_geometric"
    end
end

@testset "Linear geometry and elastic CBAR limits" begin
    mktempdir() do folder
        # SOL106 without large displacement activation has the same elastic
        # response as SOL101, even though standard increment controls exist.
        shell=energy_fixture(folder)
        delete!(shell,"PARAM_LGDISP")
        elastic=deepcopy(shell);elastic["SOL"]=101
        linearcase=only(OpenJFEM.solve_model(elastic)["subcases"])
        nonlinearcase=only(OpenJFEM.solve_model(shell)["subcases"])
        @test nonlinearcase["raw_displacement"]≈linearcase["raw_displacement"] rtol=2e-11 atol=1e-12
        @test nonlinearcase["nonlinear_diagnostics"]["nonlinear_method"]=="linear_elastic"
        # CBAR is an elastic line element in this large-displacement route.
        # Its large lateral deflection must not acquire a spurious Kg*u force.
        path=joinpath(folder,"elastic_bar.bdf")
        write(path,"""
SOL 106
CEND
SUBCASE 1
 SPC=1
 LOAD=1
 NLPARM=1
BEGIN BULK
PARAM,LGDISP,1
PARAM,AUTOSPC,YES
PARAM,K6ROT,100.
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
CBAR,1,1,1,2,0.,1.,0.
PBAR,1,1,1.e-4,8.33333333333333e-10,8.33333333333333e-10,1.66666666666667e-9
MAT1,1,7.e10,,.3
SPC1,1,123456,1
FORCE,1,2,0,50.,0.,0.,1.
NLPARM,1,2,,,1,25,P,NO
+,1.e-6,1.e-8,1.e-6
ENDDATA
""")
        bar=OpenJFEM.bdf_to_model(path)
        staticbar=deepcopy(bar);staticbar["SOL"]=101
        basecase=only(OpenJFEM.solve_model(staticbar)["subcases"])
        autocase=only(OpenJFEM.solve_model(bar)["subcases"])
        @test autocase["raw_displacement"]≈basecase["raw_displacement"] rtol=2e-11 atol=1e-12
        @test autocase["nonlinear_diagnostics"]["nonlinear_method"]=="linear_elastic"
        @test autocase["nonlinear_diagnostics"]["final_load_scale"]≈1.
        @test autocase["nonlinear_diagnostics"]["requested_load_step_count"]==2
        unknown=deepcopy(bar);unknown["PARAM_NLMETHOD"]="misspelled_method"
        @test_throws ArgumentError OpenJFEM.solve_model(unknown)
    end
end

end
