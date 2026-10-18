using Test

# Manufactured analytical checks of anisotropic laminate prestress and the
# transverse energy of its finite-warp projected shell operator.
module WarpedPcompPrestressFixture
using Test, LinearAlgebra, ForwardDiff, Printf, OpenJFEM
const S = OpenJFEM.Solver
const F = OpenJFEM.FEM
const E1, E2, NU12, G12 = 143e9, 8.9e9, 0.27, 4.7e9
const H, PLY_ANGLE = 0.0046, 19.0

shape(q) = [(1-q[1])*(1-q[2]), (1+q[1])*(1-q[2]),
            (1+q[1])*(1+q[2]), (1-q[1])*(1+q[2])] ./ 4

function gradient(xy, r, s)
    natural = ForwardDiff.jacobian(shape, [r,s])
    jacobian = transpose(xy)*natural
    natural/jacobian, abs(det(jacobian))
end

# Derive A by rotating physical strain/stress tensors. This does not call the
# production constitutive-rotation or shell material-frame routines.
function material_matrix(xy, theta)
    angle = atan(xy[2,2]-xy[1,2],xy[2,1]-xy[1,1]) + deg2rad(theta+PLY_ANGLE)
    c,s = cos(angle),sin(angle)
    Q = [c -s; s c]
    factor = H/(1-NU12^2*E2/E1)
    A0 = factor*[E1 NU12*E2 0.; NU12*E2 E2 0.; 0. 0. G12*(1-NU12^2*E2/E1)]
    A = zeros(3,3)
    for j in 1:3
        e = Float64.(collect(1:3).==j)
        Em = transpose(Q)*[e[1] e[3]/2; e[3]/2 e[2]]*Q
        n = A0*[Em[1,1],Em[2,2],2Em[1,2]]
        N = Q*[n[1] n[3]; n[3] n[2]]*transpose(Q)
        A[:,j] = [N[1,1],N[2,2],N[1,2]]
    end
    A
end

# Independent center-shear, per-quadrature normal strain resultants, recovered
# from W*u. Shape derivatives are differentiated from interpolation with AD.
function prestress(xy, projected_u, A)
    U = transpose(reshape(projected_u,6,4))
    dc,_ = gradient(xy,0.,0.)
    shear = dot(dc[:,2],U[:,1])+dot(dc[:,1],U[:,2])
    g = inv(sqrt(3.))
    result = zeros(4,3)
    for (i,(r,s)) in enumerate(((-g,-g),(g,-g),(g,g),(-g,g)))
        d,_ = gradient(xy,r,s)
        result[i,:] = A*[dot(d[:,1],U[:,1]),dot(d[:,2],U[:,2]),shear]
    end
    result
end

function transverse_energy(xy, N, w)
    value = zero(w[1])
    g = inv(sqrt(3.))
    for (i,(r,s)) in enumerate(((-g,-g),(g,-g),(g,g),(-g,g)))
        _,jac = gradient(xy,r,s)
        dx,_ = gradient(xy,0.,s)
        dy,_ = gradient(xy,r,0.)
        gx,gy = dot(dx[:,1],w),dot(dy[:,2],w)
        value += jac*(N[i,1]*gx^2+N[i,2]*gy^2+2N[i,3]*gx*gy)/2
    end
    value
end

function make_model(path, xyz, theta)
    open(path,"w") do io
        println(io,"SOL 105\nCEND\nBEGIN BULK\nPARAM,SNORM,0\nPARAM,K6ROT,10.")
        for i in 1:4
            @printf(io,"GRID,%d,,%.16g,%.16g,%.16g\n",i,xyz[i,1],xyz[i,2],xyz[i,3])
        end
        println(io,"MAT8,7,$E1,$E2,$NU12,$G12,3.8e9,2.6e9,1590.")
        println(io,"PCOMP,11,$(-H/2)\n+,7,$H,$PLY_ANGLE,YES")
        println(io,"CQUAD4,13,11,1,2,3,4,$theta\nENDDATA")
    end
    OpenJFEM.bdf_to_model(path)
