using Test

@testset "Startup helper terminates on stdin EOF" begin
    script=joinpath(@__DIR__,"..","src","startup_progress.jl")
    for with_stage in (false,true)
        input=Pipe();output=IOBuffer()
        command=`$(Base.julia_cmd()) --startup-file=no --history-file=no $script`
        process=run(pipeline(ignorestatus(command),stdin=input,stdout=output,stderr=output);wait=false)
        close(input.out)
        try
            if with_stage
                for stage in ("Loading package HTTP", "Loaded HTTP v1.0 in 0.1 s", "Starting the local HTTP listener")
                    println(input,stage)
                end
                flush(input)
                sleep(.2)
            end
            close(input.in)
            finished=timedwait(()->process_exited(process),15.;pollint=.05)
            @test finished==:ok
            # Only this test's own helper is stopped if its EOF lifecycle fails.
            finished==:ok || kill(process)
            wait(process)
            @test success(process)
            log=String(take!(output))
            @test !occursin("ERROR",log)
            if with_stage
                # Fast stage changes must not be overwritten by the heartbeat.
                entries=("Loading package HTTP", "Loaded HTTP v1.0 in 0.1 s", "Starting the local HTTP listener")
                @test all(entry->occursin(entry,log),entries)
                @test issorted([first(findfirst(entry,log)) for entry in entries])
            end
        finally
            isopen(input.in) && close(input.in)
            process_running(process) && (kill(process);wait(process))
        end
    end
end
