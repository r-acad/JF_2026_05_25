using Test

module NaturalShearWorkTransportFixture
using Test, LinearAlgebra, ForwardDiff, OpenJFEM
const F = OpenJFEM.Solver.FEM
const CORNERS = ((-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.))
const EDGES = ((0.,-1.),(0.,1.),(-1.,0.),(1.,0.))

shape(z) = [(1-z[1])*(1-z[2]),(1+z[1])*(1-z[2]),
            (1+z[1])*(1+z[2]),(1-z[1])*(1+z[2])] ./ 4

# Independent kinematic construction. Covariant edge strains are formed from
# nodal w and rotations, then interpolated before converting to physical axes.
function tying_rows(xy)
    C = zeros(4,12)
    jacobians = Matrix{Float64}[]
    for (i,rs) in enumerate(EDGES)
        z = collect(rs)
        dn = transpose(ForwardDiff.jacobian(shape,z))
        J = dn*xy
        push!(jacobians,J)
        family = i <= 2 ? 1 : 2
        n = shape(z)
        for j in 1:4
            C[i,3j-2] = dn[family,j]
            C[i,3j-1] = -J[family,2]*n[j]
            C[i,3j] = J[family,1]*n[j]
        end
    end
    D = zeros(4,12)
    for (i,(r,s)) in enumerate(EDGES)
        cov = vcat(transpose(((1-s)*C[1,:]+(1+s)*C[2,:])/2),
                   transpose(((1-r)*C[3,:]+(1+r)*C[4,:])/2))
        physical = jacobians[i] \ cov
        D[i,:] = physical[i <= 2 ? 1 : 2,:]
    end
    D
end

function rotation_fields()
    Q = zeros(12,4)
    for (j,(r,s)) in enumerate(CORNERS)
        Q[3j,1] = 1.; Q[3j,2] = s
        Q[3j-1,3] = -1.; Q[3j-1,4] = -r
    end
    Q
end

# Three-point integration is independent of the production two-point rule.
# For a bilinear planar map, detJ is linear and this energy is polynomial.
function integrated_shear_energy(xy,Cs,a)
    gp = (-sqrt(3/5),0.,sqrt(3/5)); gw = (5/9,8/9,5/9)
    value = zero(eltype(a))
    for (r,wr) in zip(gp,gw), (s,ws) in zip(gp,gw)
        J = ForwardDiff.jacobian(t -> transpose(xy)*shape(t),[r,s])
        gamma = [a[1]+s*a[2],a[3]+r*a[4]]
        value += wr*ws*abs(det(J))*dot(gamma,Cs*gamma)
    end
    value
end

# Independent scalar form of MacNeal (1978), Eqs. 23--25. The physical
# sample strains are weighted by sqrt(2J); only the pair means cross-couple.
function published_shear_energy(xy,Cs,a)
    gp=inv(sqrt(3.0)); points=((0.,-gp),(0.,gp),(-gp,0.),(gp,0.))
    physical=(a[1]-gp*a[2],a[1]+gp*a[2],a[3]-gp*a[4],a[3]+gp*a[4])
    weighted=map(enumerate(points)) do (i,rs)
        J=ForwardDiff.jacobian(t -> transpose(xy)*shape(t),collect(rs))
        sqrt(2abs(det(J)))*physical[i]
    end
    x1,x2,y1,y2=weighted
    Cs[1,1]*(x1*x1+x2*x2)+Cs[2,2]*(y1*y1+y2*y2)+
        (Cs[1,2]+Cs[2,1])*(x1+x2)*(y1+y2)/2
end

function flexibility(xy,Cb,Cs;rigid_shear=false)
    T = promote_type(eltype(Cb),eltype(Cs))
    mw = F.create_macneal_shear_workspace(T)
    mw.D_mat .= tying_rows(xy)
    F.quad4_natural_shear_flexibility!(mw,xy,Cb,Cs;rigid_shear=rigid_shear)
    mw
end