end

function assemble(model, xyz, u)
    ids = Dict(i=>i for i=1:4)
    rotations = [Matrix{Float64}(I,3,3) for _=1:4]
    normals = S.compute_snorm_normals(model,ids,xyz)
    mapping = S.assemble_constraints(model,ids,xyz,rotations,Int[],Int[],Float64[])[1]
    context = Ref{Any}()
    callback = (eid,c) -> (context[] = deepcopy(c))
    K = S.assemble_geometric_stiffness(model,ids,xyz,rotations,24,u,normals,mapping;
        snorm_angle_override=0.,geometric_capture=callback)
    Matrix(K),context[]
end

function rotation_matrix()
    axis = normalize([0.31,-0.47,0.61])
    x,y,z = axis
    skew = [0. -z y; z 0. -x; -y x 0.]
    angle = 0.83
    Matrix{Float64}(I,3,3)+sin(angle)*skew+(1-cos(angle))*skew*skew
end

function checks()
    BLAS.set_num_threads(1)
    shapes = ([0. 0.;1.7 .1;1.85 .9;-.2 .7],
              [0. 0.;2.3 .05;1.6 .72;.15 .85])
    Q = rotation_matrix()
    R6 = zeros(6,6);R6[1:3,1:3]=Q;R6[4:6,4:6]=Q
    R24 = kron(Matrix{Float64}(I,4,4),R6)
    mktempdir() do dir
        for (si,xy0) in enumerate(shapes), warp in (0.,0.31,-0.47), theta in (0.,27.)
            xyz = hcat(xy0,[0.,0.,warp,0.])
            model = make_model(joinpath(dir,"manufactured.bdf"),xyz,theta)
            @test model["PSHELLs"]["11"]["TYPE"] == "PCOMP_CLT"
            @test get(model["PSHELLs"]["11"],"Bmb",nothing) === nothing
            u = 1e-4sin.(collect(1.:24.)) + 4e-5cos.(collect(1.:24.).^1.3)
            K,c = assemble(model,xyz,u)
            T = c[:T_buf]
            xy,local3 = c[:lc_buf4],c[:coords3d_local_buf4]
            W = F.quad4_finite_warp_displacement_map(xy,local3)
            W = W === nothing ? Matrix{Float64}(I,24,24) : W
            A = material_matrix(xy,theta)
            N = prestress(xy,W*(T*u),A)
            @test c[:Cm_override] ≈ A rtol=3e-12
            @test c[:N_gp] ≈ N rtol=5e-12
            @test c[:kg_membrane_selc]
            @test c[:kg_flat_uncoupled_pcomp_assumed]
            @test c[:kg_trans_mode_eff] === :principal_transverse
            @test c[:curvature_membrane] === nothing
            @test c[:slope_membrane_kg] === nothing
            @test !c[:elem_mitc4_3d_kg_recovery]
            @test c[:apply_finite_warp_kg]
            if warp != 0.
                @test c[:warp_ratio_kg] > 1e-2
                @test !c[:elem_is_flat_kg]
            end
            @test K ≈ transpose(K) rtol=3e-13
            for w in ([.17,-.43,.81,.06],[-.36,.28,.11,.74])
                projected = zeros(24);projected[3:6:24]=w
                physical = transpose(T)*(W\projected)
                expected = 2transverse_energy(xy,N,w)
                actual = dot(physical,K*physical)
                @test actual ≈ expected rtol=2e-11 atol=2e-9
                hessian = ForwardDiff.hessian(v->transverse_energy(xy,N,v),w)
                localK = transpose(inv(W))*T*K*transpose(T)*inv(W)
                @test localK[3:6:24,3:6:24] ≈ hessian rtol=2e-11 atol=2e-9
            end
            # Rotate physical points and both vector parts of every nodal DOF.
            # The material direction follows the element edge, so no coordinate
            # or constitutive helper is reused to manufacture the rotated data.
            xr = xyz*transpose(Q)
            mr = make_model(joinpath(dir,"rotated.bdf"),xr,theta)
            Kr,cr = assemble(mr,xr,R24*u)
            covariance = norm(transpose(R24)*Kr*R24-K)/norm(K)
            @test covariance < 2e-11
            for axis in 1:3
                unit = Float64.(collect(1:3).==axis)
                rigid = zeros(24)
                for i in 1:4
                    rigid[6i-5:6i-3]=cross(unit,xyz[i,:])
                    rigid[6i-2:6i]=unit
                end
                Kg_rigid,_ = assemble(model,xyz,rigid)
                @test norm(Kg_rigid) < 1e-10*E1*H
            end
        end
    end
