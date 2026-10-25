using Test, LinearAlgebra, WingFEGen, OpenJFEM
const W=WingFEGen

@testset "Axial actuator stiffness and physical lever arm" begin
    reg=W.NodeRegistry();append!(reg.xyz,[0.,0.,1., 2.,1.,1.5])
    record=Dict{String,Any}("actuator"=>true,"kind"=>"hinge","actuator_stiffness"=>1e7,
        "axis"=>[0.,1.,0.],"origin"=>[1.,0.,0.],"surface"=>"Test", "fitting"=>"shell_lugs","hinge_stiffness"=>123.)
    @test W.add_movable_actuator!(reg,record,1,2,1,100)==101
    @test record["actuator_nodes"]==[1,2]
    @test record["K1_N_per_m"]==1e7
    @test record["actuator_length_m"]≈sqrt(5.25)
    @test record["actuator_hinge_arm_m"]≈2.5/sqrt(5.25)
    @test record["actuator_effective_hinge_stiffness_Nm"]≈1e7*2.5^2/5.25
    f=W.movable_actuator_frame(record);Q=hcat(collect(f.x),collect(f.y),collect(f.z))
    @test Q'Q≈Matrix{Float64}(I,3,3)
    @test det(Q)≈1
    mktempdir() do dir
        path=joinpath(dir,"axial.bdf")
        open(path,"w") do io
            println(io,"SOL 101\nCEND\nBEGIN BULK\nGRID,11,,0.,0.,1.\nGRID,22,,2.,1.,1.5")
            W.write_movable_actuator(io,(node_ids=[11,22],),record)
            println(io,"ENDDATA")
        end
        parsed=OpenJFEM.bdf_to_model(path)
        b=parsed["CBUSHs"]["100"];p=parsed["PBUSHs"][string(record["actuator_pid"])]
        @test p["K"]==[1e7,0.,0.,0.,0.,0.]
        @test (b["GA"],b["GB"],b["CID"])==(11,22,record["actuator_cid"])
        Id=Matrix{Float64}(I,3,3);X=permutedims(reshape(reg.xyz,3,2))
        _,K=OpenJFEM.Solver._cbush_stiffness_matrix(parsed,b,p,Dict(11=>1,22=>2),X,[Id,Id])
        direction=record["actuator_axis"];v=vcat(-direction,zeros(3),direction,zeros(3))
        @test K≈1e7*(v*v') rtol=1e-8 atol=1e-8
        @test count(>(1e-3),eigvals(Symmetric(K)))==1
        @test norm(K[[4,5,6,10,11,12],:])<1e-8
        u=zeros(12);u[7:9]=direction*1e-5
        @test dot((K*u)[7:9],direction)≈100. rtol=1e-8
        omega=record["axis"];turn=zeros(12)
        turn[7:9]=cross(omega,X[2,:]-record["origin"]);turn[10:12]=omega
        @test dot(turn,K*turn)≈record["actuator_effective_hinge_stiffness_Nm"] rtol=1e-8
        for j in 1:3
            rigid=zeros(12);rigid[j]=rigid[j+6]=1
            @test norm(K*rigid)<1e-8
            rigid=zeros(12)
            for n in 1:2
                rigid[6(n-1).+(1:3)]=cross(Id[:,j],X[n,:]);rigid[6(n-1).+(4:6)]=Id[:,j]
            end
            @test norm(K*rigid)<1e-8
        end
    end
    data=Dict("surfaces"=>[Dict("name"=>"Test")],"attachments"=>[record])
    m=(params=Dict("output.solution"=>"101"),movable_structure=data)
    @test W.validate_movable_actuator_paths(m)===nothing
    record["actuator_hinge_arm_m"]=0.
    for sol in ("101","105","106")
        @test_throws ArgumentError W.validate_movable_actuator_paths(m;solution=sol)
    end
    @test W.validate_movable_actuator_paths(m;solution="103")===nothing
    @test W.add_movable_actuator!(reg,merge(record,Dict("kind"=>"rigid")),1,2,2,101)==101
    @test_throws ArgumentError W.add_movable_actuator!(reg,record,1,1,2,101)
end
