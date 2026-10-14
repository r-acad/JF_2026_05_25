using Test, OpenJFEM, LinearAlgebra, JSON

# This integration test accepts a stable private or curated two-preload column
# deck and an explicit artifact directory; it makes no workspace assumptions.
length(ARGS)==2 || throw(ArgumentError("Usage: buckling_output_test.jl <two_preload_column.bdf> <output_directory>"))
const O=OpenJFEM
const S=O.Solver
const INPUT=abspath(ARGS[1])
const OUTPUT=abspath(ARGS[2])
isfile(INPUT) || throw(ArgumentError("Missing input deck: $INPUT"))
mkpath(OUTPUT)
include(joinpath(@__DIR__,"..","JFEM_installation","julia_tools","jfem_output_formats.jl"))

function solve_variant(name;compact=false,energy=false,density=false)
    model=O.bdf_to_model(INPUT)
    O._apply_sol105_output_overrides!(model;compact_buckling=compact,
        export_element_energy=energy,export_energy_density=density)
    result=O.solve_model(O.ReferenceParityBackend(),model)
    dir=joinpath(OUTPUT,name);mkpath(dir)
    # Even explicitly requested heavy formats must be skipped by compact mode.
    O.export_results(result,INPUT,dir;export_json=!compact && !energy && !density,
        export_vtk=compact,export_hdf5=compact,export_jfem_binary=compact,export_report=false)
    path=joinpath(dir,splitext(basename(INPUT))[1]*".BUCKLING.JSON")
    return result,JSON.parsefile(path),path
end

function check_peak_ownership(model,result)
    incidence=O._buckling_property_incidence(model)
    ids=copy(result["id_map"]);ids[99]=length(ids)+1
    vector=zeros(6length(ids))
    vector[6(ids[2]-1)+2]=1
    vector[6(ids[99]-1)+1]=1
    vector[6(ids[1]-1)+4]=1e8 # rotations never win the translation metric
    peak=O._buckling_peak_translation(vector,ids,incidence)
    @test [n["node_id"] for n in peak["nodes"]]==[2,99]
    @test peak["nodes"][1]["property_ids"]==[101,102]
    @test peak["nodes"][1]["element_ids"]==[101,102]
    @test isempty(peak["nodes"][2]["property_ids"])
    @test peak["nodes"][2]["property_status"]=="no_incident_property"
    # A spider reference has no property of its own; do not follow weighted
    # connections to invent a shell/beam PID for it.
    model=deepcopy(model)
    model["RBE3s"]=Dict("900"=>Dict("ID"=>900,"REFGRID"=>99,
        "WT_GROUPS"=>[(wt=1.,comps="123",grids=[2,3])]))
    incidence=O._buckling_property_incidence(model)
    vector.=0;vector[6(ids[99]-1)+1]=2
    peak=O._buckling_peak_translation(vector,ids,incidence)
    @test only(peak["nodes"])["element_ids"]==[900]
    @test isempty(peak["property_ids"])
    zero=O._buckling_peak_translation(zeros(length(vector)),ids,incidence)
    @test zero["all_translations_zero"]
    @test length(zero["nodes"])==length(ids)
end

function check_energy(result,json)
    for subcase in result["buckling"].subcases
        state=result["static_states"][subcase.static_subcase_id]
        exported=only(filter(row->row["static_subcase_id"]==subcase.static_subcase_id,json["static_subcases"]))
        energy=exported["element_energy"]
        @test energy==exported["static_result"]["element_energy"]
        @test energy["status"]=="complete"
        @test energy["coverage"]["energy_available"]==2
        @test all(row->isapprox(row["volume"],.0005;rtol=1e-12),energy["records"])
        total=sum(row["deformation_energy"] for row in energy["records"])
        @test total≈.5dot(state.u_static,state.K*state.u_static) rtol=1e-10
        load=subcase.static_subcase_id==11 ? 1000. : 2000.
        @test total≈load^2/(2*7e10*.001) rtol=1e-10
        for mode in eachindex(subcase.reported_eigenvalues)
            row=only(filter(row->row["buckling_subcase_id"]==subcase.buckling_subcase_id &&
                row["subcase_mode_index"]==mode,json["modes"]))
            e=row["element_energy"]
            phi=copy(subcase.reported_mode_shapes[:,mode])
            for index in values(state.id_map), components in (1:3,4:6)
                dofs=6(index-1).+components
                phi[dofs]=state.node_R[index]'*phi[dofs]
            end
            @test sum(r["deformation_energy"] for r in e["records"])≈.5dot(phi,state.K_eig*phi) rtol=1e-9
            @test all(r->isapprox(r["energy_density"]*r["volume"],r["deformation_energy"];rtol=1e-13),e["records"])
            @test occursin("arbitrary amplitude",e["normalization"])
            @test row["peak_translation"]["property_ids"]==(mode==3 ? [101,102] : [102])
            @test only(row["peak_translation"]["nodes"])["node_id"]==(mode==3 ? 2 : 3)
        end
    end
    @test norm(result["static_states"][11].node_R[result["id_map"][2]]-I)>1
    # An output-only scale check: cached values must follow the as-exported
    # vector rather than secretly normalizing every mode independently.
    first_case=first(result["buckling"].subcases)
    old=result["element_energy_by_subcase"][first_case.static_subcase_id].modes[(first_case.buckling_subcase_id,1)]
    expected=[4r["deformation_energy"] for r in old["records"]]
    first_case.reported_mode_shapes[:,1].*=2
    delete!(result,"element_energy_by_subcase")
    new=O._sol105_element_energy!(result)[first_case.static_subcase_id].modes[(first_case.buckling_subcase_id,1)]
    @test [r["deformation_energy"] for r in new["records"]]≈expected rtol=1e-12
    first_case.reported_mode_shapes[:,1]./=2
    # Explicit coverage instead of a made-up stress-based fallback.
    for (sid,state) in result["static_states"]
        result["static_states"][sid]=merge(state,(assembly_options=nothing,))
    end
    delete!(result,"element_energy_by_subcase")
    unavailable=O._sol105_element_energy!(result)
    @test all(value.preload["status"]=="unavailable" for value in values(unavailable))
    @test all(r["deformation_energy"]===nothing for value in values(unavailable) for r in value.preload["records"])
