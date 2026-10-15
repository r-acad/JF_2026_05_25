#!/usr/bin/env julia
# A bare Julia process checks provenance before starting the chosen application.
include("runtime_images.jl")
length(ARGS)>=3||error("usage: launch.jl solver|boxer ROOT ENTRY [arguments...]")
kind,root,entry=ARGS[1:3]
image,reason=JFEMRuntimeImages.selected_image(abspath(root);kind)
if image===nothing
    reason in ("image_missing","disabled")||println(stderr,"JFEM: local image skipped ($reason); run setup to refresh it.")
else
    println("JFEM: using verified ",kind," sysimage.")
end
project=root
command=Cmd(vcat([JFEMRuntimeImages.bare_julia()],JFEMRuntimeImages.image_arguments(image),
    ["--startup-file=no","--threads=auto","--project="*abspath(project),abspath(entry)],ARGS[4:end]))
exit(run(ignorestatus(command)).exitcode)
