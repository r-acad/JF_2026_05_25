module PbeamNonlinearScopeTests

using Test, OpenJFEM
const S = OpenJFEM.Solver

@testset "SOL106 offset PBEAM preflight covers every nonlinear route" begin
    mktempdir() do folder
        deck=joinpath(folder,"mixed_shell_beam.bdf")
        write(deck,"""
        SOL 106
        CEND
        BEGIN BULK
        GRID,1,,0.,0.,0.
        GRID,2,,1.,0.,0.
        GRID,3,,1.,1.,0.
        GRID,4,,0.,1.,0.
        MAT1,1,7.3e10,,.29
        PSHELL,1,1,.003,1
        CQUAD4,1,1,1,2,3,4
        PBEAM,2,1,.00047,2.1e-7,8.3e-8,-3.2e-8,8.2e-9
        +,0.,0.,0.,0.,0.,0.,0.,0.
        +,.72,.56
        +,,,,,.017,-.029
        CBEAM,2,2,1,2,0.,1.,0.
        ENDDATA
        """)
        model=OpenJFEM.bdf_to_model(deck)
        withenv("JFEM_PBEAM_NEUTRAL_AXIS_COUPLING"=>nothing) do
            K,ids,coords,ndof,rotations=redirect_stdout(devnull) do
                S.assemble_stiffness(model)[1:5]
            end
            # This mixed model passes the formal shell selector. Testing the
            # public nonlinear entry catches a bypass of geometric assembly.
            @test S._formal_von_karman_shell_support_report(model,ids,coords).supported
            for method in (:auto,:formal_shell_von_karman)
                error = try
                    S.solve_nonlinear_static(K,ndof,model,ids,coords,nothing,nothing,rotations;
                        nonlinear_method=method)
                    nothing
                catch exception
                    exception
                end
                @test error isa ArgumentError
                @test occursin("PBEAM neutral-axis offsets N1/N2",sprint(showerror,error))
            end
            builder_called=Ref(false)
            builder=(args...;kwargs...)->(builder_called[]=true)
            @test_throws ArgumentError S.solve_nonlinear_static(
                K,ndof,model,ids,coords,nothing,nothing,rotations;nonlinear_state_builder=builder)
            @test !builder_called[]
            # Ordinary beams and an explicit legacy opt-out keep their scope.
            withenv("JFEM_PBEAM_NEUTRAL_AXIS_COUPLING"=>"false") do
                @test S._assert_nonlinear_pbeam_neutral_axis_supported(model)===nothing
            end
            for key in ("N1A","N1B","N2A","N2B")
                model["PBARLs"]["2"][key]=0.
            end
            @test S._assert_nonlinear_pbeam_neutral_axis_supported(model)===nothing
        end
    end
end

end
