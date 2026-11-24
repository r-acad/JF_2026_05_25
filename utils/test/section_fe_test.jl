# julia --project=. --startup-file=no utils/test/section_fe_test.jl
#
# Finite-element conversion of beam sections (src/parsing/section_fe.jl) and the sliver bound of
# the CTRIA3 residual bending flexibility, against values of the reference solver.
# The reference numbers are those of its message 4379 ("... ARE REPLACED BY THE FOLLOWING PBAR
# ENTRIES. CONVERSION METHOD ... FINITE ELEMENT METHOD", five digits) and of its displacement
# output (seven digits) for single-element decks.
using Test, LinearAlgebra, OpenJFEM
const P = OpenJFEM.ReferenceParser

# section, dimensions, A, I1, I2, J and, where the reference prints them, K1 and K2
const LIBRARY = [
    ("T", [0.04, 0.05, 0.004, 0.003], 2.9800e-4, 7.0856e-8, 2.1437e-8, 1.2508e-9, 0.40913, 0.45948),
    ("T1", [0.05, 0.04, 0.004, 0.003], 3.2000e-4, 4.1757e-8, 5.2567e-8, 1.4108e-9, nothing, nothing),
    ("T2", [0.04, 0.05, 0.004, 0.003], 2.9800e-4, 7.0856e-8, 2.1437e-8, 1.2515e-9, nothing, nothing),
    ("BAR", [0.01, 0.01], 1.0000e-4, 8.3333e-10, 8.3333e-10, 1.4064e-9, nothing, nothing),
    ("BAR", [0.02, 0.01], 2.0000e-4, 1.6667e-9, 6.6667e-9, 4.5761e-9, nothing, nothing),
    ("BAR", [0.2, 0.01], 2.0000e-3, 1.6667e-8, 6.6667e-6, 6.4741e-8, nothing, nothing),
    ("ROD", [0.01], 3.1416e-4, 7.8540e-9, 7.8540e-9, 1.5708e-8, nothing, nothing),
    ("TUBE", [0.02, 0.018], 2.3876e-4, 4.3216e-8, 4.3216e-8, 8.6431e-8, nothing, nothing),
    ("TUBE2", [0.02, 0.002], 2.3876e-4, 4.3216e-8, 4.3216e-8, 8.6431e-8, nothing, nothing),
    ("BOX", [0.06, 0.04, 0.003, 0.003], 5.6400e-4, 1.4313e-7, 2.7385e-7, 2.9296e-7, nothing, nothing),
    ("BOX", [0.03, 0.03, 0.008, 0.008], 7.0400e-4, 6.4299e-8, 6.4299e-8, 1.0676e-7, nothing, nothing),
    ("BOX1", [0.06, 0.04, 0.003, 0.004, 0.002, 0.005], 6.5100e-4, 1.5967e-7, 2.9608e-7, 3.0319e-7, nothing, nothing),
    ("I", [0.08, 0.05, 0.05, 0.003, 0.004, 0.004], 6.1600e-4, 6.7145e-7, 8.3495e-8, 2.7791e-9, nothing, nothing),
    ("I", [0.04, 0.04, 0.04, 0.012, 0.01, 0.01], 1.0400e-3, 1.9467e-7, 1.0955e-7, 4.2782e-8, nothing, nothing),
    ("I1", [0.04, 0.004, 0.05, 0.06], 6.4000e-4, 3.7533e-7, 7.1253e-8, 4.7373e-9, nothing, nothing),
    ("CHAN", [0.03, 0.06, 0.003, 0.004], 3.9600e-4, 2.2363e-7, 3.5348e-8, 1.6903e-9, 0.37478, 0.36324),
    ("CHAN1", [0.03, 0.003, 0.05, 0.058], 4.1400e-4, 2.2406e-7, 4.5592e-8, 1.8010e-9, nothing, nothing),
    ("CHAN2", [0.002, 0.002, 0.025, 0.0745], nothing, nothing, nothing, 3.2206e-10, nothing, nothing),
    ("Z", [0.03, 0.003, 0.05, 0.056], 3.4800e-4, 1.7044e-7, 6.2631e-8, 1.0441e-9, 0.42960, 0.46098),
    ("L", [0.05, 0.05, 0.004, 0.004], 3.8400e-4, 9.2608e-8, 9.2608e-8, 2.0203e-9, 0.43020, 0.43020),
    ("H", [0.04, 0.008, 0.05, 0.004], 5.6000e-4, 8.3547e-8, 2.1547e-7, 3.0557e-9, nothing, nothing),
    ("CROSS", [0.04, 0.004, 0.06, 0.004], 4.0000e-4, 7.2213e-8, 2.8693e-8, 2.2085e-9, nothing, nothing),
    ("HAT", [0.04, 0.003, 0.05, 0.02], 4.9200e-4, 1.1834e-7, 3.0502e-7, 1.4926e-9, nothing, nothing),
    ("HEXA", [0.01, 0.04, 0.03], 9.0000e-4, 5.6250e-8, 7.5000e-8, 1.2325e-7, nothing, nothing),
]

