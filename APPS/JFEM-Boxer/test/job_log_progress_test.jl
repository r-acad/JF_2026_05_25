using Test
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const L=WingFEGen

@testset "Bounded live logs, complete streamed disk logs, and SOL106 progress" begin
    mktempdir() do dir
        p=merge(L.default_params(),Dict("output.solution"=>"106","planform.area"=>4.0,
            "planform.aspect_ratio"=>4.0,"box.rib_pitch"=>2.0,"mesh.elements_between_ribs"=>1,
            "mesh.elements_spar_height"=>1))
        m=L.build_model(p)
        job(id)=L.JfemJob(id,"test",joinpath(dir,"unused.bdf"),dir,joinpath(dir,id*".log"),
            dir,m,nothing,String[],ReentrantLock(),time(),nothing,:running,0,"")
        live=job("live")
        for first in 1:1000:50000
            L.append_job_lines!(live,["line $n "*repeat("x",80) for n in first:first+999])
        end
        @test L.job_line_count(live)==50000
        @test length(live.lines)<=L.JOB_LOG_MAX_LINES
        @test live.log_bytes<=L.JOB_LOG_MAX_BYTES
        @test length(readlines(live.logpath))==50000
        batch=L.job_log_batch(live,0)
        @test batch.omitted_lines==live.log_offset
        @test batch.first_line==live.log_offset+1
        @test batch.next_line==live.log_offset+length(batch.lines)
        cursor=0; collected=String[]; calls=0
        while true
            b=L.job_log_batch(live,cursor);calls+=1
            @test length(b.lines)<=200
            @test sum(ncodeunits,b.lines;init=0)<=65536
            @test b.next_line>=cursor
            append!(collected,b.lines);cursor=b.next_line
            b.has_more || break
        end
        @test calls>1
        @test cursor==50000
        @test collected==live.lines
        @test isempty(L.job_log_batch(live,cursor).lines)
        @test L.job_log_batch(live,-99).omitted_lines==live.log_offset
        @test L.job_log_batch(live,typemax(Int)).next_line==50000

        huge=repeat("α翼🙂",10000)
        @test isvalid(L.bounded_log_line(huge))
        @test ncodeunits(L.bounded_log_line(huge))<=8192
        @test endswith(L.bounded_log_line(huge),L.JOB_LOG_TRUNCATED)
        for _ in 1:600
            L.append_job_lines!(live,[huge])
        end
        @test live.log_bytes<=L.JOB_LOG_MAX_BYTES
        @test ncodeunits(L.job_log(live;tail=0))<=65536
        @test L.job_line_count(live)==50600
        @test last(readlines(live.logpath))==huge

        # Parent aggregation reads the full disk stream, never the truncated ring.
        child=job("child");child.case_id=7
        parent=job("parent");push!(parent.runs,child)
        original=join(["native $i" for i in 1:12000],"\n")*"\n"*huge*"\npartial α🙂"
        write(child.logpath,original)
        c=L.JobDiskCursor()
        while L.drain_child_log!(parent,child,c;final=true)>0
            @test length(c.preview)<=8192
        end
        prefix="[Case 7, SOL106] "
        expected=join((prefix*line for line in split(original,'\n')),"\n")*"\n"
        @test read(parent.logpath,String)==expected
        @test L.job_line_count(parent)==12002
        @test length(parent.lines)<=4000
        @test parent.log_bytes<=1024*1024
        @test all(isvalid,parent.lines)
        @test last(parent.lines)==prefix*"partial α🙂"

        progress=job("progress")
        native(target,iter)= "[SOLVER] NL target=$target iter $iter: rel_change=0.01, rel_res_before=0.03, rel_res_after=1.0e-5, alpha=1.0"
        L.append_job_lines!(progress,[native("0.125",1)])
        @test L.job_progress(progress)["target_percent"]==12.5
        @test L.job_progress(progress)["accepted_percent"]==0
        L.append_job_lines!(progress,[native("0.2812",1),native("0.2812",2)])
        @test L.job_progress(progress)["accepted_percent"]==12.5
        L.append_job_lines!(progress,["[SOLVER] NL cutback: retrying with reduced load increment 0.078 (target scale 0.2031)"])
        q=L.job_progress(progress)
        @test q["phase"]=="cutback" && q["attempt"]==2 && q["cutbacks"]==1
        @test q["accepted_percent"]==12.5 && q["target_percent"]≈20.31
        L.append_job_lines!(progress,[native("2.031e-1",3)])
        @test L.job_progress(progress)["attempt"]==2
        @test L.job_progress(progress)["iteration"]==3
        L.append_job_lines!(progress,[native("1.0",1)])
        @test L.job_progress(progress)["target_percent"]==100
        @test L.job_progress(progress)["accepted_percent"]≈20.31
        before=copy(progress.progress)
        L.append_job_lines!(progress,[native("1e999",1),"unrelated progress 100%"])
        @test progress.progress==before
        @test occursin("Applied-load target 100.0%",read(progress.logpath,String))
        L.finish_jfem_process!(progress,2)
        @test L.job_progress(progress)["phase"]=="failed"
        @test L.job_progress(progress)["accepted_percent"]≈20.31

        # Ordinary analyses report observed stages, not invented load fractions.
        m.params["output.solution"]="101"
        linear=job("linear_stages")
        for (line,stage) in (
            (">>> Reading BDF file: fixture.bdf","deck"),
            ("[SOLVER] Computing Element Stiffness (1 threads)...","assembly"),
            ("[SOLVER] Using Direct Solver (Cholesky) for 42 DOFs...","linear_solve"),
            ("[SOLVER] Post-Processing...","recovery"),
            (">>> Exporting AGGREGATED JSON: result.json","export"))
            L.append_job_lines!(linear,[line]);q=L.job_progress(linear)
            @test q["stage"]==stage
            @test q["stage_seconds"]>=0
            @test q["target_percent"]===nothing
            @test !haskey(q,"stage_started")
        end
        @test Set(keys(L.job_progress(linear)["stage_timings_seconds"]))==Set(["deck","assembly","linear_solve","recovery"])
        L.finish_jfem_process!(linear,2)
        @test L.job_progress(linear)["phase"]=="failed"
        @test !L.job_timings(linear)["available"]
        timed=job("timed");timed.started=100.;timed.finished=160.;timed.state=:done
        timing=Dict("schema_version"=>1,"solution_seconds"=>7.,"compilation_seconds"=>30.,
            "measured_wall_seconds"=>50.,"phases"=>Dict(
                "parse"=>Dict("execution_seconds"=>4.),"build_model"=>Dict("execution_seconds"=>3.),
                "solve"=>Dict("execution_seconds"=>7.),"export"=>Dict("execution_seconds"=>5.),
                "report"=>Dict("execution_seconds"=>1.)))
        L.append_job_lines!(timed,["[JFEM_TIMINGS] "*L.JSON.json(timing)])
        tt=L.job_timings(timed)
        @test tt["available"]&&tt["solution_seconds"]==7
        @test tt["compilation_seconds"]==30
        @test tt["preparation_seconds"]==7
        @test tt["export_seconds"]==6
        @test tt["startup_overhead_seconds"]==10
        @test tt["total_seconds"]==60
        L.append_job_lines!(timed,["[JFEM_TIMINGS] not JSON"])
        @test L.job_timings(timed)==tt
        timed_parent=job("timed_parent");timed_parent.started=90.;timed_parent.finished=220.
        timed_parent.runs=[timed,linear]
        @test !L.job_timings(timed_parent)["available"]
        @test L.job_timings(timed_parent)["measured_runs"]==1
        L.append_job_lines!(linear,["[JFEM_TIMINGS] "*L.JSON.json(timing)])
        @test L.job_timings(timed_parent)["solution_seconds"]==14
        @test L.job_timings(timed_parent)["startup_overhead_seconds"]==30
        @test tt["adjoint_seconds"]==0
        overlap=L.JSON.parse(L.JSON.json(timing))
        overlap["phases"]["parse"]["execution_seconds"]=nothing
        overlap["phases"]["adjoint"]=Dict("execution_seconds"=>2.)
        measured=job("overlapping_compilation")
        L.append_job_lines!(measured,["[JFEM_TIMINGS] "*L.JSON.json(overlap)])
        separated=L.job_timings(measured)
        @test separated["available"] && separated["solution_seconds"]==7
        @test separated["preparation_seconds"]===nothing
        @test separated["export_seconds"]==6
        @test separated["adjoint_seconds"]==2
        m.params["output.solution"]="106"

        app=normpath(joinpath(@__DIR__,".."));input=joinpath(dir,"input.toml")
        write(input,L.params_to_toml(p))
        st=L.AppState(app,input;deck_store_dir=joinpath(dir,"decks"));st.jobs[live.id]=live
        st.jobs[parent.id]=parent
        status=L.handle_jfem_status(st,L.HTTP.Request("GET","/api/jfem_status?job=live&from=0"))
        @test ncodeunits(String(status.body))<80000
        doc=L.JSON.parse(String(status.body))
        @test doc["omitted_lines"]>0 && doc["has_more"]
        @test doc["next_line"]<doc["total_lines"]
        @test haskey(doc["progress"],"target_percent")
        response=L.handle_jfem_log(st,L.HTTP.Request("GET","/api/jfem_log?job=parent&run=child"))
        @test response.status==200 && response.body isa L.HTTP.CallbackBody
        # Snapshot length remains fixed even if the solver appends while downloaded.
        open(io->write(io,"new line after response\n"),child.logpath,"a")
        received=IOBuffer();buf=Vector{UInt8}(undef,4096)
        try
            while true
                n=L.HTTP.body_read!(response.body,buf)
                n==0 && break
                write(received,view(buf,1:n))
            end
        finally
            L.HTTP.body_close!(response.body)
        end
        @test String(take!(received))==original
        @test L.HTTP.body_closed(response.body)
        @test L.handle_jfem_log(st,L.HTTP.Request("GET","/api/jfem_log?job=parent&run=../other")).status==400
        @test L.handle_jfem_log(st,L.HTTP.Request("GET","/api/jfem_log?job=missing")).status==400
    end
end
