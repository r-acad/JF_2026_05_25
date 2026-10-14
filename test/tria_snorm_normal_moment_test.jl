using Test
module TriaSnormFixture
using Test, OpenJFEM, LinearAlgebra
const S = OpenJFEM.Solver
function checks()
    mktempdir() do dir
        points = [0. 0. 0.; 2. 0. 0.; .3 1.1 0.; 1.4 -.9cosd(20) .9sind(20)]
        path = joinpath(dir, "fold.bdf")
        text = "SOL 101\nCEND\nBEGIN BULK\nPARAM,K6ROT,0.\nPARAM,SNORM,20.\nMAT1,1,7.E10,,.3\nPSHELL,1,1,.025,1,,1\n"
        for i in 1:4
            text *= "GRID,$i,," * join(points[i, :], ",") * "\n"
        end
        text *= "CTRIA3,10,1,1,2,3\nCTRIA3,11,1,2,1,4\nENDDATA\n"
        write(path, text)
        model = OpenJFEM.bdf_to_model(path)
        captured = S.analytic_shell_contexts(model; membrane_incomp=true, sol101_context=true)
        a = captured.assembly
        K, ids, xyz, ndof, node_R, _, rbe, normals = a[1:8]
        K = Matrix(K)
        @test norm(K-K') < 2e-13norm(K)
        @test eigmin(Symmetric(K)) > -2e-13norm(K)
        rigid = zeros(24, 6)
        for axis in 1:3
            e = zeros(3); e[axis] = 1.
            for i in 1:4
                rigid[6i-5:6i-3, axis] = e
                rigid[6i-5:6i-3, axis+3] = cross(e, xyz[i, :])
                rigid[6i-2:6i, axis+3] = e
            end
        end
        @test norm(K*rigid) < 2e-13norm(K)*norm(rigid)
        # Shared nodes have one common drilling null, not separate element normals.
        for id in (1, 2)
            drill = zeros(24);i = ids[id]
            drill[6i-2:6i] = normals[i]
            @test norm(K*drill) < 2e-13norm(K)
        end
        @test S.tria3_snorm_normal_moment_displacement_map([0. 0.;1. 0.;0. 1.], zeros(3,2)) == Matrix{Float64}(I,18,18)
        @test_throws ArgumentError S.tria3_snorm_normal_moment_displacement_map(zeros(3,2), ones(3,2))

        # The actual geometric stiffness path must use all off-diagonal blocks
        # of the map when recovering preload strains; it is not block diagonal.
        u = 1e-4sin.(collect(1.:24.))
        # The legacy native local adjoint builds only a block-diagonal frame.
        # Fail before a partial gradient rather than silently omit this map;
        # the captured constitutive derivatives tested below remain supported.
        dv = Dict{String,Any}("type"=>"shell_thickness", "pids"=>[1])
        @test_throws ErrorException S.compute_dKdx_u(dv, model, ids, xyz, node_R, u, ndof)
        @test S._adjoint_has_active_completed_q4_snorm(model, ids, xyz)
        minimal_results = Dict{String,Any}("model"=>model, "id_map"=>ids, "node_coords"=>xyz)
        @test_throws ErrorException S._solve_adjoint_buckling_case(minimal_results,
            Dict("design_variables"=>[dv]))
        for other in (Dict("type"=>"bar_area", "pids"=>[1]),
                      Dict("type"=>"node_coord", "grid"=>1),
                      Dict("type"=>"shell_thickness", "pids"=>[99]))
            @test S._guard_mapped_quad4_local_dkdx!(other, model, ids, xyz) === nothing
        end
        # A bar-only DV must not bypass the independent response-element guard.
        # Native response evaluation is also used by its gradient builders.
        response = Dict{String,Any}("type"=>"von_mises", "eid"=>10)
        @test_throws ErrorException S.evaluate_response(response, u, model, ids, ndof, xyz, node_R)
        @test_throws ErrorException S.evaluate_response(
            Dict("type"=>"shell_moment_mx", "eid"=>10), u, model, ids, ndof, xyz, node_R)
        @test S.evaluate_response(Dict("type"=>"displacement", "grid"=>1, "dof"=>1),
            u, model, ids, ndof, xyz, node_R) == u[1]
        withenv("JFEM_PARAM_SNORM_OVERRIDE"=>"0", "JFEM_PARAM_SNORM_OVERRIDE_STATIC"=>"0",
                "JFEM_PARAM_SNORM_OVERRIDE_EIG"=>"0", "JFEM_PARAM_SNORM_OVERRIDE_KG"=>"0") do
            @test S._guard_mapped_quad4_local_dkdx!(dv, model, ids, xyz) === nothing
            @test !S._adjoint_has_active_completed_q4_snorm(model, ids, xyz)
            @test isfinite(S.evaluate_response(response, u, model, ids, ndof, xyz, node_R))
        end
        # T3 activation is independent of the optional Q4 curvature map.
        withenv("JFEM_Q4_SNORM_CURVATURE"=>"0") do
            @test_throws ErrorException S._guard_mapped_quad4_local_dkdx!(dv, model, ids, xyz)
            @test S._adjoint_has_active_completed_q4_snorm(model, ids, xyz)
        end
        kg_capture = Dict{Int,Any}()
        S.assemble_geometric_stiffness(model, ids, xyz, node_R, ndof, u, normals, rbe;
            geometric_capture=(eid,data)->(kg_capture[eid]=deepcopy(data)))
        output = Dict{String,Any}(key=>Dict("quad4"=>Any[], "tria3"=>Any[]) for key in
            ("forces", "forces_bilin", "stresses", "strains"))
        S.recover_shell_stresses!(model, ids, xyz, node_R, u, normals, Dict{Int,Float64}(), output)
        @test length(output["forces"]["tria3"]) == 2
        for (eid, ctx) in captured.contexts
            data = kg_capture[eid]
            @test isapprox(data[:T18], ctx.transform; rtol=2e-13, atol=1e-14)
            @test isapprox(data[:u_elem18], ctx.transform*u[ctx.dofs]; rtol=2e-13, atol=1e-15)
            row = only(filter(row->row["eid"]==eid, output["forces"]["tria3"]))
            @test isapprox([row[k] for k in ("fx","fy","fxy")], data[:N_res]; rtol=2e-12, atol=1e-7)
            # Frozen geometry transform preserves exact constitutive tangents.
            tangent = S.analytic_shell_tangent(ctx, (thickness=1.,))
            step = 1e-6
            matrices = Matrix{Float64}[]
            for sign in (-1.,1.)
                perturbed = deepcopy(model)
                perturbed["PSHELLs"]["1"]["T"] += sign*step
                replay = S.analytic_shell_contexts(perturbed; membrane_incomp=true, sol101_context=true)
                push!(matrices, replay.contexts[eid].Ke)
            end
            derivative = (matrices[2]-matrices[1])/(2step)
            @test norm(derivative-tangent.dKe) < 2e-8norm(tangent.dKe)
            for axis in 1:6
                feature = S.analytic_shell_stress_tangent(ctx, (thickness=1.,), rigid[:,axis], ids, xyz, node_R, normals)
                @test norm(feature.features) < 2e-3
            end
        end
        # Demonstrate that the old mean-frame projection failed the physical
        # rigid-motion check. This diagnostic is not an alternative default.
        old = withenv("JFEM_TRIA3_SNORM_NORMAL_MOMENT"=>"0") do
            Matrix(S.assemble_stiffness(model;membrane_incomp=true,sol101_context=true)[1])
        end
        @test norm(old*rigid) > 1e5norm(K*rigid)
    end
end
end
@testset "Triangle SNORM rigid motion, drilling null and recovery consistency" begin
    TriaSnormFixture.checks()
end