end

function eligibility_checks()
    BLAS.set_num_threads(1)
    xyz = [0. 0. 0.; 2.3 .05 0.; 1.6 .72 .43; .15 .85 0.]
    u = 1e-4sin.(collect(1.:24.))
    mktempdir() do dir
        path = joinpath(dir,"eligibility.bdf")
        model = make_model(path,xyz,27.)
        _,base = assemble(model,xyz,u)
        @test base[:kg_projected_pcomp]
        @test base[:warp_ratio_kg] > 1e-2
        @test !base[:elem_is_flat_kg]
        @test base[:kg_axis_mode_eff] === :element
        configurations = (
            ("global material edge axis with default Kg", "JFEM_Q4_PCOMP_AXIS_MODE"=>"g12"),
            ("actual Kg material edge axis", "JFEM_Q4_PCOMP_KG_AXIS_MODE"=>"g12"),
            ("actual Kg global axis", "JFEM_Q4_PCOMP_KG_AXIS_MODE"=>"global_x"),
            ("explicit flatness tolerance", "JFEM_Q4_FLAT_TOL_REL"=>"1e-6"),
            ("restrictive explicit warp tolerance", "JFEM_Q4_MACNEAL_WARP_TOL"=>"1e-4"),
            ("finite warp map disabled", "JFEM_Q4_WARP_TRANSFORM"=>"0"),
            ("mismatched Kg frame", "JFEM_Q4_FRAME_MODE_KG"=>"edge"),
        )
        for (label,setting) in configurations
            withenv(setting) do
                _,c = assemble(model,xyz,u)
                @test !c[:kg_projected_pcomp]
                if first(setting) == "JFEM_Q4_PCOMP_AXIS_MODE"
                    @test c[:kg_axis_mode_eff] === :element
                end
            end
        end
        # The new prestress selector is specific to linear buckling.
        # Other analyses retain their existing formulations.
        for sol in (101,103,106)
            other = deepcopy(model);other["SOL"] = sol
            _,c = assemble(other,xyz,u)
            @test !c[:kg_projected_pcomp]
        end
        # An asymmetric two-ply stack manufactures a nonzero CLT B tensor.
        # It remains under the existing coupled laminate formulation boundary.
        text = read(path,String)
        old = "PCOMP,11,$(-H/2)\n+,7,$(H),$(PLY_ANGLE),YES"
        new = "PCOMP,11,$(-H/2)\n+,7,$(H/3),19.,YES,7,$(2*H/3),-11.,YES"
        @test occursin(old,text)
        write(path,replace(text,old=>new))
        coupled = OpenJFEM.bdf_to_model(path)
        B = get(coupled["PSHELLs"]["11"],"Bmb",nothing)
        @test B !== nothing
        @test norm(B)>0
        _,c = assemble(coupled,xyz,u)
        @test !c[:kg_projected_pcomp]
    end
end
end

@testset "Manufactured warped anisotropic laminate prestress energy" begin
    WarpedPcompPrestressFixture.checks()
end

@testset "Warped uncoupled laminate actual assembly exclusions" begin
    WarpedPcompPrestressFixture.eligibility_checks()
end
