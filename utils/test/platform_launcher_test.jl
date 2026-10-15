using Test

@testset "OS launcher forwarding preserves paths, arguments and exit status" begin
    repo=normpath(joinpath(@__DIR__,"..", ".."))
    names=("setup","JFEM-Boxer","PANDEATOR","Results-viewer","JFEM-solver")
    shell=get(ENV,"JFEM_TEST_BASH",Sys.iswindows() ? "" : something(Sys.which("bash"),""))
    mktempdir() do temp
        root=joinpath(temp,"Checkout with spaces ! (fixture)");mkpath(root)
        argument="model with spaces !.bdf"
        for system in ("Windows","Linux","Mac")
            suffix=system=="Windows" ? ".cmd" : system=="Mac" ? ".command" : ".sh"
            folder=joinpath(root,"__Start here!__",system);mkpath(folder)
            for name in names
                source=joinpath(repo,"__Start here!__",system,name*suffix)
                @test isfile(source)
                script=joinpath(folder,name*suffix);cp(source,script)
                if system=="Windows" && Sys.iswindows()
                    # Parent/root target is a test double, so no installation/app runs.
                    write(joinpath(root,name*".cmd"),"@echo off\nsetlocal DisableDelayedExpansion\necho TARGET:$name\necho ARG:%~1\nexit /b 7\n")
                    body="\"\""*script*"\" \""*argument*"\"\""
                    command=Cmd(Cmd(["cmd.exe","/d","/v:off","/s","/c",body]);windows_verbatim=true)
                    io=IOBuffer()
                    result=run(pipeline(ignorestatus(addenv(command,"OPENJFEM_NO_PAUSE"=>"1"));stdout=io,stderr=io))
                    output=String(take!(io))
                    @test result.exitcode==7
                    @test occursin("TARGET:"*name,output)
                    @test occursin("ARG:"*argument,output)
                elseif system!="Windows" && !isempty(shell)
                    write(joinpath(root,name*".sh"),"#!/usr/bin/env bash\nprintf '%s\\n' 'TARGET:$name' \"ARG:\$1\"\nexit 7\n")
                    io=IOBuffer()
                    command=Cmd([shell,replace(script,'\\'=>'/'),argument])
                    result=run(pipeline(ignorestatus(addenv(command,"OPENJFEM_NO_PAUSE"=>"1"));stdout=io,stderr=io))
                    output=String(take!(io))
                    @test result.exitcode==7
                    @test occursin("TARGET:"*name,output)
                    @test occursin("ARG:"*argument,output)
                end
            end
        end
        if !isempty(shell)
            # The root Finder shortcut follows the same shared-root shell entry.
            script=joinpath(root,"JFEM-Boxer.command")
            cp(joinpath(repo,"JFEM-Boxer.command"),script)
            io=IOBuffer()
            result=run(pipeline(ignorestatus(Cmd([shell,replace(script,'\\'=>'/'),argument]));stdout=io,stderr=io))
            @test result.exitcode==7
            @test occursin("TARGET:JFEM-Boxer",String(take!(io)))
        end
    end
end
