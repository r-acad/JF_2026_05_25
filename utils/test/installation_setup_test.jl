using Test,TOML
include(joinpath(@__DIR__,"..", "..","utils","julia_tools","install_julia_packages.jl"))
const InstallationSetup=JFEMPackageSetup
const InstallationEnvironment=InstallationSetup.JFEMEnvironmentSetup
@testset "Project-driven combined installation" begin
    options=InstallationSetup.parse_options(String[])
    @test options[:selection]==:all && options[:precompile] && options[:verify]
    @test InstallationSetup.parse_options(["--no-precompile","--no-verify"])[:verify]==false
    @test InstallationSetup.parse_options(["--offline"])[:offline]
    @test InstallationSetup.parse_options(["--help"])===nothing
    @test_throws ErrorException InstallationSetup.parse_options(["--solver-only","--wingfegen-only"])
    @test_throws ErrorException InstallationSetup.parse_options(["--wingfegen-project="])
    @test_throws ErrorException InstallationSetup.parse_options(["--unknown"])
    mktempdir() do root
        mkpath(joinpath(root,"APPS","JFEM-Boxer"))
        for project in (root,joinpath(root,"APPS","JFEM-Boxer"))
            write(joinpath(project,"Project.toml"),"[deps]\n")
            write(joinpath(project,"Manifest.toml"),"julia_version = \"$(VERSION)\"\n")
        end
        @test first.(InstallationSetup.setup_projects(root,options))==["JFEM"]
        @test first.(InstallationSetup.setup_projects(root,InstallationSetup.parse_options(["--solver-only"])))==["JFEM"]
        @test first.(InstallationSetup.setup_projects(root,InstallationSetup.parse_options(["--wingfegen-only"])))==["JFEM"]
        @test InstallationEnvironment.check_runtime(root;version=VersionNumber(VERSION.major,VERSION.minor,VERSION.patch+1))===nothing
        @test_throws ErrorException InstallationEnvironment.check_runtime(root;version=v"1.0.0")
        @test InstallationEnvironment.missing_sources(Dict(1=>(source=root,name="installed"),2=>(source=joinpath(root,"missing"),name="missing")))==["missing"]
        @test "--project="*root in InstallationSetup.verification_command("JFEM",root).exec
        @test occursin("using WingFEGen",string(InstallationSetup.verification_command("FGen",root)))
        @test !occursin("using OpenJFEM",string(InstallationSetup.verification_command("FGen",root)))
    end
    @test isfile(joinpath(InstallationSetup.repo_root(),"setup.cmd"))
    @test isfile(joinpath(InstallationSetup.repo_root(),"setup.sh"))
    @test isfile(joinpath(InstallationSetup.repo_root(),"setup.command"))
end