@testset "Library sections converted by finite elements" begin
    for (type, dims, A, I1, I2, J, K1, K2) in LIBRARY
        p = P.section_library_properties(type, dims)
        A === nothing || @test p.A ≈ A rtol = 1e-4
        I1 === nothing || @test p.I1 ≈ I1 rtol = 1e-4
        I2 === nothing || @test p.I2 ≈ I2 rtol = 1e-4
        # The torsion constant carries the discretisation of the section mesh; the reference's
        # interior mesh is not reproduced, which leaves up to 0.45 % on the measured sections.
        @test p.J ≈ J rtol = 5e-3
        K1 === nothing || @test p.K1 ≈ K1 rtol = 1e-2
        K2 === nothing || @test p.K2 ≈ K2 rtol = 1e-2
        # the same shape at another size: areas scale with the square, inertias with the fourth power
        # (to the round-off of the normalised dimensions, which can move a mesh point slightly)
        q = P.section_library_properties(type, 1000 .* dims)
        @test q.A ≈ 1e6 * p.A rtol = 1e-10
        @test q.J ≈ 1e12 * p.J rtol = 1e-6
        @test q.K1 ≈ p.K1 rtol = 1e-6
    end
    # shear factors have no Poisson coupling: 6/7 for a circle, 5/6 for a rectangle
    @test P.section_library_properties("ROD", [0.01]).K1 ≈ 6 / 7 rtol = 1e-3
    @test P.section_library_properties("BAR", [0.02, 0.03]).K1 ≈ 5 / 6 rtol = 1e-3
    @test P.section_library_properties("DBOX", ones(10)) === nothing
    @test_throws ArgumentError P.section_library_properties("T", [0.04, 0.05, 0.06, 0.003])
    @test_throws ArgumentError P.section_library_properties("BOX", [0.06, 0.04, 0.03, 0.003])
end

@testset "Products of inertia, shear centres and warping constants" begin
    z = P.section_library_properties("Z", [0.03, 0.003, 0.05, 0.056])
    @test z.I12 ≈ -7.8705e-8 rtol = 1e-4
    @test z.N1 == 0 && z.N2 == 0                         # point symmetry: shear centre at the centroid
    @test z.CW ≈ 2.6034e-11 rtol = 2e-3
    l = P.section_library_properties("L", [0.05, 0.05, 0.004, 0.004])
    @test l.I12 ≈ -5.5104e-8 rtol = 1e-4
    @test l.N1 ≈ 1.1884e-2 rtol = 1e-3
    @test l.N2 ≈ 1.1884e-2 rtol = 1e-3
    @test l.CW ≈ 3.8880e-13 rtol = 2e-3
    t = P.section_library_properties("T", [0.04, 0.05, 0.004, 0.003])
    @test t.N1 ≈ -1.1379e-2 rtol = 1e-3
    @test t.N2 == 0 && t.I12 == 0                        # mirror symmetry
    @test t.CW ≈ 1.0913e-13 rtol = 2e-3
    c = P.section_library_properties("CHAN", [0.03, 0.06, 0.003, 0.004])
    @test c.N1 == 0 && c.I12 == 0
    @test c.N2 ≈ 1.9439e-2 rtol = 1e-3
    @test c.CW ≈ 1.9661e-11 rtol = 2e-3
    i = P.section_library_properties("I", [0.08, 0.06, 0.03, 0.004, 0.006, 0.003])
    @test i.N1 ≈ 1.9528e-2 rtol = 1e-3
    @test i.CW ≈ 3.6825e-11 rtol = 2e-3
    b = P.section_library_properties("BAR", [0.02, 0.03])
    @test b.N1 == 0 && b.N2 == 0 && b.I12 == 0
end

@testset "Section mesh follows the measured boundary subdivision" begin
    # edges on each straight segment of four sections whose meshes the reference exported
    counts(type, dims) = begin
        nodes, tri, _ = P.section_mesh(P.section_library_loops(type, dims))
        boundary = Dict{Tuple{Int,Int},Int}()
        for t in tri, (a, b) in ((t[1], t[2]), (t[2], t[3]), (t[3], t[1]))
            k = (min(a, b), max(a, b)); boundary[k] = get(boundary, k, 0) + 1
        end
        count(==(1), values(boundary))
    end
    @test counts("BAR", [0.01, 0.01]) == 32             # 8 on each side
    @test counts("BAR", [0.04, 0.01]) == 40             # 16 and 4
    @test counts("BAR", [0.2, 0.01]) == 66              # 32 and 1
    @test counts("T", [0.04, 0.05, 0.004, 0.003]) == 79 # with two levels at the re-entrant corners
    @test counts("L", [0.05, 0.05, 0.004, 0.004]) == 72
end

