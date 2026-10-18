using Test, OpenJFEM, LinearAlgebra

module GeometricCaptureThreadSafetyFixture
using Test, OpenJFEM, LinearAlgebra
const S = OpenJFEM.Solver

function checks()
    mktempdir() do dir
        path=joinpath(dir,"mixed_shell_capture.bdf")
        open(path,"w") do io
            println(io,"SOL 101\nCEND\nBEGIN BULK\nPARAM,K6ROT,0.\nMAT1,1,7.E10,,.3\nPSHELL,1,1,.025,1,,1")
            for cell in 0:7
                base=4cell
                for (j,(x,y)) in enumerate(((0.,0.),(1.,0.),(1.,1.),(0.,1.)))
                    println(io,"GRID,$(base+j),,$(x+2cell),$y,0.")
                end
                eid=100+2cell
                if iseven(cell)
                    println(io,"CQUAD4,$eid,1,$(base+1),$(base+2),$(base+3),$(base+4)")
                else
                    println(io,"CTRIA3,$eid,1,$(base+1),$(base+2),$(base+3)")
                    println(io,"CTRIA3,$(eid+1),1,$(base+1),$(base+3),$(base+4)")
                end
            end
            println(io,"ENDDATA")
        end
        model=OpenJFEM.bdf_to_model(path)
        assembly=S.assemble_stiffness(model;membrane_incomp=true,sol101_context=true)
        _,ids,xyz,ndof,node_R,_,rbe,normals=assembly[1:8]
        u=1e-4sin.(collect(1.:ndof))
        expected=Set(parse(Int,string(k)) for k in keys(model["CSHELLs"]))
        plain=S.assemble_geometric_stiffness(model,ids,xyz,node_R,ndof,u,normals,rbe)
        for _ in 1:3
            captured=Dict{Int,Any}()
            calls=Int[]
            active=Threads.Atomic{Int}(0)
            peak=Threads.Atomic{Int}(0)
            function capture(eid,data)
                running=Threads.atomic_add!(active,1)+1
                Threads.atomic_max!(peak,running)
                try
                    # Force overlapping callback attempts in threaded assembly.
                    # Callers may retain data in an ordinary Dict without locks.
                    sleep(.001)
                    push!(calls,eid)
                    captured[eid]=data[:n]==4 ?
                        (dofs=copy(data[:dofs_buf24]),matrix=copy(data[:Kg_global])) :
                        (dofs=copy(data[:dofs_t3]),matrix=copy(data[:Kg18]))
                finally
                    Threads.atomic_sub!(active,1)
                end
            end
            actual=S.assemble_geometric_stiffness(model,ids,xyz,node_R,ndof,u,normals,rbe;geometric_capture=capture)
            @test peak[]==1
            @test active[]==0
            @test Set(calls)==expected
            @test length(calls)==length(expected)
            @test Set(keys(captured))==expected
            @test actual==plain
            reconstructed=zeros(ndof,ndof)
            for item in values(captured)
                reconstructed[item.dofs,item.dofs]+=item.matrix
            end
            @test reconstructed≈Matrix(actual) rtol=2e-14
        end
    end
end
end

@testset "Geometric capture retains every shell under threaded assembly" begin
    GeometricCaptureThreadSafetyFixture.checks()
end
