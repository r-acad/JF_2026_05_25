module K6rotMetadataTests
using Test, OpenJFEM, LinearAlgebra, JSON
const S = OpenJFEM.Solver
const EVIDENCE = Dict{String,Any}()

function fixture(directory)
    path = joinpath(directory,"k6rot_shell.bdf")
    write(path,"""
SOL 105
CEND
SUBCASE 1
 SPC = 1
 LOAD = 1
SUBCASE 2
 SPC = 1
 METHOD = 1
 STATSUB = 1
BEGIN BULK
PARAM,K6ROT,1.
PARAM,AUTOSPC,YES
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,1.,1.,0.
GRID,4,,0.,1.,0.
CQUAD4,1,1,1,2,3,4
PSHELL,1,1,.02,1,,1
MAT1,1,7.E10,,.3,2700.
SPC1,1,123456,1,4
FORCE,1,2,0,-1000.,1.,0.,0.
FORCE,1,3,0,-1000.,1.,0.,0.
EIGRL,1,0.,1.E9,3
ENDDATA
""")
    OpenJFEM.bdf_to_model(path)
end

@testset "K6ROT metadata matches effective assembly and shared SOL105 operator" begin
    withenv("JFEM_PARAM_K6ROT"=>nothing,"JFEM_PARAM_K6ROT_STATIC"=>nothing,"JFEM_PARAM_K6ROT_EIG"=>nothing) do
        for solution in (101,103,105,106,129)
            model=Dict{String,Any}("SOL"=>solution)
            expected=solution in (106,129) ? 100.0 : 0.0
            for branch in (false,true)
                data=S.k6rot_metadata(model,branch)
                @test data["value"] == expected == S.solver_k6rot(S.reference_k6rot_default(model),branch)
                @test data["source"] == "sequence_default:SOL$solution"
            end
            model["PARAM_K6ROT"]=1.
            @test S.k6rot_metadata(model)["value"] == 1.
            @test S.k6rot_metadata(model)["source"] == "deck:PARAM,K6ROT"
        end
        model=Dict{String,Any}("SOL"=>105,"PARAM_K6ROT"=>1.)
        withenv("JFEM_PARAM_K6ROT"=>"3", "JFEM_PARAM_K6ROT_STATIC"=>"4", "JFEM_PARAM_K6ROT_EIG"=>"5") do
            @test S.k6rot_metadata(model,false)["value"] == 4.
            @test S.k6rot_metadata(model,true)["value"] == 5.
            @test S.k6rot_metadata(model,false)["source"] == "environment:JFEM_PARAM_K6ROT_STATIC"
            @test S.k6rot_metadata(model,true)["source"] == "environment:JFEM_PARAM_K6ROT_EIG"
            report=S.sol105_options_metadata(S.SOL105Options(),model)
            @test report["k6rot"] == report["k6rot_static"] == report["k6rot_eigen"] == 4.
            @test report["k6rot_legacy_option"] == 3.
            @test !report["k6rot_legacy_option_consumed"]
            @test report["k6rot_resolution"]["eigen_stiffness_reuses_static"]
            @test report["k6rot_resolution"]["eigen_override_used"] === false
            @test report["k6rot_resolution"]["eigen"]["operator_source"] == "reused_static_stiffness"
            @test JSON.parse(JSON.json(report))["k6rot"] == 4.
            EVIDENCE["branch_overrides"] = report
        end
        withenv("JFEM_PARAM_K6ROT"=>"3") do
            @test S.k6rot_metadata(model)["value"] == 3.
            @test S.k6rot_metadata(model)["source"] == "environment:JFEM_PARAM_K6ROT"
            # Preserve the established semantics: an explicit blank/invalid
            # branch override masks the generic ENV and falls back to the deck.
            for value in ("", "invalid")
                withenv("JFEM_PARAM_K6ROT_STATIC"=>value) do
                    @test S.k6rot_metadata(model)["value"] == 1.
                    @test S.k6rot_metadata(model)["source"] == "deck:PARAM,K6ROT"
                    @test !S.k6rot_metadata(model)["override_applied"]
                end
            end
        end
        unknown=S.sol105_options_metadata(S.SOL105Options(),model;shared_stiffness=false)
        @test unknown["k6rot_eigen"] === nothing
        @test unknown["k6rot_resolution"]["eigen_override_used"] === nothing
        @test unknown["k6rot_resolution"]["eigen"]["source"] == "unknown"
        @test occursin("not consumed",sprint(io->S.summary(S.SOL105Options(),io)))
        mktempdir() do directory
            # This tiny actual SOL105 solve verifies the emitted footer and
            # proves an EIG-only override cannot change a shared static K.
            deck=fixture(directory)
            baseline=redirect_stdout(devnull) do
                OpenJFEM.solve_model(OpenJFEM.ReferenceParityBackend(),deck)
            end
            overridden=withenv("JFEM_PARAM_K6ROT_EIG"=>"29") do
                redirect_stdout(devnull) do
                    OpenJFEM.solve_model(OpenJFEM.ReferenceParityBackend(),deepcopy(deck))
                end
            end
            @test !isempty(baseline["eigenvalues"])
            @test all(isfinite,baseline["eigenvalues"])
            @test baseline["K"] == baseline["K_eig"] == overridden["K"] == overridden["K_eig"]
            @test baseline["eigenvalues"] ≈ overridden["eigenvalues"] rtol=1e-12
            for result in (baseline,overridden)
                footer=only(result["buckling"].subcases).details["sol105_options"]
                @test footer["k6rot"] == footer["k6rot_static"] == footer["k6rot_eigen"] == 1.
                @test footer["k6rot_resolution"]["static"]["source"] == "deck:PARAM,K6ROT"
                @test only(filter(row->get(row,"buckling_subcase",nothing)==2,result["solver_diagnostics"]))["details"]["sol105_options"] == footer
                @test footer["k6rot_legacy_option"] == 0.
            end
            EVIDENCE["actual_sol105"] = Dict("eigenvalues"=>baseline["eigenvalues"],"K_unchanged"=>true,
                "footer"=>only(overridden["buckling"].subcases).details["sol105_options"])
        end
    end
end
end