@testset "PBARL, PBEAML and PBRSECT use the conversion; TWBRBML=1 the library equations" begin
    card(kind, type, dims...) = Any["SMALL", kind, 1, 1, "", type, dims...]
    bar = P.extract_pbarl([card("PBARL", "T", 0.04, 0.05, 0.004, 0.003)])["1"]
    @test bar["SECTION_METHOD"] == "finite_element"
    @test bar["J"] ≈ 1.2508e-9 rtol = 5e-3
    @test bar["I12"] == 0
    @test !haskey(bar, "N1A")                             # a bar has no shear-centre offset
    beam = P.extract_pbeaml([vcat(card("PBEAML", "L"), fill("", 4), [0.05, 0.05, 0.004, 0.004])])["1"]
    @test beam["N1A"] ≈ 1.1884e-2 rtol = 1e-3
    @test beam["N2B"] ≈ 1.1884e-2 rtol = 1e-3
    @test beam["I12"] ≈ -5.5104e-8 rtol = 1e-4
    legacy = P.extract_pbarl([card("PBARL", "T", 0.04, 0.05, 0.004, 0.003)]; twbrbml=1)["1"]
    @test legacy["SECTION_METHOD"] == "library_equations"
    @test legacy["J"] ≈ 1.2853e-9 rtol = 5e-5
    # a general section with the outline of the same T, and one with a hole
    deck = ["BEGIN BULK", "PBRSECT        1       1      GS", "        OUTP=10", "SET1          10     101    THRU     108",
        "POINT,101,,-.0015,0.", "POINT,102,,.0015,0.", "POINT,103,,.0015,.046", "POINT,104,,.02,.046", "POINT,105,,.02,.05",
        "POINT,106,,-.02,.05", "POINT,107,,-.02,.046", "POINT,108,,-.0015,.046", "ENDDATA"]
    _, bulk = P.read_bulk_and_case(deck); cards = P.process_cards(bulk)
    general = P.extract_pbrsect(cards["PBRSECT"], cards["POINT"], cards["SET1"])["1"]
    @test general["A"] ≈ 2.98e-4 rtol = 1e-12
    @test general["I1"] ≈ 7.0856e-8 rtol = 1e-4       # the second POINT coordinate is the element y
    @test general["J"] ≈ 1.2514e-9 rtol = 5e-3
    @test general["J"] ≈ bar["J"] rtol = 1e-8
    box = ["BEGIN BULK", "PBRSECT        2       1      GS", "        OUTP=20,INP=21", "SET1,20,201,THRU,204", "SET1,21,211,THRU,214",
        "POINT,201,,-.03,-.02", "POINT,202,,.03,-.02", "POINT,203,,.03,.02", "POINT,204,,-.03,.02",
        "POINT,211,,-.027,-.017", "POINT,212,,.027,-.017", "POINT,213,,.027,.017", "POINT,214,,-.027,.017", "ENDDATA"]
    _, bulk = P.read_bulk_and_case(box); cards = P.process_cards(bulk)
    hollow = P.extract_pbrsect(cards["PBRSECT"], cards["POINT"], cards["SET1"])["2"]
    @test hollow["A"] ≈ 5.64e-4 rtol = 1e-12
    @test hollow["J"] ≈ 2.9296e-7 rtol = 5e-3
    @test_throws ArgumentError P.extract_pbrsect([Any["SMALL", "PBRSECT", 1, 1, "OP", "", "", "", "", "", "OUTP=10"]], cards["POINT"], cards["SET1"])
end

@testset "Sliver CTRIA3: second residual flexibility bounded at 1/10000 of the first" begin
    # One triangle clamped along its unit base, normal force at the apex. Deflection of the apex.
    function apex(height, position, thickness)
        deck = joinpath(mktempdir(), "sliver.bdf")
        write(deck, """
SOL 101
CEND
DISPLACEMENT = ALL
SUBCASE 1
  SPC = 1
  LOAD = 1
BEGIN BULK
PARAM,AUTOSPC,YES
PARAM,EPZERO,.001
PARAM,K6ROT,1.
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,$position,$height,0.
CTRIA3,1,1,1,2,3
PSHELL,1,1,$thickness,1,,1
MAT1,1,7.+10,,.33,2700.
FORCE,1,3,,1.,0.,0.,1.
SPC1,1,123456,1,2
ENDDATA
""")
        result = redirect_stdout(devnull) do
            OpenJFEM.solve_model(OpenJFEM.bdf_to_model(deck))
        end
        first(d for d in first(result["subcases"])["displacements"] if d["grid_id"] == 3)["t3"]
    end
    @test apex(0.05, 0.5, 0.003) ≈ 4.730020e-7 rtol = 1e-5     # ordinary shape: the bound is inactive
    @test apex(0.005, 0.5, 0.003) ≈ 8.592222e-10 rtol = 1e-5
    @test apex(0.0005, 0.5, 0.003) ≈ 5.091470e-11 rtol = 1e-5
    @test apex(0.005, 0.05, 0.003) ≈ 9.301650e-10 rtol = 1e-5
    @test apex(0.005, 0.95, 0.003) ≈ 9.301650e-10 rtol = 1e-5   # mirror image
    @test apex(0.005, 0.5, 0.03) ≈ 1.590722e-11 rtol = 1e-5
    @test apex(0.005, 0.5, 0.0003) ≈ 7.087420e-7 rtol = 1e-5
end
