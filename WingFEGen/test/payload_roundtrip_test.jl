# Stored physical results must preserve MessagePack bin tags through HTTP.
# julia --project=WingFEGen WingFEGen/test/payload_roundtrip_test.jl
using Test
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
@testset "Viewport binary payload round trip" begin
    values=Float32[0.,1.25,-.03125,Inf]
    payload=Dict{String,Any}("static"=>Dict("disp"=>W.blob_f32(values),"rotation"=>W.blob_f32(zeros(4))),
        "nested"=>Any[Dict("ids"=>W.blob_i32([101,900,40000001]))],
        "empty_binary"=>W.Blob(UInt8[]),"ordinary"=>Any[0,1,127,255],"empty_array"=>Any[],
        "name"=>"Native baseline","available"=>true)
    original=W.MsgPack.pack(payload)
    decoded=W.unpack_view_payload(original)
    @test decoded["static"]["disp"] isa W.Blob
    @test decoded["empty_binary"] isa W.Blob
    @test decoded["ordinary"] isa Vector{Any}
    @test decoded["empty_array"] isa Vector{Any}
    response=W.msgpack_response(decoded)
    @test response.status==200
    wire=W.MsgPack.unpack(response.body)
    @test wire["static"]["disp"] isa Vector{UInt8}
    @test length(wire["static"]["disp"])==4length(values)
    @test reinterpret(Float32,wire["static"]["disp"])==values
    @test reinterpret(Int32,wire["nested"][1]["ids"])==[101,900,40000001]
    @test wire["empty_binary"] isa Vector{UInt8}
    @test wire["empty_array"] isa Vector{Any}
    @test wire["ordinary"] isa Vector{Any}
    @test wire["ordinary"]==[0,1,127,255]
    @test wire["name"]=="Native baseline"&&wire["available"]
    second=W.MsgPack.unpack(W.msgpack_response(W.unpack_view_payload(response.body)).body)
    @test second["static"]["disp"] isa Vector{UInt8}
    @test second["ordinary"] isa Vector{Any}
    @test second==wire
end
