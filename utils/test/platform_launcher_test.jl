using Test

@testset "Application launchers preserve checkout paths, arguments and exits" begin
    repo=normpath(joinpath(@__DIR__,"..",".."))
    apps=Dict("JFEM-Boxer"=>"JFEM-Boxer","PANDEATOR"=>"PANDEATOR_APP",
              "Results-viewer"=>"JFEM_results_viewer","JFEM-solver"=>"JFEM-solver")
    shell=get(ENV,"JFEM_TEST_BASH",Sys.iswindows() ? "" : something(Sys.which("bash"),""))
    julia=joinpath(Sys.BINDIR,Sys.iswindows() ? "julia.exe" : "julia")
    @test sort(filter(name->any(ext->endswith(name,ext),(".cmd",".sh",".command")),readdir(repo))) == ["setup.cmd","setup.command","setup.sh"]
    @test !isfile(joinpath(repo,"jfem"))
    mktempdir() do temp
        root=joinpath(temp,"Checkout with spaces ! (fixture)");mkpath(root)
        away=joinpath(temp,"unrelated working directory");mkpath(away)
        for name in ("setup.cmd","setup.sh","setup.command")
            cp(joinpath(repo,name),joinpath(root,name))
        end
        # Copy only entry scripts and the real image-aware launcher, never the
        # applications. Tiny Julia targets stop before any installation or solve.
        for app in values(apps), system in ("Windows","Linux","Mac")
            source=joinpath(repo,"APPS",app,system)
            @test isdir(source)
            destination=joinpath(root,"APPS",app,system);mkpath(destination)
            for name in readdir(source)
                isfile(joinpath(source,name)) && cp(joinpath(source,name),joinpath(destination,name))
            end
        end
        for system in ("Windows","Linux","Mac")
            destination=joinpath(root,"__Start here!__",system);mkpath(destination)
            for name in readdir(joinpath(repo,"__Start here!__",system))
                any(ext->endswith(name,ext),(".cmd",".sh",".command")) || continue
                cp(joinpath(repo,"__Start here!__",system,name),joinpath(destination,name))
            end
        end
        target=joinpath(root,"utils","julia_tools");mkpath(target)
        for name in ("runtime_images.jl","sysimage_provenance.jl","launch.jl")
            cp(joinpath(repo,"utils","julia_tools",name),joinpath(target,name))
        end
        write(joinpath(root,"Project.toml"),"[deps]\n")
        function capture(path,name;check_project=true)
            mkpath(dirname(path))
            write(path,"println(\"TARGET:$name\"); println(\"ARGS:\",join(ARGS,\"|\")); "*
                  (check_project ? "println(\"PROJECT:\",normpath(Base.active_project())); " : "")*"exit(7)\n")
        end
        capture(joinpath(target,"install_julia_packages.jl"),"setup")
        capture(joinpath(target,"jfem.jl"),"JFEM-solver")
        capture(joinpath(target,"serve_results_viewer.jl"),"Results-viewer")
        capture(joinpath(root,"APPS","JFEM-Boxer","JFEM-Boxer.jl"),"JFEM-Boxer")
        capture(joinpath(root,"APPS","PANDEATOR_APP","panel_launch.jl"),"PANDEATOR")
        arguments=["model with spaces !.bdf","output with spaces !","--fixture=value"]
        function exercise(script,system,target;check_project=true)
            if system=="Windows"
                Sys.iswindows() || return
                body="\"\""*script*"\" "*join(["\""*a*"\"" for a in arguments]," ")*"\""
                command=Cmd(Cmd(["cmd.exe","/d","/v:off","/s","/c",body]);windows_verbatim=true,dir=away)
            else
                isempty(shell) && return
                command=Cmd(Cmd([shell,replace(script,'\\'=>'/'),arguments...]);dir=away)
            end
            executable=system=="Windows" ? julia : replace(julia,'\\'=>'/')
            io=IOBuffer()
            result=run(pipeline(ignorestatus(addenv(command,"JFEM_JULIA"=>executable,
                "WINGFEGEN_JULIA"=>executable,"OPENJFEM_NO_PAUSE"=>"1","JFEM_NO_SYSIMAGE"=>"1"));stdout=io,stderr=io))
            output=String(take!(io))
            @test result.exitcode==7
            @test occursin("TARGET:"*target,output)
            @test occursin("ARGS:"*join(arguments,"|"),output)
            if check_project
                @test occursin("PROJECT:"*normpath(joinpath(root,"Project.toml")),output)
            end
        end
        for system in ("Windows","Linux","Mac")
            suffix=system=="Windows" ? ".cmd" : system=="Mac" ? ".command" : ".sh"
            for (name,app) in apps
                exercise(joinpath(root,"APPS",app,system,name*suffix),system,name)
                exercise(joinpath(root,"__Start here!__",system,name*suffix),system,name)
            end
            exercise(joinpath(root,"setup"*suffix),system,"setup")
            cli=system=="Windows" ? "jfem.cmd" : "jfem"
            exercise(joinpath(root,"APPS","JFEM-solver",system,cli),system,"JFEM-solver")
        end
    end
end
