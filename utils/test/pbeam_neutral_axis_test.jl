using Test, OpenJFEM, LinearAlgebra

const PBEAM_AXIS_SOLVER = OpenJFEM.Solver

function pbeam_axis_test_property(n1,n2)
    p=Dict{String,Any}("TYPE"=>"PBEAM","PID"=>10,"MID"=>1,
        "A"=>4.7e-4,"I1"=>2.1e-7,"I2"=>8.3e-8,"I12"=>-3.2e-8,"J"=>8.2e-9,
        "K1"=>.72,"K2"=>.56,"N1A"=>n1,"N2A"=>n2,"N1B"=>n1,"N2B"=>n2)
    p["STATIONS"]=[Dict{String,Any}("X"=>x,(k=>p[k] for k in ("A","I1","I2","I12","J"))...) for x in (0.,1.)]
    return p
end

@testset "Prismatic PBEAM neutral-axis cantilever flexibility" begin
    withenv("JFEM_PBEAM_NEUTRAL_AXIS_COUPLING"=>nothing) do
        E=73e9; G=E/(2*1.29)
        for L in (.08,.72,1.3), (n1,n2) in ((-.023,.041),(.017,-.029),(0.,0.))
            p=pbeam_axis_test_property(n1,n2)
            k0=OpenJFEM.FEM.stiffness_frame3d(L,p["A"],p["I2"],p["I1"],p["J"],E,G;
                I12=p["I12"],As_y=p["K1"]*p["A"],As_z=p["K2"]*p["A"])
            k=PBEAM_AXIS_SOLVER._apply_pbeam_neutral_axis_coupling(k0,p)
            load=[1.,0.,0.,0.,0.,0.]
            u=vcat(zeros(6),k[7:12,7:12]\load)
            # Castigliano: an axial force at the shear centre also causes
            # constant moments F*[N1,N2] about the centroid's bending axes.
            D=E*[p["I1"] p["I12"];p["I12"] p["I2"]]
            offset=[n1,n2]
            compliance=L/(E*p["A"])+L*dot(offset,D\offset)
            @test u[7] ≈ compliance rtol=2e-12
            @test k ≈ transpose(k) rtol=2e-14
            @test minimum(eigvals(Symmetric(k))) >= -1e-12*opnorm(k)
            @test count(x->abs(x)<1e-10*opnorm(k),eigvals(Symmetric(k)))==6
            section=PBEAM_AXIS_SOLVER._pbeam_neutral_axis_section_forces(k*u,p)
            @test section[7:12] ≈ [1.,0.,0.,0.,-n2,n1] rtol=1e-10 atol=2e-13
            @test dot(u,k*u) ≈ compliance rtol=2e-12
            C=PBEAM_AXIS_SOLVER._pbeam_neutral_axis_transform(p)
            if C !== nothing
                @test dot(C*u,section) ≈ dot(u,k*u) rtol=2e-12
            else
                @test k==k0
            end
        end
    end
end

@testset "PBEAM neutral-axis route has an explicit verified scope" begin
    withenv("JFEM_PBEAM_NEUTRAL_AXIS_COUPLING"=>nothing,"JFEM_PBEAM_FORCE_FLEXIBILITY"=>"false") do
        p=pbeam_axis_test_property(.02,-.03)
        @test PBEAM_AXIS_SOLVER._pbeam_neutral_axis_transform(p)!==nothing
        absent=deepcopy(p); absent["STATIONS"]=nothing
        @test PBEAM_AXIS_SOLVER._pbeam_neutral_axis_transform(absent)!==nothing
        varying=deepcopy(p); varying["STATIONS"][2]["I1"] *= 1.001
        @test PBEAM_AXIS_SOLVER._pbeam_neutral_axis_transform(varying)===nothing
        varying=deepcopy(p); varying["N1B"] += .001
        @test PBEAM_AXIS_SOLVER._pbeam_neutral_axis_transform(varying)===nothing
        ordinary=deepcopy(p); ordinary["TYPE"]="PBAR"
        @test PBEAM_AXIS_SOLVER._pbeam_neutral_axis_transform(ordinary)===nothing
        withenv("JFEM_PBEAM_NEUTRAL_AXIS_COUPLING"=>"false") do
            @test PBEAM_AXIS_SOLVER._pbeam_neutral_axis_transform(p)===nothing
        end
    end
end

@testset "Blank PBEAM end-B neutral-axis offsets inherit end A" begin
    mktempdir() do folder
        path=joinpath(folder,"neutral_axis.bdf")
        write(path,"""
        SOL 101
        CEND
        BEGIN BULK
        GRID,1,,0.,0.,0.
        GRID,2,,1.,0.,0.
        MAT1,1,7.3e10,,.29,,1.e-5,20.
        PBEAM,10,1,.00047,2.1e-7,8.3e-8,-3.2e-8,8.2e-9
        +,0.,0.,0.,0.,0.,0.,0.,0.
        +,YES,1.,.00047,2.1e-7,8.3e-8,-3.2e-8,8.2e-9
        +,0.,0.,0.,0.,0.,0.,0.,0.
        +,.72,.56
        +,,,,,.017,-.029
        CBEAM,1,10,1,2,0.,1.,0.
        TEMP,900,1,40.,2,40.
        ENDDATA
        """)
        model=OpenJFEM.bdf_to_model(path)
        p=model["PBARLs"]["10"]
        @test p["N1A"]==p["N1B"]==.017
        @test p["N2A"]==p["N2B"]==-.029
        withenv("JFEM_PBEAM_NEUTRAL_AXIS_COUPLING"=>nothing) do
            @test PBEAM_AXIS_SOLVER._pbeam_neutral_axis_transform(p)!==nothing
        end
        raw=Dict{String,Any}("case_control"=>Dict{String,Any}(),
            "bulk_data"=>Dict("PBEAM"=>Dict("10"=>p)))
        rebuilt=OpenJFEM.build_model_from_json(raw)
        q=rebuilt["PBARLs"]["10"]
        @test q["STATIONS"]==p["STATIONS"]
        @test all(q[key]==p[key] for key in ("N1A","N2A","N1B","N2B"))
        withenv("JFEM_PBEAM_NEUTRAL_AXIS_COUPLING"=>nothing) do
            for release in (0,6)
                model["CBEAMs"]["1"]["PB"]=release
                K,ids,coords,ndof,rotations=PBEAM_AXIS_SOLVER.assemble_stiffness(model)[1:5]
                load=zeros(ndof)
                PBEAM_AXIS_SOLVER.resolve_thermal_loads(model,900,1.,ids,Dict(),coords,load;node_R=rotations)
                tip=6*(ids[2]-1).+(1:6)
                active=release==0 ? tip : tip[1:5]
                u=zeros(ndof);u[active]=K[active,active]\load[active]
                @test u[tip] ≈ [2.e-4,0.,0.,0.,0.,0.] atol=1e-16 rtol=1e-11
                @test norm(K*u-load) <= 1e-10*norm(load)
                @test norm(load[tip[5:6]]) > 0
            end
        end
    end
end
