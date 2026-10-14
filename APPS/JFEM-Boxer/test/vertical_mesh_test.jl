using Test, TOML, JSON
isempty(ARGS) || length(ARGS) == 2 || error("Usage: julia --project=. test/vertical_mesh_test.jl [fixture-directory evidence-directory]")
include(joinpath(@__DIR__, "..", "src", "WingFEGen.jl"))
const W = WingFEGen

point(m, n) = Tuple(m.xyz[3n-2:3n])
family(m, name) = filter(gr -> startswith(gr.name, name), m.groups)
elements(m, name) = sum(W.n_elements, family(m, name); init=0)
function shell_edges(m, name)
    edges = Set{Tuple{Int,Int}}()
    for gr in family(m, name)
        width = gr.kind == :quad ? 4 : gr.kind == :tria ? 3 : 0
        width > 0 || continue
        for e in 1:W.n_elements(gr)
            nodes = gr.conn[width*(e-1)+1:width*e]
            for q in 1:width
                push!(edges, minmax(nodes[q], nodes[mod1(q+1,width)]))
            end
        end
    end
    return edges
end

# Normalize only the upper-surface height label when comparing meshes.
surface_points(m) = Dict((i,j,k == m.grid.nh ? 1 : 0) => point(m,n)
    for (n,(i,j,k)) in enumerate(m.node_keys) if j >= 0 && k in (0,m.grid.nh))

base = merge(W.default_params(), Dict{String,Any}(
    "planform.area"=>4., "planform.aspect_ratio"=>4., "planform.sweep"=>12.,
    "planform.twist_tip"=>7., "box.rib_pitch"=>.4, "box.stringer_pitch"=>.12,
    "mesh.elements_between_ribs"=>2, "mesh.elements_between_stringers"=>2,
    "mesh.aero_chord_points"=>15, "leading_edge.enabled"=>true,
    "leading_edge.chord_elements"=>5, "loads.cases"=>Any[]))
