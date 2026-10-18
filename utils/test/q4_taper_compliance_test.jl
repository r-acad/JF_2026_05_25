using Test, LinearAlgebra, OpenJFEM, ForwardDiff

@testset "Orthotropic taper complementary energy" begin
    F = OpenJFEM.FEM
    h = 0.012
    Cs = [2.7e8 0.0; 0.0 2.7e8]
    function shear_operator(xy, D1, D2)
        T = promote_type(typeof(D1), typeof(D2))
        Cb = Matrix(Diagonal(T[D1, D2, 2400.0]))
        K = zeros(T, 24, 24)
        mw = F.create_macneal_shear_workspace(T)
        F.add_quad4_macneal_shear_rbf!(K, xy, Cb, Cs, h; msws=mw)
        return K, copy(mw.Z_total)
    end
    geometries = (
        [0.0 0.0; 1.8 0.0; 1.4 0.9; 0.4 0.9],
        [0.0 0.0; 0.6 0.0; 1.0 1.2; -0.4 1.2],
        [0.0 0.0; 2.0 0.0; 1.8 1.1; 0.5 0.8],
        [0.0 0.0; 1.8 0.0; 2.3 0.9; 0.5 0.9],
    )
    for xy in geometries
        # Complementary energy is affine in the directional flexibilities.
        # This identity fails with a geometric-mean material cross term.
        _, Za = shear_operator(xy, 13000.0, 1800.0)
        _, Zb = shear_operator(xy, 2100.0, 9000.0)
        mix = 0.37
        D1 = inv(mix/13000.0 + (1-mix)/2100.0)
        D2 = inv(mix/1800.0 + (1-mix)/9000.0)
        K, Zmix = shear_operator(xy, D1, D2)
        @test Zmix ≈ mix*Za + (1-mix)*Zb rtol=2e-12
        @test K ≈ K' rtol=2e-14
        @test eigmin(Symmetric(K)) >= -2e-12*opnorm(K)

        rigid = zeros(24,6)
        for i in 1:4
            j=6(i-1);x,y=xy[i,:]
            rigid[j+1:j+3,1:3] .= Matrix{Float64}(I,3,3)
            rigid[j+1:j+3,4:6] .= [0.0 0.0 -y; 0.0 0.0 x; y -x 0.0]
            rigid[j+4:j+6,4:6] .= Matrix{Float64}(I,3,3)
        end
        @test norm(K*rigid) <= 3e-13*norm(K)*norm(rigid)

        # Rotate geometry and material axes by 90 degrees and exchange the
        # natural axes. The low-level kernel expects the element-frame
        # convention; assembly supplies the corresponding cyclic numbering.
        R = [0.0 -1.0; 1.0 0.0]
        order = (4,1,2,3)
        KR, _ = shear_operator((xy*R')[collect(order),:], D2, D1)
        Q3 = [0.0 -1.0 0.0; 1.0 0.0 0.0; 0.0 0.0 1.0]
        Q = kron(Matrix{Float64}(I,8,8),Q3)
        dofs = vcat((collect(6(i-1) .+ (1:6)) for i in order)...)
        @test KR ≈ (Q*K*Q')[dofs,dofs] rtol=3e-12
    end

    xy = first(geometries)
    # Constitutive tangents must follow the same corrected primal operator.
    p = [13000.0, 1800.0]
    fun = x -> vec(first(shear_operator(xy,x[1],x[2])))
    exact = ForwardDiff.jacobian(fun,p)
    finite = similar(exact)
    for j in 1:2
        step = 1e-5*p[j]
        plus=copy(p);minus=copy(p);plus[j]+=step;minus[j]-=step
        finite[:,j] = (fun(plus)-fun(minus))/(2step)
    end
    @test exact ≈ finite rtol=2e-8

    @testset "Partially degenerate tapered bending scope" begin
        trap = first(geometries)
        rect = [0.0 0.0; 1.8 0.0; 1.8 0.9; 0.0 0.9]
        function degenerate_shear(xy, cb)
            K = zeros(24,24)
            F.add_quad4_macneal_shear_rbf!(K,xy,Matrix(Diagonal(cb)),Cs,h)
            K
        end
        @test_throws ArgumentError degenerate_shear(trap,[0.0,1800.0,2400.0])
        @test_throws ArgumentError degenerate_shear(trap,[1800.0,0.0,2400.0])
        @test all(isfinite,degenerate_shear(trap,[0.0,0.0,0.0]))
        @test all(isfinite,degenerate_shear(rect,[0.0,1800.0,2400.0]))
        @test all(isfinite,degenerate_shear(rect,[1800.0,0.0,2400.0]))
    end
end
