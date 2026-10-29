# Generate the warm-sizing demonstration using the production Boxer geometry,
# mesh, loads and deck writer. No UI or reference solver is started.
using JSON, TOML
length(ARGS)==2 || error("usage: generate_wingbox.jl CONFIG.toml OUTPUT_DIRECTORY")
using WingFEGen
config=abspath(ARGS[1]); destination=abspath(ARGS[2])
isdir(destination) && !isempty(readdir(destination)) && error("Output directory must be new or empty")
mkpath(destination)
params=merge(WingFEGen.default_params(),WingFEGen.flatten_toml(TOML.parsefile(config)))
model=WingFEGen.build_model(params)
WingFEGen.all_checks_pass(model) || error("Boxer model checks failed")
deck=joinpath(destination,"wingbox.bdf")
WingFEGen.write_reference(model,deck)
write(joinpath(destination,"boxer_input.toml"),WingFEGen.params_to_toml(params))
write(joinpath(destination,"generation.json"),JSON.json(Dict(
    "generator"=>"WingFEGen.build_model + write_reference", "input"=>config,
    "deck"=>deck, "nodes"=>length(model.node_ids), "checks_passed"=>true)))
println(deck)