@testset "Unified application setup and automatic image contract" begin
    @test InstallationSetup.parse_options(String[])[:sysimage]==""
    @test InstallationSetup.parse_options(String[])[:sysimage_threads]=="2"
    @test InstallationSetup.parse_options(["--no-sysimage"])[:sysimage]===nothing
    @test InstallationSetup.parse_options(["--sysimage"])[:sysimage]==""
    @test InstallationSetup.parse_options(["--sysimage","--no-precompile","--no-verify"])[:sysimage]==""
    @test_throws ErrorException InstallationSetup.parse_options(["--sysimage="])
    @test InstallationSetup.parse_options(["--sysimage","--wingfegen-only"])[:selection]==:wingfegen
    @test InstallationSetup.parse_options(["--sysimage-threads=2"])[:sysimage_threads]=="2"
    @test_throws ErrorException InstallationSetup.parse_options(["--sysimage","--sysimage-threads=0"])
    @test_throws ErrorException InstallationSetup.parse_options(["--sysimage","--sysimage-threads=two"])
    @test_throws ErrorException InstallationSetup.parse_options(["--sysimage","--deck"])
    @test_throws ErrorException InstallationSetup.parse_options(["--no-sysimage","--flags","A=1"])
    repo=InstallationSetup.repo_root()
    @test InstallationSetup.verify_viewer_assets(repo)
    @test occursin("/health",string(InstallationSetup.verification_command("PANDEATOR",repo)))
    @test occursin("/jfem_graphics.js",string(InstallationSetup.verification_command("PANDEATOR",repo)))
    @test occursin("/vendor/twgsl/twgsl.wasm",string(InstallationSetup.verification_command("PANDEATOR",repo)))
    @test_throws ErrorException InstallationSetup.verification_command("unknown",repo)
    viewer=read(joinpath(repo,"APPS","JFEM_results_viewer","postv11.html"),String)
    scripts=[m[1] for m in eachmatch(r"<script\s+src=\"([^\"]+)\"",viewer)]
    @test !isempty(scripts) && all(src->!occursin("://",src),scripts)
    @test all(src->isfile(joinpath(repo,"APPS","JFEM_results_viewer",src)),scripts)
    mktempdir() do root
        @test_throws ErrorException InstallationSetup.verify_viewer_assets(root)
        deck=joinpath(root,"model with spaces.bdf");write(deck,"SOL 101\n")
        manifest=joinpath(root,"cases.json");write(manifest,"{\"cases\":[]}")
        image=joinpath(root,"custom image."*InstallationSetup.Libdl.dlext)
        options=InstallationSetup.parse_options(["--solver-only","--sysimage="*image,"--sysimage-threads=2",
            "--deck",deck,"--manifest="*manifest,"--flags","JFEM_EXPORT_BINARY=false","--offline"])
        command=InstallationSetup.sysimage_command(root,options)
        @test "--threads=2" in command.exec
        @test "--sysimage="*image in command.exec
        @test deck in command.exec && manifest in command.exec
        @test "JULIA_PKG_OFFLINE=true" in command.env
        @test "JFEM_PRECOMPILE_BOXER=1" in command.env
        @test any(startswith("JULIA_NUM_PRECOMPILE_TASKS="),command.env)
        @test any(startswith("JULIA_IMAGE_THREADS="),command.env)
        @test !any(arg->occursin("install-packagecompiler",arg),command.exec)
        @test_throws ErrorException InstallationSetup.parse_options(["--sysimage","--deck="*joinpath(root,"absent.bdf")])

        # A successful child exit is insufficient: reject absent or stale receipts.
        @test_throws ErrorException InstallationSetup.build_sysimage(root,options;runner=cmd->nothing)
        @test_throws ErrorException InstallationSetup.build_sysimage(root,options;runner=cmd->error("build failed"))
        mkpath(joinpath(root,"src"));write(joinpath(root,"src","tiny.jl"),"# test source\n")
        write(joinpath(root,"Project.toml"),"[deps]\n")
        provenance=InstallationSetup.JFEMSysimageProvenance
        function receipt_runner(cmd)
            inputs=provenance.input_hashes(root)
            workload=provenance.workload_hashes([deck],"test")
            # Receipt unit fixture only: never load these bytes as a Julia image.
            write(image,"receipt fixture, not a loadable image")
            provenance.write_sidecar(root,image,inputs,workload)
        end
        @test InstallationSetup.build_sysimage(root,options;runner=receipt_runner)==image
        reuse=InstallationSetup.parse_options(["--solver-only","--sysimage="*image])
        @test InstallationSetup.build_sysimage(root,reuse;runner=cmd->error("current image must be reused"))==image
        write(joinpath(root,"src","tiny.jl"),"# modified\n")
        @test_throws ErrorException InstallationSetup.build_sysimage(root,options;runner=cmd->nothing)
    end
end

