using Test, LinearAlgebra, OpenJFEM

@testset "SOL101 shell stiffness is independent of disconnected constraints" begin
    mktempdir() do dir
        function local_shell_matrix(material, extra=""; warp=0.0)
            path = joinpath(dir, "locality.bdf")
            write(path, """
SOL 101
CEND
BEGIN BULK
PARAM,AUTOSPC,NO
GRID,1,,0.,0.,0.
GRID,2,,2.,0.,0.
GRID,3,,2.,1.,0.
GRID,4,,0.,1.,$warp
$material
MAT1,2,7.E10,,.3
PSHELL,1,1,.01,1,,2
CQUAD4,1,1,1,2,3,4
$extra
ENDDATA
""")
            model = OpenJFEM.bdf_to_model(path)
            assembled = OpenJFEM.Solver.assemble_stiffness(model;
                membrane_incomp=true, sol101_context=true)
            K, ids = assembled[1], assembled[2]
            dofs = vcat([collect(6(ids[n]-1) .+ (1:6)) for n in 1:4]...)
            Matrix(K[dofs, dofs])
        end
        remote_grids = "GRID,101,,10.,0.,0.\nGRID,102,,11.,0.,0.\n"
        remote_rigid = remote_grids * "RBE2,10,101,123456,102"
        remote_mpc = remote_grids * "MPC,10,101,1,1.,102,1,-1."
        mat1 = "MAT1,1,7.E10,,.3"
        mat2 = "MAT2,1,1.1E11,2.E10,5.E9,7.E10,3.E9,3.E10"
        # The planar materials now use the compatible projected membrane.
        # Retain a genuinely warped MAT2 cell to exercise Wilson selection
        # and its historical global-topology switch independently of that fix.
        materials = [(mat1,0.0), (mat2,0.0), (mat2,0.004)]
        changed_by_old_gate = Float64[]
        withenv("JFEM_SOL101_Q4_CROSS_MEMBRANE_WEIGHTS_MIXED_TOPOLOGY" => nothing,
                "JFEM_SOL101_Q4_MEMBRANE_INCOMP_MODE_WEIGHTS" => nothing,
                "JFEM_Q4_MEMBRANE_INCOMP_MODE_WEIGHTS" => nothing) do
            for (material,warp) in materials
                standalone = local_shell_matrix(material;warp=warp)
                @test norm(standalone) > 0
                @test isapprox(standalone, standalone'; rtol=1e-13)
                for connection in (remote_rigid, remote_mpc)
                    @test isapprox(local_shell_matrix(material, connection;warp=warp), standalone;
                        rtol=1e-12, atol=0)
                end
                legacy = withenv("JFEM_SOL101_Q4_CROSS_MEMBRANE_WEIGHTS_MIXED_TOPOLOGY" => "0") do
                    local_shell_matrix(material, remote_rigid;warp=warp)
                end
                push!(changed_by_old_gate, norm(legacy-standalone)/norm(standalone))
            end
        end
        # Ensure this fixture actually exercises the historical global gate.
        @test maximum(changed_by_old_gate) > 1e-4
    end
end