end

function check_element_capture()
    # Small independent operator test covers shells (including laminate volume),
    # rods, solids and discrete springs without needing another eigensolve.
    mktempdir() do dir
        path=joinpath(dir,"element_coverage.bdf")
        lines=String["SOL 105","CEND","BEGIN BULK","PARAM,SNORM,0.",
            "MAT1,1,7.E10,,.3,2700.","PSHELL,10,1,.02,1,,1",
            "PCOMP,11","+,1,.01,15.,YES,1,.02,-25.,YES",
            "PROD,12,1,.003,.00001","PSOLID,13,1","PELAS,14,1234.",
            "PBUSH,15,K,10.,20.,30.,40.,50.,60."]
        xyz=[(0.,0.,0.),(1.,0.,0.),(1.,1.,0.),(0.,1.,0.),
            (0.,0.,1.),(1.,0.,1.),(1.,1.,1.),(0.,1.,1.),
            (.5,0.,0.),(1.,.5,0.),(.5,1.,0.),(0.,.5,0.),(.5,.5,0.)]
        for (i,(x,y,z)) in enumerate(xyz)
            push!(lines,"GRID,$i,,$x,$y,$z")
        end
        append!(lines,["CQUAD4,1,11,1,2,3,4","CTRIA3,2,10,1,2,4",
            "CROD,3,12,1,2","CONROD,4,1,2,1,.003,.00001",
            "CTETRA,5,13,1,2,4,5","CHEXA,6,13,1,2,3,4,5,6,7,8",
            "CPENTA,7,13,1,2,4,5,6,8","CELAS1,8,14,1,1,2,1",
            "CELAS2,9,5678.,1,2,2,2","CBUSH,10,15,1,2",
            "CQUAD8,11,11,1,2,3,4,9,10","+,11,12",
            "CTRIA6,12,10,1,2,4,9,13,12","ENDDATA"])
        write(path,join(lines,'\n')*"\n")
        model=O.bdf_to_model(path)
        energies=zeros(12);v=sin.(Float64.(1:6length(xyz)))
        guard=ReentrantLock()
        capture=(eid,pid,dofs,ke)->lock(guard) do
            energies[eid]+=.5dot(v[dofs],ke*v[dofs])
        end
        assembly_options=(sol105_context=true,snorm_angle_override=0.0)
        assembled=S.assemble_stiffness(model;assembly_options...,element_capture=capture)
        @test all(isfinite,energies)
        @test all(>(0),energies)
        @test sum(energies)≈.5dot(v,first(assembled)*v) rtol=1e-12
        expected=Dict(1=>.03,2=>.01,3=>.003,4=>.003,5=>1/6,6=>1.,7=>.5,11=>.03,12=>.01)
        for family in O._BUCKLING_PROPERTY_FAMILIES, element in values(get(model,family,Dict()))
            eid=Int(element["ID"])
            volume=O._buckling_element_volume(model,family,element)
            if haskey(expected,eid)
                @test volume≈expected[eid] rtol=1e-12
            else
                @test volume===nothing
            end
        end
        @test model["PSHELLs"]["11"]["T"]≈.03
        state=(u_static=v,id_map=assembled[2],node_R=assembled[5],temp_load_id=nothing,assembly_options=assembly_options)
        br=(subcases=[(static_subcase_id=1,buckling_subcase_id=2,
            reported_eigenvalues=[1.],reported_mode_shapes=reshape(copy(v),:,1))],)
        result=Dict{String,Any}("model"=>model,"buckling"=>br,"static_states"=>Dict{Int,Any}(1=>state),
            "output_options"=>O._sol105_output_options(Dict("PARAM_JFBKENG"=>1,"PARAM_JFBKDEN"=>1)))
        payload=O._sol105_element_energy!(result)[1].preload
        @test payload["coverage"]["energy_available"]==12
        @test payload["coverage"]["density_available"]==9
        @test payload["status"]=="partial"
        @test [r["deformation_energy"] for r in payload["records"]]≈energies rtol=1e-12
        @test sum(r["deformation_energy"] for r in payload["records"])≈.5dot(v,first(assembled)*v) rtol=1e-12
        for r in payload["records"]
            if r["eid"] in (8,9,10)
                @test r["energy_density"]===nothing
                @test haskey(r,"density_reason")
                @test r["status"]=="partial"
            end
        end
        # Initial thermal strain must not be mislabeled as physical stored
        # preload energy, while the incremental elastic mode energy is valid.
        result["static_states"][1]=merge(state,(temp_load_id=99,))
        delete!(result,"element_energy_by_subcase")
        thermal=O._sol105_element_energy!(result)[1]
        @test thermal.preload["status"]=="unavailable"
        @test thermal.modes[(2,1)]["status"]=="partial"
        result["static_states"][1]=state
        result["output_options"]=O._sol105_output_options(Dict("PARAM_JFBKDEN"=>1))
        delete!(result,"element_energy_by_subcase")
        density=O._sol105_element_energy!(result)[1].preload
        @test density["status"]=="partial"
        for r in density["records"]
            @test !haskey(r,"deformation_energy")
            @test r["status"]==(r["eid"] in (8,9,10) ? "unavailable" : "available")
        end
        # The physical PBEAM volume includes intermediate stations regardless
        # of the stiffness formulation's station-condensation switch.
        model["PBARLs"]["20"]=Dict("A"=>1.,"STATIONS"=>[
            Dict("X"=>0.,"A"=>1.),Dict("X"=>.5,"A"=>3.),Dict("X"=>1.,"A"=>1.)])
        beam=Dict("GA"=>1,"GB"=>2,"PID"=>20)
        for setting in ("false","true")
            withenv("JFEM_PBEAM_STATION_CONDENSED"=>setting) do
                @test O._buckling_element_volume(model,"CBEAMs",beam)≈2.
            end
        end
    end
