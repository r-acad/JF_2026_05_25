using Test
module UnsupportedDirectionLoadFixture
using Test, OpenJFEM, LinearAlgebra, JSON
const P=OpenJFEM.ReferenceParser
const S=OpenJFEM.Solver
const kinds=("FORCE1","FORCE2","MOMENT1","MOMENT2")
const ids=Dict(i=>i for i=1:4)
const X=[0. 0. 0.;1. 0. 0.;0. 1. 0.;1. 1. 0.]
const rotations=[Matrix{Float64}(I,3,3) for _=1:4]

function fixture(folder,card;sol=101)
    path=joinpath(folder,"unsupported_direction_load.bdf")
    deck="SOL $sol\nCEND\nBEGIN BULK\n"
    for i=1:4
        deck*="GRID,$i,,"*join(X[i,:],",")*"\n"
    end
    deck*="FORCE,1,1,0,2.,1.,0.,0.\n"*card*"ENDDATA\n"
    write(path,deck)
    OpenJFEM.bdf_to_model(path)
end

applied(m,sid;scale=1.)=S._assemble_applied_force(24,m,ids,X,sid,rotations,Dict();load_scale=scale)
combo(sid,parts)=Dict("SID"=>sid,"S"=>1.,"COMPS"=>[Dict("LID"=>p[1],"S"=>p[2]) for p in parts])

function checks()
    mktempdir() do folder
        expected=zeros(24);expected[1]=2.
        for kind in kinds
            fields=endswith(kind,"1") ? ["7","4","-2.5","1","2"] : ["7","4","-2.5","1","2","3","4"]
            free=kind*","*join(fields,",")*"\n"
            small=rpad(kind,8)*join(lpad.(fields,8))*"\n"
            large=rpad(kind*"*",8)*join(lpad.(fields[1:4],16))*"\n"*rpad("*",8)*join(lpad.(fields[5:end],16))*"\n"
            for card in (free,small,large)
                m=fixture(folder,card)
                record=only(m[kind*"s"])
                @test record["TYPE"]==kind
                @test record["SID"]==7
                @test record["Mag"]==-2.5
                @test !isempty(record["FIELDS"])
                @test JSON.parse(JSON.json(m))[kind*"s"][1]["TYPE"]==kind
                @test applied(m,1)==expected
                @test_throws ArgumentError applied(m,7)
            end
            # The common preflight protects both linear and nonlinear applied
            # loads. It runs before any mutation of the accumulation buffer.
            for sol in (101,106)
                m=fixture(folder,free;sol=sol)
                accumulator=ones(24)
                @test_throws ArgumentError S.resolve_loads(m,7,1.,ids,Dict(),X,accumulator)
                @test accumulator==ones(24)
                @test_throws ArgumentError applied(m,7)
                @test applied(m,1)==expected
                @test all(iszero,applied(m,7;scale=0.))
                @test_throws ArgumentError applied(m,7;scale=-1.)
            end
            m=fixture(folder,free)
            # Two distinct nested paths cancel their common leaf exactly;
            # ordinary supported loads on a separate branch remain unchanged.
            m["LOAD_COMBOS"]=[combo(20,[(7,2.)]),combo(21,[(7,4.)]),
                combo(30,[(20,1.),(21,-.5),(1,3.)])]
            @test get(S._load_sid_scales(m,30),7,0.)==0.
            @test applied(m,30)==3expected
            m["LOAD_COMBOS"][3]=combo(30,[(20,1.),(21,-.25),(1,3.)])
            @test_throws ArgumentError applied(m,30)
            m["LOAD_COMBOS"]=[combo(30,[(7,0.),(1,-2.)])]
            @test applied(m,30)==-2expected
            m[kind*"s"][1]["Mag"]=0.
            @test all(iszero,applied(m,7))
            m[kind*"s"][1]["Mag"]=1e-300
            @test_throws ArgumentError applied(m,7;scale=1e-300)
            # Equal and opposite scalar magnitudes do not establish physical
            # cancellation of different geometric directions or force types.
            opposed=deepcopy(m)
            opposed[kind*"s"][1]["Mag"]=2.5
            push!(opposed[kind*"s"],Dict("TYPE"=>kind,"SID"=>7,"Mag"=>-2.5,"FIELDS"=>[4,-2.5,3,4]))
            @test_throws ArgumentError applied(opposed,7)
            other=kind=="FORCE1" ? "MOMENT2" : "FORCE1"
            different=deepcopy(m)
            different[kind*"s"][1]["Mag"]=2.5
            different[other*"s"]=[Dict("TYPE"=>other,"SID"=>7,"Mag"=>-2.5)]
            @test_throws ArgumentError applied(different,7)
            # Raw JSON accepts its documented magnitude field and the shared
            # normalized Mag form, preserving the unsupported card ownership.
            field=startswith(kind,"FORCE") ? "F" : "M"
            for magnitude_key in (field,"Mag")
                record=Dict{String,Any}("SID"=>"7","G"=>4,magnitude_key=>"-2.5","G1"=>1,"G2"=>2)
                raw=Dict("case_control"=>Dict("SOL"=>101),"bulk_data"=>Dict(
                    "GRID"=>deepcopy(m["GRIDs"]),kind=>[record],"FORCE"=>deepcopy(m["FORCEs"])))
                imported=OpenJFEM.build_model_from_json(raw)
                @test only(imported[kind*"s"])["TYPE"]==kind
                @test only(imported[kind*"s"])["Mag"]==-2.5
                @test_throws ArgumentError applied(imported,7)
                @test applied(imported,1)==expected
            end
            for sid in (0,-1,1.5,"invalid")
                @test_throws ArgumentError P.normalize_unsupported_directional_load(Dict("SID"=>sid,"Mag"=>1.),kind)
            end
            for mag in (nothing,NaN,Inf,"invalid")
                @test_throws ArgumentError P.normalize_unsupported_directional_load(Dict("SID"=>7,"Mag"=>mag),kind)
            end
        end
    end
end
end

@testset "Unsupported geometric-direction load selection" begin
    UnsupportedDirectionLoadFixture.checks()
end