scenarios = [
    "twisted_tapered" => base,
    "angled_ribs_and_le_gaps" => merge(base, Dict{String,Any}(
        "ribs.masters"=>[Dict("eta"=>.45,"mode"=>"rear_spar_angle","angle"=>95.,"pitch"=>.35)],
        "leading_edge.start_rib"=>2, "leading_edge.disabled_bays"=>"3",
        "leading_edge.rib_orientation"=>"front_spar_angle", "leading_edge.rib_angle"=>100.)),
    "angled_ribs_and_spar_kinks" => merge(base, Dict{String,Any}(
        "ribs.masters"=>[Dict("eta"=>.45,"mode"=>"rear_spar_angle","angle"=>95.,"pitch"=>.35)],
        "box.front_spar_points"=>[Dict("eta"=>.3,"dxc"=>.025),Dict("eta"=>.7,"dxc"=>-.015)],
        "box.rear_spar_points"=>[Dict("eta"=>.5,"dxc"=>.01)],
        "leading_edge.start_rib"=>2, "leading_edge.end_rib"=>4)),
]
reports = Dict{String,Any}()
suite = @testset "Shared vertical mesh count and congruent leading-edge attachment" begin
    @testset "Whole counts, existing defaults and TOML persistence" begin
        spec = W.SCHEMA_BY_KEY["mesh.elements_spar_height"]
        @test spec.kind === :int && spec.group == "Mesh" && spec.default == 3
        @test occursin("leading edge", spec.label)
        for invalid in (0,-1,1.5,true,NaN,Inf,"2.5","",nothing)
            @test_throws ArgumentError W.normalize_params(merge(base,Dict("mesh.elements_spar_height"=>invalid)))
        end
        for invalid in (0,-1,1.5,true,NaN,Inf)
            @test_throws ArgumentError W.build_model(merge(base,Dict("mesh.elements_spar_height"=>invalid)))
        end
        for count in (1,3,7,101)
            params = merge(base,Dict("mesh.elements_spar_height"=>count))
            restored = first(W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(params)))))
            @test restored["mesh.elements_spar_height"] === count
            @test first(W.normalize_params(merge(base,Dict("mesh.elements_spar_height"=>string(count)))))["mesh.elements_spar_height"] === count
        end
        legacy = copy(base); delete!(legacy,"mesh.elements_spar_height")
        restored = first(W.normalize_params(legacy))
        @test restored["mesh.elements_spar_height"] == 3
        original, loaded = W.build_model(copy(base)), W.build_model(restored)
        @test original.xyz == loaded.xyz
        @test original.node_keys == loaded.node_keys
        @test [(gr.eids,gr.conn) for gr in original.groups] == [(gr.eids,gr.conn) for gr in loaded.groups]
    end

    for (name,params) in scenarios
        @testset "$name" begin
            baseline = W.build_model(merge(params,Dict("mesh.elements_spar_height"=>1)))
            for count in (1,2,3,6)
                @testset "$count vertical elements" begin
                    p = merge(params,Dict("mesh.elements_spar_height"=>count))
                    m = W.build_model(p); g = m.grid
                    @test g.nh == count
                    @test W.all_checks_pass(m)
                    @test surface_points(m) == surface_points(baseline)
                    @test g.etas == baseline.grid.etas && g.ribs == baseline.grid.ribs
                    @test m.aero_xyz == baseline.aero_xyz && m.aero_quads == baseline.aero_quads
                    lookup = Dict(key=>n for (n,key) in enumerate(m.node_keys))
                    front, rear = shell_edges(m,"FRONT_SPAR_WEB"), shell_edges(m,"REAR_SPAR_WEB")
                    main_ribs, le_ribs = shell_edges(m,"RIB_WEBS"), shell_edges(m,"LE_RIB_WEBS")
                    layout = W.leading_edge_layout(p,length(g.ribs))

                    # Every through-height segment belongs to the spar and its
                    # main rib; selected leading-edge extensions reuse that
                    # exact front-spar edge, including both endpoint GRID IDs.
                    for (rib,j) in enumerate(g.ribs), k in 0:count-1
                        front_edge = minmax(lookup[(0,j,k)],lookup[(0,j,k+1)])
                        rear_edge = minmax(lookup[(W.ni(g),j,k)],lookup[(W.ni(g),j,k+1)])
                        @test front_edge in front && front_edge in main_ribs
                        @test rear_edge in rear && rear_edge in main_ribs
                        rib in layout.active_ribs && @test front_edge in le_ribs
                    end

                    # Linear placement stays on the same physical spar/rib
                    # boundary while height refinement adds interior nodes.
                    for (n,(i,j,k)) in enumerate(m.node_keys)
                        j >= 0 && 0 < k < count || continue
                        lower,upper = point(m,lookup[(i,j,0)]),point(m,lookup[(i,j,count)])
                        @test collect(point(m,n)) ≈ collect(lower .+ (k/count).*(upper.-lower)) atol=2e-13
                    end
                    @test elements(m,"LE_RIB_NOSE") == count*length(layout.active_ribs)
                    @test elements(m,"LE_RIB_WEBS") == count*(p["leading_edge.chord_elements"]-1)*length(layout.active_ribs)
                    if name != "angled_ribs_and_spar_kinks"
                        for group in ("FRONT_SPAR_WEB","REAR_SPAR_WEB","RIB_WEBS","RIB_STIFFENERS")
                            @test elements(m,group) == count*elements(baseline,group)
                        end
                    end
                    owners = Set(vcat([gr.conn for gr in m.groups]...))
                    @test all(n in owners for n in 1:m.n_struct)
                    @test Dict(m.info)["Vertical elements: spars, ribs and leading edge"] == string(count)
                    reports["$(name)_$count"] = Dict("vertical_elements"=>count,"structural_nodes"=>m.n_struct,
                        "front_spar_elements"=>elements(m,"FRONT_SPAR_WEB"),"main_rib_elements"=>elements(m,"RIB_WEBS"),
                        "leading_edge_rib_elements"=>elements(m,"LE_RIB_WEBS")+elements(m,"LE_RIB_NOSE"),
                        "shared_front_edges"=>count*length(layout.active_ribs),"checks_pass"=>true)
                    if length(ARGS) == 2 && count == 6
                        mkpath(ARGS[1]);write(joinpath(ARGS[1],"vertical_$(name).toml"),W.params_to_toml(p))
                    end
                end
            end
        end
    end
end
if length(ARGS) == 2
    mkpath(ARGS[2]); counts = Test.get_test_counts(suite)
    write(joinpath(ARGS[2],"vertical_mesh_summary.json"),JSON.json(Dict(
        "passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"cases"=>reports),2))
end