end

summary=Dict{String,Any}()
@testset "SOL105 compact and element energy output" begin
    @test _parse_format_letters("-b")[:compact_buckling]
    @test _parse_format_letters("-ed")[:export_element_energy]
    @test _parse_format_letters("-ed")[:export_energy_density]
    @test_throws ArgumentError _parse_format_letters("-z")
    @test_throws ArgumentError O._apply_sol105_output_overrides!(Dict{String,Any}("SOL"=>101);compact_buckling=true)
    @test_throws ArgumentError O._sol105_output_options(Dict("PARAM_JFBKCOMP"=>2))
    plain,pj,pp=solve_variant("normal")
    compact,cj,cp=solve_variant("compact";compact=true,energy=true,density=true)
    energy,ej,ep=solve_variant("energy";energy=true,density=true)
    @test length(plain["eigenvalues"])==6
    @test compact["eigenvalues"]≈plain["eigenvalues"] rtol=1e-12
    @test energy["eigenvalues"]≈plain["eigenvalues"] rtol=1e-12
    @test cj["eigenvalues"]==pj["eigenvalues"]==ej["eigenvalues"]
    @test cj["mode_shape_status"]=="omitted_compact"
    @test !haskey(cj,"grid_id_order") && !haskey(cj,"static_displacements")
    @test all(!haskey(m,"mode_shape") && !haskey(m,"element_energy") for m in cj["modes"])
    @test all(collect(keys(s))==["static_subcase_id"] for s in cj["static_subcases"])
    @test length(readdir(dirname(cp)))==1
    @test isempty(compact["mode_shapes"])
    @test !haskey(compact,"static_results_by_subcase")
    @test isempty(get(compact,"static_shell_fields_by_subcase",Dict()))
    @test !haskey(compact,"element_energy_by_subcase")
    @test cj["output_options"]["requested_deformation_energy"]
    @test !cj["output_options"]["deformation_energy"]
    for (compact_mode,normal_mode) in zip(cj["modes"],pj["modes"])
        @test all(compact_mode[key]==normal_mode[key] for key in ("eigenvalue","static_subcase_id",
            "buckling_subcase_id","subcase_mode_index","global_mode_source_index","peak_translation"))
    end
    @test first(cj["modes"])["static_subcase_id"]==12
    roots=Dict(s["buckling_subcase_id"]=>s["eigenvalues"] for s in cj["subcases"])
    @test roots[21]≈2roots[22] rtol=1e-10
    check_peak_ownership(plain["model"],plain)
    check_energy(energy,ej)
    check_element_capture()
    summary["status"]="PASS"
    summary["eigenvalues"]=pj["eigenvalues"]
    summary["normal_json"]=pp;summary["compact_json"]=cp;summary["energy_json"]=ep
    summary["json_bytes"]=Dict("normal"=>filesize(pp),"compact"=>filesize(cp),"energy"=>filesize(ep))
end
open(joinpath(OUTPUT,"summary.json"),"w") do io;JSON.print(io,summary,2);end
