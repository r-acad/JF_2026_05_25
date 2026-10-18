using Test

module ProjectedQuadTransverseEnergyFixture
using Test, LinearAlgebra, ForwardDiff, OpenJFEM
const F = OpenJFEM.Solver.FEM
const WD = [3, 9, 15, 21]

# Independent scalar prestress energy. Differentiate the interpolated position
# and shape functions rather than using the production gradient routines.
shape(rs) = [(1-rs[1])*(1-rs[2]), (1+rs[1])*(1-rs[2]),
             (1+rs[1])*(1+rs[2]), (1-rs[1])*(1+rs[2])] ./ 4
function gradient_at(xy, w, r, s)
    rs = [r, s]
    J = ForwardDiff.jacobian(t -> transpose(xy)*shape(t), rs)
    dn = ForwardDiff.jacobian(shape, rs)
    transpose(J) \ (transpose(dn)*w)
end

function transverse_energy(w, xy, stress, h; tied=true)
    p = inv(sqrt(3.0))
    value = zero(w[1])
    for (q, (r,s)) in enumerate(((-p,-p),(p,-p),(p,p),(-p,p)))
        J = ForwardDiff.jacobian(t -> transpose(xy)*shape(t), [r,s])
        gx = gradient_at(xy, w, tied ? 0.0 : r, s)[1]
        gy = gradient_at(xy, w, r, tied ? 0.0 : s)[2]
        value += h*abs(det(J))/2 *
            (stress[q,1]*gx^2 + stress[q,2]*gy^2 + 2stress[q,3]*gx*gy)
    end
    value
end

function corrected(xy, stress, h)
    K = F.geometric_stiffness_quad4(xy, stress, h;
        trans_mode=:principal_transverse)
    F.add_quad4_assumed_transverse_gradient_delta!(K, xy, stress, h)
end

@testset "Projected Q4 transverse frozen-prestress energy" begin
    cells = (
        [0. 0.; 2. 0.; 2. 1.; 0. 1.],
        [0. 0.; 2. .1; 3. 1.1; 1. 1.],
        [0. 0.; 2. 0.; 1.4 1.; .3 .8],
        [0. 0.; 20. .02; 19.8 .17; .1 .1],
        [0. 0.; 1. -.3; .8 .6; -.4 .5])
    stresses = (
        repeat([2.e6 3.e6 .4e6], 4, 1),
        [-2.e6 -3.e6 .4e6; -1.e6 -4.e6 -.2e6;
         -3.e6 -2.e6 .8e6; -2.5e6 -1.5e6 -.3e6],
        [0. 0. 1.e6; 0. 0. -2.e6; 0. 0. .5e6; 0. 0. 1.3e6])
    h = .003
    w = [.3, -.2, .6, .1]
    withenv("JFEM_KG_SHELL_TRANSVERSE_W_FORM" => "w",
            "JFEM_KG_SHELL_LOCAL_TRANS_SPLIT" => "0") do
        for (ci, xy) in enumerate(cells), stress in stresses
            before = F.geometric_stiffness_quad4(xy, stress, h;
                trans_mode=:principal_transverse)
            K = corrected(xy, stress, h)
            H = ForwardDiff.hessian(t -> transverse_energy(t,xy,stress,h), w)
            @test K[WD,WD] ≈ H rtol=3e-12 atol=2e-9
            @test dot(w, K[WD,WD]*w)/2 ≈ transverse_energy(w,xy,stress,h) rtol=3e-12 atol=2e-9
            @test K ≈ transpose(K) rtol=3e-13 atol=2e-10
            untouched = trues(24,24); untouched[WD,WD] .= false
            @test K[untouched] == before[untouched]
            @test norm(K[WD,WD]*ones(4)) <= 1e-12*norm(K[WD,WD])
            @test corrected(xy, -stress, h) ≈ -K rtol=3e-13 atol=2e-10
            other = stresses[1]
            @test corrected(xy, stress+other, h) ≈ K+corrected(xy,other,h) rtol=3e-12 atol=2e-9
            # Affine transverse displacement has the same physical gradient at
            # every tying point; the correction must preserve its patch energy.
            affine = .7 .+ .2xy[:,1] .- .6xy[:,2]
            @test dot(affine,K[WD,WD]*affine) ≈ dot(affine,before[WD,WD]*affine) rtol=3e-11 atol=2e-8
            @test corrected(7xy, stress, h) ≈ K rtol=3e-12 atol=2e-9
            @test corrected(xy,stress,0.) == zeros(24,24)
            # Property sensitivity differentiates this same frozen-stress
            # operator; retaining dual values is part of the kernel contract.
            denergy = ForwardDiff.derivative(t -> dot(w,corrected(xy,t*stress,h)[WD,WD]*w),1.)
            @test denergy ≈ dot(w,K[WD,WD]*w) rtol=3e-12 atol=2e-9
            if ci == 1
                @test K ≈ before rtol=3e-13 atol=2e-10
            end
        end
        for xy in cells
            @test minimum(eigvals(Symmetric(corrected(xy,stresses[1],h)[WD,WD]))) >= -1e-11*norm(corrected(xy,stresses[1],h)[WD,WD])
            @test corrected(xy,vec(stresses[1][1,:]),h) ≈ corrected(xy,stresses[1],h) rtol=3e-12 atol=2e-9
        end
    end
end
end
