using Test
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen
isempty(ARGS) || length(ARGS)==2 || error("Usage: job_pipeline_progress_test.jl [native.log fixture.json]")

@testset "Structured native stages and timing bridge" begin
    mktempdir() do dir
        model=W.build_model(merge(W.default_params(),Dict("output.solution"=>"105",
            "planform.area"=>4.,"planform.aspect_ratio"=>4.,"box.rib_pitch"=>2.,
            "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1)))
        job=W.JfemJob("timing","test",joinpath(dir,"fixture.bdf"),dir,joinpath(dir,"job.log"),
            dir,model,nothing,String[],ReentrantLock(),time(),nothing,:running,0,"")
        emit(event)=W.append_job_lines!(job,["[JFEM_PROGRESS] "*W.JSON.json(event)])
        event=Dict{String,Any}("schema_version"=>1,"id"=>"solve:2","phase"=>"assembly",
            "label"=>"Assemble elastic stiffness","category"=>"numerical","parent"=>"solve",
            "depth"=>1,"state"=>"started","resumed"=>false,"elapsed_seconds"=>0.,
            "compilation_live"=>"not_separable")
        emit(event);p=W.job_progress(job)
        @test p["stage"]=="assembly" && p["stage_category"]=="numerical"
        @test p["compilation_live"]=="not_separable"
        @test occursin("compilation",p["stage_message"])
        @test p["stage_parent"]=="solve" && p["stage_depth"]==1
        W.append_job_lines!(job,["[SOLVER] Post-Processing..."])
        @test W.job_progress(job)["stage"]=="assembly" # Structured event takes precedence.
        event["state"]="completed";event["elapsed_seconds"]=2.
        event["timing"]=Dict{String,Any}("wall_seconds"=>2.,"compilation_seconds"=>.8,
            "recompilation_seconds"=>.1,"execution_seconds"=>1.2,"gc_seconds"=>.05)
        emit(event);p=W.job_progress(job)
        @test p["stage_seconds"]==2.
        @test p["stage_timing"]["execution_seconds"]==1.2
        @test p["compilation_live"]=="measured_retrospectively"
        event["timing"]["execution_seconds"]=nothing
        emit(event)
        @test W.job_progress(job)["stage_timing"]["execution_seconds"]===nothing
        before=copy(job.progress)
        W.append_job_lines!(job,["[JFEM_PROGRESS] not JSON"])
        @test job.progress==before
        event["state"]="started";event["resumed"]=true;delete!(event,"timing")
        emit(event)
        @test !haskey(W.job_progress(job),"stage_timing")
        @test W.job_progress(job)["compilation_live"]=="not_separable"

        if length(ARGS)==2
            events=Any[];payload=nothing
            bytes=read(ARGS[1])
            log=length(bytes)>=2 && bytes[1:2]==UInt8[0xff,0xfe] ?
                transcode(String,reinterpret(UInt16,bytes[3:end])) : String(bytes)
            for line in split(log,'\n')
                if startswith(line,"[JFEM_PROGRESS] ")
                    push!(events,W.JSON.parse(line[length("[JFEM_PROGRESS] ")+1:end]))
                    W.append_job_lines!(job,[line])
                elseif startswith(line,"[JFEM_TIMINGS] ")
                    payload=W.JSON.parse(line[length("[JFEM_TIMINGS] ")+1:end])
                    W.append_job_lines!(job,[line])
                end
            end
            @test payload!==nothing && !isempty(events)
            # Controlled process clock tests overhead arithmetic. Native stage
            # times/events below are unchanged measurements from the real solve.
            job.started=100.;job.finished=102. + payload["measured_wall_seconds"];job.state=:done
            timing=W.job_timings(job)
            @test timing["available"]
            @test timing["solution_seconds"]==payload["solution_seconds"]
            @test timing["preparation_seconds"]==payload["preparation_seconds"]
            @test timing["export_seconds"]==payload["export_seconds"]
            @test timing["startup_overhead_seconds"]≈2.
            @test length(timing["stages"])==length(payload["stages"])
            @test all(r->r["case_id"]==1 && r["solution"]=="105",timing["stages"])
            @test all(e->e["compilation_live"]=="not_separable",filter(e->e["state"]=="started",events))
            @test sum(r["exclusive"]["wall_seconds"] for r in timing["stages"])≈payload["measured_wall_seconds"]
            for invalid in (merge(payload,Dict("stages"=>nothing)),merge(payload,Dict("stages"=>[nothing])),
                    merge(payload,Dict("preparation_seconds"=>"unknown")),merge(payload,Dict("phases"=>Dict("solve"=>nothing))))
                W.append_job_lines!(job,["[JFEM_TIMINGS] "*W.JSON.json(invalid)])
                @test W.job_timings(job)==timing # Keep last valid telemetry.
            end
            fixture=Dict("origin"=>"Real native stage measurements; controlled bridge process clock adds 2 s overhead for arithmetic verification.",
                "events"=>events,"job"=>Dict("state"=>"done","seconds"=>W.job_seconds(job),
                "progress"=>W.job_progress(job),"timings"=>timing))
            mkpath(dirname(abspath(ARGS[2])));write(ARGS[2],W.JSON.json(fixture,2))
        end
    end
end
