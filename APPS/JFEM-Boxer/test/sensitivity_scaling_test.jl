using Test, JSON
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
out=abspath(only(ARGS));mkpath(out)

struct CountedPropertyIndex <: AbstractDict{Int,Any}
    properties::Dict{Int,Any}
    reads::Base.RefValue{Int}
end
Base.getindex(index::CountedPropertyIndex,pid)=(index.reads[]+=1;index.properties[pid])
Base.length(index::CountedPropertyIndex)=length(index.properties)
Base.iterate(index::CountedPropertyIndex,state...)=iterate(index.properties,state...)

function fixture(sandwich)
    p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,
        "box.rib_pitch"=>.6,"box.stringer_pitch"=>.12,"mesh.elements_between_ribs"=>1,
        "mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "loads.method"=>"analytic","fuel.enabled"=>false,"loads.cases"=>Any[],
        "properties.ribs"=>Any[Dict("rib"=>2,"thickness"=>.016,"height"=>.039)],
        "properties.spar_bays"=>Any[Dict("bay"=>1,"front_thickness"=>.019)]))
    if sandwich
        for row in p["materials.shells"];row["kind"]="sandwich";end
    end
    m=W.build_model(p);panel=first(W.stiffened_panel_layout(m.grid).panels)
    m.params["properties.panels"]=Any[Dict("key"=>W.panel_key(panel),"layout_token"=>W.panel_property_context(m.params).token,
        "skin"=>Dict("thickness"=>.0027,"face_thickness"=>.0007,"material"=>2),
        "stringer"=>Dict("height"=>.037,"material"=>2))]
    W.register_panel_properties!(m.params,m.grid)
    m
end

measurements=Dict{String,Any}()
tests=@testset "Sensitivity property lookup and scalable checkpoints" begin
    @testset "Indexed directions retain all ownership and chain rules" begin
        for sandwich in (false,true)
            m=fixture(sandwich);properties=W.model_property_definitions(m);catalog=W.sensitivity_catalog(m)
            indexed=CountedPropertyIndex(Dict{Int,Any}(p["pid"]=>p for p in properties),Ref(0))
            total_reads=0
            for d in catalog["variables"]
                indexed.reads[]=0
                full=W.sensitivity_analytic_property_directions(m,d;properties)
                scoped=W.sensitivity_analytic_property_directions(m,d;properties,properties_by_pid=indexed)
                @test scoped==full
                @test Set(keys(scoped))==Set(d["pids"])
                @test indexed.reads[]==length(d["pids"])
                total_reads+=indexed.reads[]
            end
            d=first(filter(d->haskey(d,"panel_key"),catalog["variables"]))
            discovery=copy(d);delete!(discovery,"pids")
            @test W.sensitivity_analytic_property_directions(m,discovery;properties,properties_by_pid=indexed)==
                W.sensitivity_analytic_property_directions(m,d;properties)
            full_time=@elapsed for _ in 1:100;W.sensitivity_analytic_property_directions(m,d;properties);end
            indexed_time=@elapsed for _ in 1:100;W.sensitivity_analytic_property_directions(m,d;properties,properties_by_pid=indexed);end
            measurements[sandwich ? "sandwich" : "monolithic"]=Dict("variables"=>length(catalog["variables"]),
                "properties"=>length(properties),"indexed_property_visits"=>total_reads,
                "full_scan_property_visits"=>length(properties)*length(catalog["variables"]),
                "local_100_full_seconds"=>full_time,"local_100_indexed_seconds"=>indexed_time)
        end
    end
    @testset "10580 rows, timed recovery and mandatory final flush" begin
        count=10580;result=Dict{String,Any}("request"=>Dict("variables"=>fill("x",count)),"rows"=>Any[])
        published=Int[];clock=Ref(0.)
        checkpoint=W.sensitivity_result_checkpoint(out,result;clock=()->clock[],
            write_result=(_,data)->push!(published,length(data["rows"])))
        actual=W.sensitivity_checkpointed(checkpoint) do
            for i in 1:count;push!(result["rows"],i);checkpoint();end
            result["status"]="complete";result
        end
        @test actual===result
        @test first(published)==0
        @test last(published)==count
        @test length(published)==fld(count,128)+2
        @test sum(published)<count*(count+1)/100
        @test !checkpoint()
        measurements["checkpoints"]=Dict("rows"=>count,"snapshots"=>length(published),
            "serialized_rows"=>sum(published),"previous_serialized_rows"=>count*(count+1)÷2)
        push!(result["rows"],count+1);clock[]=2.
        @test checkpoint()
        @test last(published)==count+1
        # Final metadata is published even if no row was added since the last write.
        mktempdir(out) do directory
            small=Dict{String,Any}("rows"=>Any[])
            save=W.sensitivity_result_checkpoint(directory,small;clock=()->0.)
            W.sensitivity_checkpointed(save) do
                push!(small["rows"],Dict("id"=>"finished","status"=>"ok"))
                small["status"]="complete"
            end
            @test JSON.parsefile(joinpath(directory,"partial_result.json"))==small
            empty!(small["rows"]);delete!(small,"status")
            failure=ErrorException("owned test cancellation")
            caught=try
                W.sensitivity_checkpointed(save) do
                    push!(small["rows"],Dict("id"=>"retained","status"=>"failed"))
                    throw(failure)
                end
            catch error;error;end
            @test caught===failure
            @test JSON.parsefile(joinpath(directory,"partial_result.json"))==small
        end
    end
end
counts=Test.get_test_counts(tests)
measurements["assertions"]=counts.passes+counts.cumulative_passes;measurements["passed"]=true
write(joinpath(out,"scaling_summary.json"),JSON.json(measurements))
