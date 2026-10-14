using Test, JSON
include(joinpath(@__DIR__,"..","src","sensitivity_io.jl"))
const IOFiles=SensitivityFileIO

function hold_without_delete_share(path)
    wide=transcode(UInt16,abspath(path)*'\0')
    handle=ccall((:CreateFileW,"kernel32"),Ptr{Cvoid},
        (Ptr{UInt16},UInt32,UInt32,Ptr{Cvoid},UInt32,UInt32,Ptr{Cvoid}),
        wide,0x80000000,0x00000001,C_NULL,3,0x80,C_NULL)
    handle==Ptr{Cvoid}(typemax(UInt))&&error("Could not create owned Windows reader lock")
    handle
end
release(handle)=ccall((:CloseHandle,"kernel32"),Int32,(Ptr{Cvoid},),handle)

@testset "Sensitivity atomic publication and Windows sharing" begin
    mktempdir() do dir
        path=joinpath(dir,"progress.json")
        @test IOFiles.write_text(path,"{\"sequence\":0}")
        @test JSON.parsefile(path)["sequence"]==0
        @test_throws ErrorException IOFiles.write_text(path,"{}";progress=true,
            replace=(args...)->error("critical disk failure"))
        @test readdir(dir)==["progress.json"]
        @test_throws IOFiles.SharingViolation IOFiles.write_text(path,"{}";attempts=2,
            replace=(args...)->throw(IOFiles.SharingViolation(path,UInt32(32))),delay=(_)->nothing)
        @test readdir(dir)==["progress.json"]
        if Sys.iswindows()
            # Reproduce the actual reader sharing violation with an OS handle,
            # not an injected exception. The legacy mv(force=true) unlinks first.
            handle=hold_without_delete_share(path)
            try
                legacy=joinpath(dir,"legacy.tmp");write(legacy,"{}")
                failure=try mv(legacy,path;force=true);nothing catch error;error end
                @test failure isa Base.IOError
                @test occursin("busy",lowercase(sprint(showerror,failure))) || occursin("permission",lowercase(sprint(showerror,failure)))
                isfile(legacy)&&rm(legacy)
                started=time()
                @test !IOFiles.write_text(path,"{\"sequence\":1}";progress=true)
                @test time()-started<2
                @test JSON.parsefile(path)["sequence"]==0
                @test readdir(dir)==["progress.json"]
            finally
                release(handle)
            end
            @test IOFiles.write_text(path,"{\"sequence\":2}";progress=true)
            @test JSON.parsefile(path)["sequence"]==2
            handle=hold_without_delete_share(path)
            unlock=@async begin sleep(.08);release(handle) end
            try
                @test IOFiles.write_text(path,"{\"sequence\":3}";progress=true)
            finally
                wait(unlock)
            end
            @test JSON.parsefile(path)["sequence"]==3
            chmod(path,0o444)
            try
                @test_throws ErrorException IOFiles.write_text(path,"{}";progress=true)
            finally
                chmod(path,0o666)
            end
        end
        failures=Any[];seen=Int[];done=Threads.Atomic{Bool}(false);ready=Channel{Nothing}(1)
        reader=Threads.@spawn begin
            put!(ready,nothing)
            while !done[]
                try push!(seen,JSON.parse(IOFiles.read_text(path))["sequence"]) catch error;push!(failures,error) end
                yield()
            end
        end
        take!(ready)
        try
            for sequence in 4:200
                @test IOFiles.write_text(path,JSON.json(Dict("sequence"=>sequence,"payload"=>fill(sequence,128)));progress=true)
                yield()
            end
        finally
            done[]=true;wait(reader)
        end
        @test isempty(failures)
        @test !isempty(seen)
        @test issorted(seen)
        @test JSON.parsefile(path)["sequence"]==200
        @test readdir(dir)==["progress.json"]
    end
end
