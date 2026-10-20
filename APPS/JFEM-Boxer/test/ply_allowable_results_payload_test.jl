using Test, WingFEGen, OpenJFEM
const W = WingFEGen

@testset "Material allowable result fields retain ply axes and source values" begin
    mktempdir() do directory
        deck="SOL 105\nCEND\nBEGIN BULK\nGRID,1,,0.,0.,0.\nGRID,2,,1.,0.,0.\nGRID,3,,1.,1.,0.\nGRID,4,,0.,1.,0.\nCQUAD4,10,20,1,2,3,4,30.\nMAT8,2,1.35E11,8.5E9,.27,4.8E9,5.1E9,3.2E9,1600.\nPCOMP,20,-.001\n+,2,.002,45.,YES\nENDDATA\n"
        path=joinpath(directory,"laminate.bdf");write(path,deck)
        native=OpenJFEM.bdf_to_model(path)
        m=W.imported_model(native,Dict("kind"=>"reference","name"=>"laminate.bdf","text"=>deck),W.default_params())
        face=Dict{String,Any}("ply"=>1,"material_id"=>2,"material_type"=>"MAT8","angle_deg"=>45.,"z_bottom"=>-.001,"z_top"=>.001,
            "bottom"=>Dict("e1"=>-.002,"e2"=>.001,"g12"=>.003),"top"=>Dict("e1"=>.004,"e2"=>-.001,"g12"=>.002))
        row=Dict{String,Any}("eid"=>10,"z1"=>Dict("normal_x"=>.001,"normal_y"=>.002,"shear_xy"=>.003,"fiber_dist"=>0.),
            "z2"=>Dict("normal_x"=>-.1,"normal_y"=>.2,"shear_xy"=>.3,"fiber_dist"=>-1.),
            "ply_faces"=>[face],"ply_faces_complete"=>true,"ply_faces_coordinate_system"=>"ply material 1/2 axes")
        raw=Dict{String,Any}("analysis_type"=>"SOL101_STATIC","strains"=>Dict("quad4"=>[row]))
        contours,records=W.element_results_payload(m,raw)
        @test isempty(contours)
        @test records["10"]["strain"]["ply_faces"]==[face]
        @test records["10"]["strain"]["ply_faces_complete"]
        @test occursin("Engineering",records["10"]["strain_units"])
        @test !haskey(records["10"],"stress_units")
        records["10"]["strain"]["ply_faces"][1]["top"]["e1"]=100.
        @test face["top"]["e1"]==.004
        scaled=W.scaled_linear_result(raw,.5)
        @test scaled["strains"]["quad4"][1]["ply_faces"][1]["top"]["e1"]==.002
        @test scaled["strains"]["quad4"][1]["ply_faces"][1]["z_top"]==.001
        @test scaled["strains"]["quad4"][1]["ply_faces"][1]["angle_deg"]==45.
        # Legacy generalized strains rotate with engineering shear; already
        # explicit material ply axes must not receive a second rotation.
        data=deepcopy(row);W.rotate_shell_results!(data,"strain",sqrt(.5),sqrt(.5))
        @test data["z1"]["normal_x"]≈.003
        @test data["z1"]["normal_y"]≈0. atol=1e-16
        @test data["z1"]["shear_xy"]≈.001
        @test data["ply_faces"]==row["ply_faces"]
        job=W.JfemJob("ply-test","",path,directory,joinpath(directory,"log"),"",m,nothing,String[],ReentrantLock(),0.,0.,:done,0,"")
        payload=W.jfem_case_results_payload(job,"fixture.JU.JSON",raw)
        @test payload["element_results"]["10"]["strain"]["ply_faces_complete"]
        @test payload["mode_kind"]=="none"
    end
end
