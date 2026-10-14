using Test, JSON, OpenJFEM

@testset "Measured timing export supports long output paths" begin
    scratch=mktempdir(;cleanup=false)
    try
        deck=joinpath(scratch,"beam.bdf")
        write(deck,"""
SOL 101
CEND
SUBCASE 1
 SPC = 1
 LOAD = 1
BEGIN BULK
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
CBAR,1,1,1,2,0.,1.,0.
PBAR,1,1,1.E-4,1.E-8,1.E-8,2.E-8
MAT1,1,7.E10,,.3,2700.
SPC1,1,123456,1
FORCE,1,2,0,100.,0.,0.,-1.
ENDDATA
""")
        output=joinpath(scratch,repeat("first_",14),repeat("second_",14),repeat("third_",14))
        timing=joinpath(output,"beam.TIMINGS.JSON")
        @test length(abspath(timing))>260
        log=joinpath(scratch,"solver.log")
        open(log,"w") do io
            redirect_stdout(io) do
                OpenJFEM.main(deck;output_dir=output,export_jfem_binary=false,export_report=false)
            end
        end
        payload=JSON.parsefile(OpenJFEM._export_fs_path(timing))
        @test payload["schema_version"]==2
        # Schema 2 totals exclusive numerical stages once, excluding preparation
        # and export. Unavailable compilation separation remains unavailable.
        numerical=[row for row in payload["stages"] if row["category"]=="numerical"]
        @test !isempty(numerical)
        @test any(row->row["depth"]>0,numerical)
        execution=[row["exclusive"]["execution_seconds"] for row in numerical]
        if any(isnothing,execution)
            @test payload["solution_seconds"]===nothing
        else
            @test payload["solution_seconds"]≈sum(execution) atol=1e-12
        end
        @test payload["measured_wall_seconds"]>=payload["phases"]["solve"]["wall_seconds"]
        marker=only(filter(line->startswith(line,"[JFEM_TIMINGS] "),readlines(log)))
        @test JSON.parse(chopprefix(marker,"[JFEM_TIMINGS] "))==payload
    finally
        # Julia's default temporary-directory cleanup does not extend Windows
        # paths; use the same filesystem helper as the tested exporter.
        @assert dirname(realpath(scratch))==realpath(tempdir())
        cleanup_path=OpenJFEM._export_fs_path(scratch)
        if Sys.iswindows() && !startswith(cleanup_path,"\\\\?\\")
            cleanup_path="\\\\?\\"*cleanup_path
        end
        rm(cleanup_path;recursive=true)
    end
end
