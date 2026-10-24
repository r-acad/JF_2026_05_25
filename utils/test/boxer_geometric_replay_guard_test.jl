using Test
module BoxerGeometricReplayGuardFixture
using Test,LinearAlgebra,OpenJFEM
const S=OpenJFEM.Solver
include(joinpath(@__DIR__,"..","..","APPS","JFEM-Boxer","src","sensitivity_analytic_geometric.jl"))
function context(path)
    write(path,"""
SOL 105
CEND
BEGIN BULK
PARAM,SNORM,0.
PARAM,K6ROT,1.
GRID,1,,0.,0.,0.
GRID,2,,2.,0.,0.
GRID,3,,2.,1.,0.
GRID,4,,0.,1.,0.
MAT1,1,7.E10,,.3,2700.
PCOMP,10
+,1,.002,0.,YES
CQUAD4,1,10,1,2,3,4
ENDDATA
""")
    model=OpenJFEM.bdf_to_model(path)
    ids=Dict(i=>i for i=1:4);X=[0. 0. 0.;2. 0. 0.;2. 1. 0.;0. 1. 0.]
    R=[Matrix{Float64}(I,3,3) for _=1:4]
    normals=S.compute_snorm_normals(model,ids,X)
    mapping=S.assemble_constraints(model,ids,X,R,Int[],Int[],Float64[])[1]
    state=[1e-4*sin(.7i) for i=1:24];contexts=Any[]
    callback=function(eid,data)
        c=Dict(k=>deepcopy(data[k]) for k in SENSITIVITY_GEOMETRIC_KEYS if haskey(data,k))
        c[:eid]=eid;c[:model]=model;push!(contexts,c)
    end
    S.assemble_geometric_stiffness(model,ids,X,R,24,state,normals,mapping;
        snorm_angle_override=0.,geometric_capture=callback)
    only(contexts)
end
function checks()
    mktempdir() do dir
        path=joinpath(dir,"boxer_replay.bdf")
        c=context(path)
        @test c[:kg_reference_kdjj_iso_branch]
        @test c[:kg_coupled_condensed]
        @test c[:kg_differential_prestress]
        @test sensitivity_geometric_shell_check(OpenJFEM,c)<2e-9
        replay=sensitivity_geometric_shell_replay(OpenJFEM,c)
        @test isapprox(replay,c[:Kg_global];rtol=2e-9)
        # The default isotropic branch takes precedence even though section
        # eligibility was computed earlier by the actual assembler.
        doubled=sensitivity_geometric_shell_replay(OpenJFEM,c;local_state=2c[:u_elem24])
        @test isapprox(doubled,2replay;rtol=2e-12)
        for differential in ("true","false")
            unsupported=withenv("JFEM_KG_QUAD4_ISO_REFERENCE_KDJJ"=>"off",
                    "JFEM_Q4_DIFFERENTIAL_PRESTRESS"=>differential) do
                context(path)
            end
            @test !unsupported[:kg_reference_kdjj_iso_branch]
            @test unsupported[:kg_coupled_condensed]
            @test unsupported[:kg_differential_prestress]==(differential=="true")
            failure=try
                sensitivity_geometric_shell_replay(OpenJFEM,unsupported)
                nothing
            catch e
                e
            end
            @test failure isa ArgumentError
            message=sprint(showerror,failure)
            @test occursin("exact replay",message)
            @test occursin(differential=="true" ? "kg_differential_prestress" : "kg_coupled_condensed",message)
        end
    end
end
end
@testset "Boxer geometric sensitivity preserves resolved operator scope" begin
    BoxerGeometricReplayGuardFixture.checks()
end
