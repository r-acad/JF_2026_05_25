using Test, TOML, JSON
isempty(ARGS) || length(ARGS) == 2 || error("Usage: julia --project=. test/le_skin_resolution_test.jl [fixture-directory evidence-directory]")
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen
point(m,n)=Tuple(m.xyz[3n-2:3n])
groups(m,name)=filter(gr->startswith(gr.name,name),m.groups)
elements(m,name)=sum(W.n_elements,groups(m,name);init=0)
function shell_edges(m,name)
    result=Set{Tuple{Int,Int}}()
    for group in groups(m,name)
        width=group.kind==:quad ? 4 : group.kind==:tria ? 3 : 0
        width>0||continue
        for e in 1:W.n_elements(group)
            nodes=group.conn[width*(e-1)+1:width*e]
            for i in 1:width;push!(result,minmax(nodes[i],nodes[mod1(i+1,width)]));end
        end
    end
    result
end

base=merge(W.default_params(),Dict{String,Any}("planform.area"=>4.,"planform.aspect_ratio"=>4.,
    "planform.sweep"=>12.,"planform.twist_tip"=>7.,"box.rib_pitch"=>.4,"box.stringer_pitch"=>.12,
    "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>2,"mesh.aero_chord_points"=>21,
    "leading_edge.enabled"=>true,"loads.cases"=>Any[]))
scenarios=["flight_ribs"=>base,"angled_ribs_with_gap"=>merge(base,Dict{String,Any}(
    "ribs.masters"=>[Dict("eta"=>.45,"mode"=>"rear_spar_angle","angle"=>95.,"pitch"=>.35)],
    "leading_edge.start_rib"=>2,"leading_edge.disabled_bays"=>"3",
    "leading_edge.rib_orientation"=>"front_spar_angle","leading_edge.rib_angle"=>100.))]