@testset "Offline browser distribution checks" begin
    @test InstallationSetup.parse_options(["--boxer-only"])[:selection]==:wingfegen
    mktempdir() do root
        boxer=joinpath(root,"APPS","JFEM-Boxer","web")
        panel=joinpath(root,"APPS","PANDEATOR_APP")
        viewer=joinpath(root,"APPS","JFEM_results_viewer")
        mkpath(boxer);mkpath(panel);mkpath(viewer)
        for (base,entry) in ((boxer,"index.html"),(panel,"panel_app.html"))
            mkpath(joinpath(base,"vendor"))
            write(joinpath(base,"vendor","babylon.js"),"/* pinned fixture */")
            digest=bytes2hex(InstallationSetup.sha256(read(joinpath(base,"vendor","babylon.js"))))
            write(joinpath(base,"vendor","provenance.json"),"""{"dependencies":[{"filename":"babylon.js","local_sha256":"$digest"}]}""")
            write(joinpath(base,entry),"<script defer src='vendor/babylon.js'></script><link rel='stylesheet' href='style.css'>")
            write(joinpath(base,"style.css"),"body{}")
        end
        write(joinpath(viewer,"postv11.html"),"<script src=\"../PANDEATOR_APP/vendor/babylon.js\"></script><script src='../jfem_binary.js'></script>")
        write(joinpath(root,"APPS","jfem_binary.js"),"/* reader */")
        write(joinpath(root,"APPS","jfem_graphics.js"),"/* graphics */")
        write(joinpath(boxer,"panel_table.html"),"<script src='table.js?v=1'></script>")
        write(joinpath(boxer,"table.js"),"/* popup */")
        open(joinpath(boxer,"index.html"),"a") do io
            write(io,"<script src='shared/jfem_graphics.js'></script>")
        end
        @test InstallationSetup.verify_browser_asset_files(root)
        @test InstallationSetup.verify_viewer_assets(root)
        @test InstallationSetup.verify_viewer_assets(root;selection=:wingfegen)
        rm(joinpath(root,"APPS","jfem_graphics.js"))
        @test_throws ErrorException InstallationSetup.verify_browser_asset_files(root;selection=:wingfegen)
        write(joinpath(root,"APPS","jfem_graphics.js"),"/* graphics */")
        rm(joinpath(boxer,"table.js"))
        @test_throws ErrorException InstallationSetup.verify_browser_asset_files(root;selection=:wingfegen)
        write(joinpath(boxer,"table.js"),"/* popup */")
        write(joinpath(boxer,"vendor","babylon.js"),"/* changed bytes! */")
        @test InstallationSetup.verify_browser_asset_files(root;selection=:wingfegen)
        @test_throws ErrorException InstallationSetup.verify_viewer_assets(root;selection=:wingfegen)
        write(joinpath(boxer,"vendor","babylon.js"),"/* pinned fixture */")
        write(joinpath(boxer,"panel_table.html"),"<script src='https://cdn.example.invalid/library.js'></script>")
        @test_throws ErrorException InstallationSetup.verify_browser_asset_files(root;selection=:wingfegen)
        write(joinpath(boxer,"panel_table.html"),"<script src='//cdn.example.invalid/library.js'></script>")
        @test_throws ErrorException InstallationSetup.verify_browser_asset_files(root;selection=:wingfegen)
        write(joinpath(boxer,"panel_table.html"),"<script src='table.js'></script>")
        rm(joinpath(panel,"vendor","babylon.js"))
        @test InstallationSetup.verify_viewer_assets(root;selection=:wingfegen)
        @test_throws ErrorException InstallationSetup.verify_viewer_assets(root)
        @test_throws ErrorException InstallationSetup.verify_viewer_assets(root;selection=:unknown)
        @test_throws ErrorException InstallationSetup.browser_asset_path(root,boxer,"../../../../../outside.js")
    end
end

module InstallationPanelPaths
include(joinpath(@__DIR__,"..", "..","APPS","PANDEATOR_APP","panel_artifacts.jl"))
end
@testset "Portable PANDEATOR output root" begin
    root=InstallationSetup.repo_root()
    @test InstallationPanelPaths._panel_default_run_root(joinpath(root,"APPS","PANDEATOR_APP"))==joinpath(root,"output","panel_runs")
    mktempdir() do root
        @test InstallationPanelPaths._panel_default_run_root(joinpath(root,"APPS","PANDEATOR_APP"))==joinpath(root,"output","panel_runs")
    end
end
