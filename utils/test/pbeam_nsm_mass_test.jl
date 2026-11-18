using Test, LinearAlgebra, OpenJFEM

@testset "PBEAM independent NSM polar inertia" begin
    solver = OpenJFEM.Solver
    length_beam = 1.5
    prop = Dict("NSM"=>2.0, "NSIA"=>0.01, "NSIB"=>0.03)
    translation = zeros(12)
    translation[1] = translation[7] = 1.0
    spin = zeros(12)
    spin[4] = spin[10] = 1.0
    for coupled in (false, true)
        mass = solver._pbeam_nsm_mass(length_beam, prop, coupled)
        @test dot(translation, mass*translation) ≈ 3.0
        @test dot(spin, mass*spin) ≈ 0.03
        @test mass ≈ mass'
        @test minimum(eigvals(Symmetric(mass))) > -1e-14
        inertia_only = solver._pbeam_nsm_mass(length_beam,
            merge(prop, Dict("NSM"=>0.0)), coupled)
        @test dot(translation, inertia_only*translation) == 0.0
        @test dot(spin, inertia_only*spin) ≈ 0.03
    end
    default_end = solver._pbeam_nsm_mass(length_beam,
        Dict("NSM"=>0.0, "NSIA"=>0.02), false)
    @test dot(spin, default_end*spin) ≈ 0.03
end

@testset "Piecewise-linear PBEAM NSM kinetic moments" begin
    solver = OpenJFEM.Solver
    length_beam = 2.7
    profile = [(0.0,2.0), (0.25,7.0), (1.0,3.0)]
    moments = zeros(3)
    # Independent exact antiderivatives, without the production quadrature.
    for ((left,a),(right,b)) in zip(profile[1:end-1],profile[2:end])
        slope = (b-a)/(right-left)
        intercept = a-slope*left
        for power in 0:2
            moments[power+1] += length_beam^(power+1) * (
                intercept*(right^(power+1)-left^(power+1))/(power+1) +
                slope*(right^(power+2)-left^(power+2))/(power+2))
        end
    end
    stations = [Dict("X"=>x,"NSM"=>density) for (x,density) in profile]
    prop = Dict("NSM"=>moments[1]/length_beam, "STATIONS"=>stations)
    rigid = zeros(12,6)
    for (base,x) in ((0,0.0),(6,length_beam))
        rigid[base+1:base+3,1:3] = Matrix{Float64}(I,3,3)
        rigid[base+4:base+6,4:6] = Matrix{Float64}(I,3,3)
        rigid[base+2,6] = x
        rigid[base+3,5] = -x
    end
    for coupled in (false,true)
        mass = solver._pbeam_nsm_mass(length_beam, prop, coupled)
        reduced = rigid' * mass * rigid
        @test reduced[1:3,1:3] ≈ moments[1]*I rtol=2e-14
        @test reduced[2,6] ≈ moments[2] rtol=2e-14
        @test reduced[3,5] ≈ -moments[2] rtol=2e-14
        expected_inertia = coupled ? moments[3] : length_beam*moments[2]
        @test reduced[5,5] ≈ expected_inertia rtol=2e-14
        @test reduced[6,6] ≈ expected_inertia rtol=2e-14
        @test mass ≈ mass'
        @test minimum(eigvals(Symmetric(mass))) > -1e-12
        # Splitting a linear interval into redundant stations is invariant.
        extra = Dict("X"=>0.625,"NSM"=>5.0)
        redundant = merge(prop, Dict("STATIONS"=>[stations[1],stations[2],extra,stations[3]]))
        @test solver._pbeam_nsm_mass(length_beam,redundant,coupled) ≈ mass rtol=2e-14
    end
end

@testset "SYSTEM 414 and PBEAM NSI through the normal model entry" begin
    solver = OpenJFEM.Solver
    mktempdir() do dir
        path = joinpath(dir,"mass.bdf")
        write(path,"""
        NASTRAN SYSTEM(414)=1, SYSTEM(442)=2
        SOL 103
        CEND
        BEGIN BULK
        PARAM,COUPMASS,-1
        GRID,1,,0.,0.,0.
        GRID,2,,1.5,0.,0.
        CBEAM,1,1,1,2,0.,1.,0.,BBB
        +,,,0.,.1,.2,0.,.1,.2
        PBAR,1,1,.0012,.0000018,.0000011,.00000008
        MAT1,1,7.E10,,.3,2700.
        ENDDATA
        """)
        model = OpenJFEM.bdf_to_model(path)
        @test model["CASE_CONTROL"]["SYSTEMS"] == Dict("414"=>1,"442"=>2)
        @test solver._beam_system_cell(model,414) == 1
        @test solver._beam_system_cell(model,398) == 0
        @test solver._beam_system_cell(Dict("CASE_CONTROL"=>Dict(
            "NASTRAN SYSTEM"=>1,"NASTRAN SYSTEM_MODIFIER"=>"414")),414) == 1
        ids = Dict(1=>1,2=>2)
        points = [0.0 0.0 0.0; 1.5 0.0 0.0]
        frames = [Matrix{Float64}(I,3,3),Matrix{Float64}(I,3,3)]
        mass() = Matrix(solver.assemble_mass(model,ids,points,frames,12))
        prop = model["PBARLs"]["1"]
        prop["NSM"] = 2.0
        prop["NSIA"] = 0.01
        prop["NSIB"] = 0.03
        rotational = [4,5,6,10,11,12]
        lumped = mass()
        @test all(iszero,lumped[rotational,:])
        @test lumped ≈ Diagonal(diag(lumped))
        @test sum(lumped[[1,7],[1,7]]) ≈ 1.5*(2700*.0012+2)
        # SYSTEM 414 applies to lumped mass. Coupled mass preserves its
        # physical offset and section inertia regardless of this switch.
        model["PARAM_COUPMASS"] = 1
        coupled = mass()
        model["CASE_CONTROL"]["SYSTEMS"]["414"] = 0
        @test mass() == coupled
        model["PARAM_COUPMASS"] = -1
        ordinary = mass()
        @test norm(ordinary[rotational,:]) > 0.0
        @test ordinary[1,1] == lumped[1,1]
        # An intrinsic polar inertia remains with zero scalar/material mass.
        model["MATs"]["1"]["RHO"] = 0.0
        prop["NSM"] = 0.0
        spin = zeros(12)
        spin[4] = spin[10] = 1.0
        @test dot(spin,mass()*spin) ≈ 0.03
        model["MATs"]["1"]["RHO"] = 2700.0
        prop["NSM"] = 2.0
        model["CBARs"] = pop!(model,"CBEAMs")
        model["CASE_CONTROL"]["SYSTEMS"]["414"] = 1
        bar_mass = mass()
        @test all(iszero,bar_mass[rotational,:])
        @test sum(bar_mass[[1,7],[1,7]]) ≈ 1.5*(2700*.0012+2)
        model["CASE_CONTROL"]["SYSTEMS"]["414"] = 0
        @test norm(mass()[rotational,:]) > 0.0
        @test_throws ArgumentError solver._beam_system_cell(Dict(
            "CASE_CONTROL"=>Dict("SYSTEMS"=>Dict("414"=>1.5))),414)
    end
end