report=Dict{String,Any}()
suite=@testset "Independent leading-edge skin resolution and parameter help" begin
    @testset "Helpful schema, existing key and compatible persistence" begin
        @test all(!isempty(strip(spec.help)) for spec in W.SCHEMA)
        @test all(lowercase(strip(spec.help))!=lowercase(strip(spec.label)) for spec in W.SCHEMA)
        spec=W.SCHEMA_BY_KEY["leading_edge.chord_elements"]
        @test spec.group=="Mesh" && spec.default==8 && spec.kind===:int
        @test occursin("EACH leading-edge skin",spec.help)
        @test occursin("does not refine structural skins or change VLM loads",W.SCHEMA_BY_KEY["mesh.aero_chord_points"].help)
        for invalid in (0,1,101,2.5,true,NaN,Inf,"3.5","",nothing)
            @test_throws ArgumentError W.normalize_params(merge(base,Dict("leading_edge.chord_elements"=>invalid)))
        end
        for invalid in (1,101,2.5,true)
            @test_throws ArgumentError W.build_model(merge(base,Dict("leading_edge.chord_elements"=>invalid)))
        end
        for count in (2,8,13,100)
            p=merge(base,Dict("leading_edge.chord_elements"=>count))
            @test first(W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(p)))))["leading_edge.chord_elements"]===count
        end
        legacy=copy(base);delete!(legacy,"leading_edge.chord_elements")
        restored=first(W.normalize_params(legacy))
        @test restored["leading_edge.chord_elements"]===8
        original,loaded=W.build_model(copy(base)),W.build_model(restored)
        @test original.xyz==loaded.xyz && original.node_keys==loaded.node_keys
        @test [(g.eids,g.conn) for g in original.groups]==[(g.eids,g.conn) for g in loaded.groups]
        disabled=W.build_model(merge(base,Dict("leading_edge.enabled"=>false,"leading_edge.chord_elements"=>13)))
        @test all(!startswith(g.name,"LE_") for g in disabled.groups)
        @test disabled.params["leading_edge.chord_elements"]==13
    end
    for (name,definition) in scenarios, height in (1,4)
        @testset "$name, height $height" begin
            p=merge(definition,Dict("mesh.elements_spar_height"=>height))
            core=W.build_model(merge(p,Dict("leading_edge.enabled"=>false)))
            baseline=W.build_model(merge(p,Dict("leading_edge.chord_elements"=>8)))
            for count in (2,8,13)
                @testset "$count skin elements per interval" begin
                    trial=merge(p,Dict("leading_edge.chord_elements"=>count));m=W.build_model(trial);g=m.grid
                    layout=W.leading_edge_layout(trial,length(g.ribs))
                    intervals=sum(g.ribs[bay+1]-g.ribs[bay] for bay in layout.active_bays)
                    @test W.all_checks_pass(m)
                    @test elements(m,"LE_UPPER_SKIN")==count*intervals
                    @test elements(m,"LE_LOWER_SKIN")==count*intervals
                    @test elements(m,"LE_RIB_WEBS")==height*(count-1)*length(layout.active_ribs)
                    @test elements(m,"LE_RIB_NOSE")==height*length(layout.active_ribs)
                    @test g.nh==height && g.ribs==baseline.grid.ribs && g.etas==baseline.grid.etas
                    @test m.xyz[1:3core.n_struct]==core.xyz[1:3core.n_struct]
                    @test [(gr.name,gr.eids,gr.conn) for gr in m.groups if !startswith(gr.name,"LE_")]==[(gr.name,gr.eids,gr.conn) for gr in core.groups]
                    @test m.spc==core.spc && m.aero_xyz==baseline.aero_xyz && m.aero_quads==baseline.aero_quads
                    @test W.vlm_grid(m.wing,4,6)==W.vlm_grid(core.wing,4,6)
                    lookup=Dict(key=>n for (n,key) in enumerate(m.node_keys))
                    front=shell_edges(m,"FRONT_SPAR_WEB");le=shell_edges(m,"LE_RIB_WEBS")
                    for rib in layout.active_ribs,k in 0:height-1
                        j=g.ribs[rib];edge=minmax(lookup[(0,j,k)],lookup[(0,j,k+1)])
                        @test edge in front && edge in le
                    end
                    for (surface,k) in (("LE_LOWER_SKIN",0),("LE_UPPER_SKIN",height))
                        skins=shell_edges(m,surface)
                        for bay in layout.active_bays,j in g.ribs[bay]:g.ribs[bay+1]-1
                            edge=minmax(lookup[(0,j,k)],lookup[(0,j+1,k)])
                            @test edge in front && edge in skins
                        end
                    end
                    report["$(name)_h$(height)_c$(count)"]=Dict("skin_elements_per_interval"=>count,
                        "vertical_elements"=>height,"span_intervals"=>intervals,"upper_skin_elements"=>elements(m,"LE_UPPER_SKIN"),
                        "lower_skin_elements"=>elements(m,"LE_LOWER_SKIN"),"checks_pass"=>true)
                    if length(ARGS)==2 && height==4 && count==13
                        mkpath(ARGS[1]);write(joinpath(ARGS[1],"le_skin_$name.toml"),W.params_to_toml(trial))
                    end
                end
            end
        end
    end
    @testset "Wetted loft sampling is independent of FE and VLM resolution" begin
        original=W.build_model(copy(base))
        for samples in (7,41,65)
            sampled=W.build_model(merge(base,Dict("mesh.aero_chord_points"=>samples)))
            @test sampled.aero_nloop==2*(samples-1)
            @test sampled.xyz==original.xyz && sampled.node_keys==original.node_keys
            @test [(gr.eids,gr.conn) for gr in sampled.groups]==[(gr.eids,gr.conn) for gr in original.groups]
            @test W.vlm_grid(sampled.wing,4,6)==W.vlm_grid(original.wing,4,6)
        end
    end
end
if length(ARGS)==2
    mkpath(ARGS[2]);counts=Test.get_test_counts(suite)
    write(joinpath(ARGS[2],"le_skin_resolution_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"cases"=>report),2))
    write(joinpath(ARGS[2],"schema.json"),JSON.json(W.schema_payload(W.default_params(),""),2))
end
