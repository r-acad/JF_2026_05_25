module PbeamLoadScopeTests

using Test, OpenJFEM
const S = OpenJFEM.Solver

@testset "PBEAM distributed-load scope follows the selected LOAD" begin
    mktempdir() do folder
        deck=joinpath(folder,"distributed_beam.bdf")
        write(deck,"""
        SOL 101
        CEND
        BEGIN BULK
        GRID,1,,0.,0.,0.
        GRID,2,,1.,0.,0.
        MAT1,1,7.3e10,,.29
        PBEAM,2,1,.00047,2.1e-7,8.3e-8,-3.2e-8,8.2e-9
        +,0.,0.,0.,0.,0.,0.,0.,0.
        +,.72,.56
        +,,,,,.017,-.029
        CBEAM,2,2,1,2,0.,1.,0.
        PLOAD1,900,2,FX,FR,0.,1000.,1.,1000.
        LOAD,901,1.,2.,900
        FORCE,902,2,0,1.,1.,0.,0.
        ENDDATA
        """)
        model=OpenJFEM.bdf_to_model(deck)
        ids=Dict(1=>1,2=>2);coords=[0. 0. 0.;1. 0. 0.]
        withenv("JFEM_PBEAM_NEUTRAL_AXIS_COUPLING"=>nothing,
                "JFEM_PBEAM_FORCE_FLEXIBILITY"=>nothing) do
            for sid in (900,901)
                @test_throws ArgumentError S.resolve_loads(model,sid,1.,ids,Dict(),coords,zeros(12))
                @test_throws ArgumentError S._beam_pload1_local_load_vector_for_sid(model,2,sid,1.)
            end
            nodal=zeros(12);S.resolve_loads(model,902,1.,ids,Dict(),coords,nodal)
            @test nodal[7]==1.
            zero=zeros(12);S.resolve_loads(model,900,0.,ids,Dict(),coords,zero)
            @test all(iszero,zero)
            prop=model["PBARLs"]["2"]
            for key in ("N1A","N1B","N2A","N2B")
                prop[key]=0.
            end
            ordinary=zeros(12);S.resolve_loads(model,900,1.,ids,Dict(),coords,ordinary)
            @test ordinary[[1,7]]≈[500.,500.]
            @test S._beam_pload1_local_load_vector_for_sid(model,2,900,1.)≈ordinary
            # A varying zero-offset section also needs its own consistent
            # distributed-load operator; it cannot reuse a uniform beam's.
            prop["STATIONS"]=[Dict("X"=>x,(key=>prop[key] for key in ("A","I1","I2","I12","J"))...) for x in (0.,1.)]
            prop["STATIONS"][2]["A"]*=1.1
            @test S._pbeam_force_flexibility_active(prop)
            @test_throws ArgumentError S.resolve_loads(model,900,1.,ids,Dict(),coords,zeros(12))
            @test_throws ArgumentError S._assert_nonlinear_pbeam_neutral_axis_supported(model)
        end
    end
end

end
