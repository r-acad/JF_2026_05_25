using Test, OpenJFEM, LinearAlgebra, Printf

function shell_frame_rigid_model(path, triangles, rotate)
    points = [0. 0. 0.; 2. 0. 0.; 2. 1. 0.; 0. 1. 0.; 1. 0.5 0.]
    angle = rotate ? 0.61 : 0.
    axis = normalize([0.2,0.5,0.7])
    skew = [0. -axis[3] axis[2]; axis[3] 0. -axis[1]; -axis[2] axis[1] 0.]
    Q = Matrix{Float64}(I,3,3) + sin(angle)*skew + (1-cos(angle))*skew*skew
    points = points*Q'
    orientation = Q*[0.,0.,1.]
    open(path,"w") do io
        println(io,"SOL 101\nCEND\nSUBCASE 1\n SPC = 1\nBEGIN BULK\nPARAM,K6ROT,100.")
        for i in axes(points,1)
            @printf(io,"GRID,%d,,%.12g,%.12g,%.12g\n",i,points[i,1],points[i,2],points[i,3])
        end
        println(io,"MAT1,1,7.0E10,,0.3,2700.\nPSHELL,1,1,0.004,1,,1")
        if triangles
            println(io,"CTRIA3,1,1,1,2,3\nCTRIA3,2,1,1,3,4")
        else
            println(io,"CQUAD4,1,1,1,2,3,4")
        end
        println(io,"PBAR,2,1,0.001,1.0E-6,2.0E-6,3.0E-6")
        @printf(io,"CBAR,10,2,1,2,%.12g,%.12g,%.12g\n",orientation...)
        # A reference grid exercises the mixed shell/frame/MPC route. No
        # constraints are applied to K during assembly: rigid motions must
        # carry zero energy regardless of the later support selection.
        println(io,"RBE3,100,,5,123456,1.,123,1,2\n+,3,4\nSPC1,1,123456,1,4\nENDDATA")
    end
    return OpenJFEM.bdf_to_model(path)
end

function shell_frame_rigid_vectors(id_map, X)
    rigid=zeros(6length(id_map),6)
    for (_,i) in id_map
        b=6(i-1)
        for j in 1:3
            unit=Float64.(collect(1:3).==j)
            rigid[b+1:b+3,j]=unit
            rigid[b+1:b+3,j+3]=cross(unit,vec(X[i,:]))
            rigid[b+4:b+6,j+3]=unit
        end
    end
    return rigid
end

@testset "Shells sharing frame nodes preserve rigid motions in SOL101" begin
    withenv("JFEM_SOL101_LINE_NODE_DRILL_SCALE"=>nothing) do
        mktempdir() do dir
            for triangles in (false,true), rotate in (false,true)
                model=shell_frame_rigid_model(joinpath(dir,"shell_frame.bdf"),triangles,rotate)
                K,id_map,X,_=OpenJFEM.Solver.assemble_stiffness(deepcopy(model);sol101_context=true)
                rigid=shell_frame_rigid_vectors(id_map,X)
                for j in 1:6
                    @test norm(K*rigid[:,j]) <= 1e-13*norm(K)*norm(rigid[:,j])
                end
                # One physical shell/frame elastic operator is independent
                # of whether it is used for linear static or preload work.
                Kpreload=first(OpenJFEM.Solver.assemble_stiffness(deepcopy(model);sol105_context=true))
                @test K == Kpreload
                @test norm(K-K') <= 1e-14*norm(K)
            end
        end
    end
end
