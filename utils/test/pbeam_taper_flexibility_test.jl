using Test, OpenJFEM, LinearAlgebra

const PBEAM_TAPER_SOLVER = OpenJFEM.Solver

function pbeam_taper_test_property(;centroid=false,interior=false)
    stations=Dict{String,Any}[
        Dict("X"=>0.,"A"=>4.0e-4,"I1"=>2.0e-7,"I2"=>8.0e-8,"I12"=>0.,"J"=>9.0e-9),
        Dict("X"=>1.,"A"=>2.0e-4,"I1"=>5.0e-8,"I2"=>4.0e-8,"I12"=>0.,"J"=>3.0e-9)]
    if interior
        insert!(stations,2,Dict("X"=>.35,"A"=>6e-4,"I1"=>3e-7,"I2"=>9e-8,"I12"=>0.,"J"=>11e-9))
    end
    p=Dict{String,Any}("TYPE"=>"PBEAM","PID"=>1,"MID"=>1,"STATIONS"=>stations,"K1"=>.72,"K2"=>.56,
        "N1A"=>centroid ? .017 : 0.,"N2A"=>centroid ? -.029 : 0.,
        "N1B"=>centroid ? -.023 : 0.,"N2B"=>centroid ? .041 : 0.)
    for key in ("A","I1","I2","I12","J")
        p[key]=(first(stations)[key]+last(stations)[key])/2
    end
    return p
end

@testset "Tapered PBEAM cantilever flexibility uses each station interval" begin
    withenv("JFEM_PBEAM_FORCE_FLEXIBILITY"=>nothing,"JFEM_PBEAM_STATION_CONDENSED"=>nothing) do
        E=73e9;G=E/(2*1.29)
        for L in (.08,.72,1.3), interior in (false,true)
            p=pbeam_taper_test_property(;interior)
            @test PBEAM_TAPER_SOLVER._pbeam_force_flexibility_active(p)
            K=PBEAM_TAPER_SOLVER._beam_local_stiffness(L,p,E,G)
            compliance=inv(Symmetric(K[7:12,7:12]))
            # Independent cantilever virtual-work integrals: a unit tip
            # transverse force has M(x)=L-x, while a unit tip moment has M=1.
            axial=torsion=bending=slope=rotation=0.
            for (a,b) in zip(p["STATIONS"][1:end-1],p["STATIONS"][2:end])
                for (r,w) in ((-sqrt(.6),5/9),(0.,8/9),(sqrt(.6),5/9))
                    t=(1+r)/2;x=a["X"]+t*(b["X"]-a["X"])
                    dx=w*L*(b["X"]-a["X"])/2
                    area=(1-t)*a["A"]+t*b["A"]
                    inertia=(1-t)*a["I1"]+t*b["I1"]
                    torsion_constant=(1-t)*a["J"]+t*b["J"]
                    axial+=dx/(E*area);torsion+=dx/(G*torsion_constant)
                    bending+=dx*((L*(1-x))^2/(E*inertia)+1/(G*p["K1"]*area))
                    slope+=dx*L*(1-x)/(E*inertia)
                    rotation+=dx/(E*inertia)
                end
            end
            @test compliance[1,1] ≈ axial rtol=3e-12
            @test compliance[4,4] ≈ torsion rtol=3e-12
            @test compliance[2,2] ≈ bending rtol=3e-12
            @test compliance[2,6] ≈ slope rtol=3e-12
            @test compliance[6,6] ≈ rotation rtol=3e-12
            @test K ≈ transpose(K) rtol=1e-13
            @test minimum(eigvals(Symmetric(K))) >= -1e-12*opnorm(K)
            @test count(x->abs(x)<1e-10*opnorm(K),eigvals(Symmetric(K)))==6
        end
    end
end

@testset "Tapered centroid section recovery and free thermal expansion" begin
    withenv("JFEM_PBEAM_FORCE_FLEXIBILITY"=>nothing,"JFEM_PBEAM_STATION_CONDENSED"=>nothing) do
        E=73e9;G=E/(2*1.29);L=.8
        for centroid in (false,true),interior in (false,true),release in (0,6)
            p=pbeam_taper_test_property(;centroid,interior)
            bar=Dict{String,Any}("PA"=>0,"PB"=>release)
            K=Matrix(PBEAM_TAPER_SOLVER._beam_local_stiffness(L,p,E,G))
            release==0 || PBEAM_TAPER_SOLVER.apply_bar_pin_flags!(K,0,release)
            active=release==0 ? collect(7:12) : collect(7:11)
            thermal_strain=2.e-4;nth=E*p["A"]*thermal_strain
            thermal=zeros(12);thermal[1]=-nth;thermal[7]=nth
            load=PBEAM_TAPER_SOLVER._pbeam_thermal_generalized_load(thermal,p,bar,L,E,G)
            u=zeros(12);u[active]=K[active,active]\load[active]
            @test u ≈ [zeros(6);L*thermal_strain;zeros(5)] atol=1e-15 rtol=1e-10
            @test norm(K*u-load)<=1e-10*norm(load)
            mech=zeros(12);mech[active]=K[active,active]\[1.;zeros(length(active)-1)]
            recovery=PBEAM_TAPER_SOLVER._stress_beam_force_flexibility_recovery(L,p,bar,E,G,mech,zeros(12))
            @test recovery.f_local[7] ≈ 1. rtol=1e-11
            @test recovery.section_a.A==first(p["STATIONS"])["A"]
            @test recovery.section_b.A==last(p["STATIONS"])["A"]
            @test recovery.section_a.Iz==first(p["STATIONS"])["I1"]
            @test recovery.section_b.Iz==last(p["STATIONS"])["I1"]
            @test recovery.f_local[11] ≈ -p["N2B"] rtol=1e-10 atol=1e-12
            @test recovery.f_local[12] ≈ p["N1B"] rtol=1e-10 atol=1e-12
        end
        p=pbeam_taper_test_property()
        withenv("JFEM_PBEAM_FORCE_FLEXIBILITY"=>"false") do
            @test !PBEAM_TAPER_SOLVER._pbeam_force_flexibility_active(p)
        end
        for field in ("S1","CWA")
            invalid=deepcopy(p);invalid[field]=.1
            @test !PBEAM_TAPER_SOLVER._pbeam_force_flexibility_active(invalid)
        end
        invalid=deepcopy(p);invalid["STATIONS"][2]["I1"]=0.
        @test !PBEAM_TAPER_SOLVER._pbeam_force_flexibility_active(invalid)
    end
end