@testset "Natural Q4 shear work transport" begin
    Cb = [38. 9. -3.;9. 119. 2.;-3. 2. 24.]
    Cs = [8.1e6 .27e6;.27e6 9.4e6]
    Q = rotation_fields()
    geometries = Matrix{Float64}[]
    # Independent convex shapes include both signs of skew and fan and a
    # slender cell. No dimensions or material coefficients come from a deck.
    for skew in (-.65,0.,.65), fan in (-.16,0.,.16)
        A = [.8 skew;.0 1.2]
        c = [fan,.35fan]
        push!(geometries,reduce(vcat,(transpose(A*[r,s]+c*r*s) for (r,s) in CORNERS)))
    end
    push!(geometries,[-.04 -.5;.04 -.65;.055 .45;-.055 .7])
    coefficients = ([.3,-.7,.4,.2],[.2,0.,-.1,0.])
    for xy in geometries
        D = tying_rows(xy); T = D*Q
        mw = flexibility(xy,Cb,Cs)
        H = ForwardDiff.hessian(a -> published_shear_energy(xy,Cs,a)/2,zeros(4))
        expected = T*(H\transpose(T))
        @test mw.Zs ≈ expected rtol=3e-12 atol=1e-18
        @test mw.Zs ≈ transpose(mw.Zs) rtol=2e-13 atol=1e-18
        @test isposdef(Symmetric(mw.Zs))
        @test isposdef(Symmetric(mw.Z_total))
        @test mw.Z_total ≈ mw.Zs+mw.Zb rtol=2e-13 atol=1e-18
        for a in coefficients
            sampled = D*(Q*a)
            @test dot(sampled,mw.Zs\sampled) ≈ published_shear_energy(xy,Cs,a) rtol=4e-12
        end
        # The continuum natural-field integral remains an exact independent
        # limiting check when transverse shear has no cross-coupling.
        for a in coefficients
            diagonal_Cs=diagm(diag(Cs))
            @test published_shear_energy(xy,diagonal_Cs,a) ≈
                  integrated_shear_energy(xy,diagonal_Cs,a) rtol=4e-12
        end
        K = transpose(D)*(mw.Z_total\D)
        @test K ≈ transpose(K) rtol=3e-12 atol=1e-10
        # The ordinary kernel must actually select the tested law; a helper
        # that passes in isolation but is bypassed by dispatch is insufficient.
        selected = F.create_macneal_shear_workspace()
        Ke = zeros(24,24)
        F.add_quad4_macneal_shear_rbf!(Ke,xy,Cb,Cs,.003;msws=selected)
        plate = [6i+j for i in 0:3 for j in (3,4,5)]
        @test selected.Z_total ≈ mw.Z_total rtol=4e-12 atol=1e-18
        @test Ke[plate,plate] ≈ K rtol=4e-12 atol=1e-10
        for (translation,rx,ry) in ((1.,0.,0.),(0.,1.,0.),(0.,0.,1.))
            rigid = reduce(vcat,([translation+rx*y-ry*x,rx,ry] for (x,y) in eachrow(xy)))
            @test norm(K*rigid) <= 2e-12*norm(K)*norm(rigid)
        end
        rigid = flexibility(xy,Cb,Cs;rigid_shear=true)
        @test iszero(rigid.Zs)
        @test rigid.Z_total ≈ mw.Zb rtol=3e-13 atol=1e-18
        @test flexibility(xy,Cb,zeros(2,2);rigid_shear=true).Z_total ≈ mw.Zb rtol=3e-13 atol=1e-18
        # Material dual values must survive the complete coefficient energy
        # and work transform used by property sensitivities.
        sampled = T*coefficients[1]
        d = ForwardDiff.derivative(1.) do scale
            m = flexibility(xy,Cb,scale*Cs)
            dot(sampled,m.Zs\sampled)
        end
        @test d ≈ dot(sampled,mw.Zs\sampled) rtol=3e-11
        force = [.4,-.3,.2,.1]
        db = ForwardDiff.derivative(1.) do scale
            m = flexibility(xy,scale*Cb,Cs)
            dot(force,m.Zb*force)
        end
        @test db ≈ -dot(force,mw.Zb*force) rtol=3e-11
        dh = ForwardDiff.derivative(1.) do scale
            m = flexibility(xy,scale^3*Cb,scale*Cs)
            dot(force,m.Z_total*force)
        end
        @test dh ≈ -dot(force,(3mw.Zb+mw.Zs)*force) rtol=3e-11
        # A cyclic change of natural axes and matching physical 90-degree
        # coordinate transformation must preserve the elemental shear energy.
        R = [0. 1.;-1. 0.]; perm = [2,3,4,1]
        rotated_xy = xy[perm,:]*transpose(R)
        rotated_Cs = R*Cs*transpose(R)
        B = [0. 1. 0.;1. 0. 0.;0. 0. -1.]
        rotated = flexibility(rotated_xy,B*Cb*transpose(B),rotated_Cs)
        Dr = tying_rows(rotated_xy)
        v = [.1,.3,-.2,-.4,.7,.2,.9,-.6,.5,.3,.2,-.8]
        vr = reduce(vcat,([v[3j-2]; R*v[3j-1:3j]] for j in perm))
        @test dot(Dr*vr,rotated.Zs\(Dr*vr)) ≈ dot(D*v,mw.Zs\(D*v)) rtol=4e-11
        @test dot(Dr*vr,rotated.Z_total\(Dr*vr)) ≈ dot(D*v,mw.Z_total\(D*v)) rtol=4e-11
        # Vanishing bending rigidity uses the existing positive limiting floor;
        # it must not create NaNs or a spurious finite plate stiffness.
        no_bending = flexibility(xy,zeros(3,3),Cs)
        Kzero = transpose(D)*(no_bending.Z_total\D)
        @test all(isfinite,Kzero)
        @test norm(Kzero) < 1e-20
    end
    for invalid in ([0. 0.;1. 0.;0. 1.;1. 1.],
                    [0. 0.;1. 0.;2. 0.;3. 0.],
                    [0. 0.;1. 0.;.2 .2;0. 1.])
        mw = F.create_macneal_shear_workspace()
        @test_throws ArgumentError F.quad4_natural_shear_flexibility!(mw,invalid,Cb,Cs)
    end
end
end
