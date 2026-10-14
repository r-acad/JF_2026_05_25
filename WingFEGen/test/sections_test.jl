using Test
include(joinpath(@__DIR__, "..", "src", "WingFEGen.jl"))
using .WingFEGen
const W = WingFEGen

# Exercise the real, unmodified JFEM parser against complete generator decks.
repo,_=W.find_jfem(dirname(@__DIR__))
include(joinpath(repo,"src","parsing","ReferenceParser.jl"))
const N = ReferenceParser

function polygon_integrals(poly)
    a = my = mz = iy = iz = 0.0
    for i in eachindex(poly)
        y, z = poly[i]
        yn, zn = poly[mod1(i + 1, length(poly))]
        c = y * zn - yn * z
        a += c / 2
        my += (y + yn) * c / 6
        mz += (z + zn) * c / 6
        iy += (y^2 + y*yn + yn^2) * c / 12
        iz += (z^2 + z*zn + zn^2) * c / 12
    end
    return abs(a), my/a, mz/a, abs(iy), abs(iz)
end

@testset "Dimension-defined PBARL sections" begin
    @testset "Area, centroid, bending inertia, placement" begin
        for (b,h,tf,tw,side) in ((.030,.032,.002,.002,.020),
                (.055,.050,.004,.003,.028), (.020,.018,.0015,.001,.011))
            p = W.default_params()
            for (key,value) in zip(W.STRINGER_DIMENSION_KEYS, (b,h,tf,tw))
                p[key] = value
            end
            p["properties.spar_cap_side"] = side
            for pid in (W.PID_STRINGER, W.PID_SPAR_CAP, W.PID_STRINGER_RUNOUT)
                s = W.section_definition(p, pid)
                area, cy, cz, i1, i2 = polygon_integrals(s["polygon_yz_m"])
                @test area ≈ s["area_m2"] rtol=1e-12
                @test cy ≈ 0 atol=1e-15
                @test cz ≈ 0 atol=1e-15
                @test i1 ≈ s["I1_m4"] rtol=1e-12
                @test i2 ≈ s["I2_m4"] rtol=1e-12
                @test s["J_m4"] > 0
                if pid != W.PID_STRINGER_RUNOUT
                    ys = [v[1] + s["offset_y_m"] for v in s["polygon_yz_m"]]
                    @test maximum(ys) ≈ 0 atol=1e-15
                    @test minimum(ys) ≈ -(pid == W.PID_STRINGER ? h : side)
                end
            end
        end
    end

    @testset "Legacy migration and parameter validation" begin
        p, unknown = W.normalize_params(Dict("properties.a_stringer" => 4.8e-4,
            "properties.a_spar_cap" => 9e-4, "properties.i_stringer" => 0.0))
        @test isempty(unknown)
        @test W.section_definition(p,W.PID_STRINGER)["area_m2"] ≈ 4.8e-4
        @test p["properties.stringer_flange_width"] ≈ .060
        @test p["properties.spar_cap_side"] ≈ .030
        @test length(p["section_migration_notes"]) == 2
        @test_throws ArgumentError W.normalize_params(Dict("properties.i_stringer"=>1e-7))
        @test_throws ArgumentError W.normalize_params(Dict("properties.a_spar_cap"=>-1.0))
        @test_throws ArgumentError W.normalize_params(Dict("properties.a_stringer"=>4.8e-4,
            "properties.stringer_flange_width"=>.030))
        @test_throws ArgumentError W.normalize_params(Dict("properties.stringer_height"=>.001))
        @test_throws ArgumentError W.normalize_params(Dict("properties.stringer_web_thickness"=>.031))
        @test_throws ArgumentError W.normalize_params(Dict("properties.spar_cap_side"=>0))
        reread, unknown = W.normalize_params(W.flatten_toml(W.TOML.parse(W.params_to_toml(p))))
        @test isempty(unknown)
        for key in W.STRINGER_DIMENSION_KEYS
            @test reread[key] == p[key]
        end
        @test all(!haskey(W.SCHEMA_BY_KEY, key) for key in W.LEGACY_SECTION_KEYS)
    end

    @testset "Actual deck parse and oriented centroid offsets" begin
        for angle in (-8.0, 0.0, 8.0)
            p = W.default_params()
            p["box.stringer_angle"] = angle
            p["box.rib_pitch"] = 1.0
            p["mesh.elements_between_ribs"] = 2
            m = W.build_model(p)
            if !isempty(ARGS)&&angle==0.0
                out=abspath(ARGS[1]);mkpath(out)
                write(joinpath(out,"schema.json"),W.JSON.json(W.schema_payload(m.params,"synthetic-project.toml")))
                write(joinpath(out,"payload.msgpack"),W.MsgPack.pack(W.mesh_payload(m)))
            end
            deck = sprint(W.write_deck, m)
            _, bulk = N.read_bulk_and_case(String.(split(deck, '\n')))
            cards = N.process_cards(bulk)
            props = N.extract_pbarl(cards["PBARL"])
            expected=Set(gr.pid for gr in m.groups if gr.kind===:bar&&gr.pid!=W.PID_STRINGER_RUNOUT)
            @test Set(keys(props)) == Set(string.(collect(expected)))
            for pid in expected
                s, actual = W.section_definition(p,pid), props[string(pid)]
                @test actual["TYPE"] == s["shape"]
                @test actual["DIMS"] ≈ s["dimensions_m"]
                for (key,pk) in (("area_m2","A"),("I1_m4","I1"),("I2_m4","I2"),("J_m4","J"))
                    @test s[key] ≈ actual[pk] rtol=1e-12
                end
            end
            runout = N.extract_pbar(cards["PBAR"])
            @test length(runout) == 1
            @test runout[string(W.PID_STRINGER_RUNOUT)]["A"] == 5e-6
            # The eight-column PBAR writer rounds 2.083333e-12 to 2.083e-12.
            # Exact section geometry is checked above; allow that deck precision here.
            for key in ("I1","I2")
                @test runout[string(W.PID_STRINGER_RUNOUT)][key] ≈ (5e-6)^2/12 rtol=2e-4
            end
            @test runout[string(W.PID_STRINGER_RUNOUT)]["J"] ≈ .1406*(5e-6)^2 rtol=2e-5
            bars = N.extract_cbar(cards["CBAR"])
            for gr in m.groups
                gr.kind === :bar || continue
                section = W.section_definition(p,gr.pid)
                for e in eachindex(gr.eids)
                    actual = bars[string(gr.eids[e])]
                    offset = W.bar_section_offset(m,gr,e)
                    a,b = gr.conn[2*e-1],gr.conn[2*e]
                    tangent = W.unit3(Tuple(m.xyz[3b-2:3b]) .- Tuple(m.xyz[3a-2:3a]))
                    # Eight-column decimal formatting has a 5 micrometre
                    # rounding bound for negative centimetre-scale offsets.
                    @test all(abs.(actual["WA"] .- collect(offset)) .<= 5.1e-6)
                    @test all(abs.(actual["WB"] .- collect(offset)) .<= 5.1e-6)
                    @test actual["PA"] == actual["PB"] == 0
                    @test abs(sum(offset .* tangent)) < 1e-14
                    @test W.norm3(offset) ≈ abs(section["offset_y_m"]) atol=1e-14
                    if gr.pid != W.PID_STRINGER_RUNOUT
                        v = Tuple(gr.orient[3*e-2:3*e])
                        @test sum(offset .* v) < 0  # upper AND lower skins point inward
                    end
                end
            end
        end
    end
end
