# ===========================================================================
#  params.jl - parameter schema, input file reading, validation
#
#  The schema below is the single source of truth for the input parameters.
#  The TOML input file, the validation rules and the browser form are all
#  driven from it, so a parameter added here appears in the web app with no
#  further work.
# ===========================================================================

"""
    ParamSpec

Description of one input parameter. `key` is the dotted TOML path, for example
`"planform.area"`. `kind` is one of `:float`, `:int`, `:bool`, `:string` or
`:choice`, `:loadcases`, `:planformpoints`, or a specialized table such as
`:supportsets`.
"""
struct ParamSpec
    key::String
    label::String
    kind::Symbol
    default::Any
    group::String
    unit::String
    help::String
    choices::Vector{String}
end

function ParamSpec(key, label, kind, default, group; unit = "", help = "",
                   choices = String[])
    return ParamSpec(key, label, kind, default, group, unit, help, choices)
end

const LOAD_MULTIPLIER_NOTE = "Dimensionless multiplier applied once to prescribed lift, VLM forces and moments, and prescribed torque. A value of 1.5 converts limit loads to ultimate only when the defined case already represents limit loads; it is not an additional n-g conversion."

const SCHEMA = ParamSpec[
    # --- airfoils ----------------------------------------------------------
    ParamSpec("airfoil.root_source", "Root profile source", :choice, "naca", "Airfoils"; choices=["naca","uiuc"], help="Generate a NACA profile or choose UIUC database coordinates"),
    ParamSpec("airfoil.root", "Root airfoil", :string, "NACA2412", "Airfoils";
              help = "NACA 4- or 5-digit code, e.g. NACA2412 or NACA23012"),
    ParamSpec("airfoil.root_profile", "Embedded root profile", :string, "", "Airfoils"; help="UIUC coordinates and provenance, stored with the model for offline use"),
    ParamSpec("airfoil.tip_source", "Tip profile source", :choice, "naca", "Airfoils"; choices=["naca","uiuc"], help="Generate a NACA profile or choose UIUC database coordinates"),
    ParamSpec("airfoil.tip", "Tip airfoil", :string, "NACA2410", "Airfoils";
              help = "NACA 4- or 5-digit code at the tip section"),
    ParamSpec("airfoil.tip_profile", "Embedded tip profile", :string, "", "Airfoils"; help="UIUC coordinates and provenance, stored with the model for offline use"),
    ParamSpec("airfoil.stations", "Intermediate airfoils", :airfoilstations, Any[], "Airfoils";
              help="Sections at ETA strictly between root (0) and tip (1), with NACA codes or embedded UIUC profiles"),
    ParamSpec("airfoil.interpolation", "Spanwise interpolation", :choice, "cosine", "Airfoils";
              choices=["cosine","linear"], help="Cosine blends adjacent sections with (1-cos(pi*t))/2 for smooth station transitions; linear preserves the legacy loft"),
    ParamSpec("airfoil.n_points", "Section points", :int, 121, "Airfoils";
              help = "NACA generating points per surface, cosine spaced; database profiles retain their coordinate tables"),
    ParamSpec("airfoil.closed_trailing_edge", "Closed trailing edge", :bool, true,
              "Airfoils"; help = "Use the NACA closed-TE coefficient; database profiles retain their original trailing-edge gap"),

    # --- planform ----------------------------------------------------------
    ParamSpec("planform.area", "Base wing area", :float, 16.0, "Planform";
              unit = "m2", help = "Projected area of the full base trapezoid. Perturbation points change the actual area reported with the mesh"),
    ParamSpec("planform.aspect_ratio", "Base aspect ratio", :float, 8.0, "Planform";
              help = "b^2 / S of the full base trapezoid; together with base area fixes the span"),
    ParamSpec("planform.taper_ratio", "Base taper ratio", :float, 0.45, "Planform";
              help = "c_tip / c_root of the base trapezoid, before edge perturbations"),
    ParamSpec("planform.twist_tip", "Tip twist", :float, -3.0, "Planform";
              unit = "deg", help = "Linear from zero at the root. Positive is nose up"),
    ParamSpec("planform.sweep", "Sweep", :float, 15.0, "Planform";
              unit = "deg", help = "Sweep of the BASE trapezoid datum at the reference x/c. Edge perturbations follow this base when sweep changes"),
    ParamSpec("planform.sweep_ref_xc", "Sweep reference", :float, 0.25, "Planform";
              unit = "x/c", help = "Base chord fraction of the swept datum. Structural skins and aerodynamic surfaces share the refined airfoil loft; spar path inputs remain measured in base-trapezoid coordinates"),
    ParamSpec("planform.dihedral", "Dihedral", :float, 5.0, "Planform";
              unit = "deg", help = "Applied to the reference line"),
    ParamSpec("planform.twist_axis_xc", "Twist axis", :float, 0.25, "Planform";
              unit = "x/c", help = "Fraction of the refined chord about which both the aerodynamic surface and structural section are pitched"),
    ParamSpec("planform.root_ref_x", "Root reference x", :float, 0.0, "Planform";
              unit = "m", help = "Global x of the BASE trapezoid reference point at the root. Refined edge points can move the common aerodynamic/structural loft relative to this reference datum"),
    ParamSpec("planform.root_ref_y", "Root reference y", :float, 0.0, "Planform";
              unit = "m", help = "Global y translation of the entire wing, supports and aerodynamic geometry; symmetry remains about the translated root plane"),
    ParamSpec("planform.root_ref_z", "Root reference z", :float, 0.0, "Planform";
              unit = "m", help = "Global z translation of the entire wing, supports and aerodynamic geometry"),
    ParamSpec("planform.leading_edge_points", "Leading-edge perturbation points", :planformpoints, Any[], "Planform";
              help = "Leading-edge eta/dxc perturbations: dxc=0 follows the nominal leading edge; +0.2 moves aft by 20% of the base chord, -0.2 forward. Offsets follow changes to the base trapezoid. Missing endpoints have zero offset. Legacy xc coordinates are migrated on load"),
    ParamSpec("planform.trailing_edge_points", "Trailing-edge perturbation points", :planformpoints, Any[], "Planform";
              help = "Trailing-edge eta/dxc perturbations: dxc=0 follows the nominal trailing edge, positive moves aft and negative forward by that fraction of the base chord. Missing endpoints have zero offset. The refined chord must contain both spars throughout the modeled box"),

    # --- torsion box -------------------------------------------------------
    ParamSpec("box.front_spar_xc", "Front spar", :float, 0.20, "Torsion box";
              unit = "x/c", help = "Nominal front spar location in the BASE trapezoid chord. Every front spar perturbation is an offset from this value and follows changes to it"),
    ParamSpec("box.rear_spar_xc", "Rear spar", :float, 0.55, "Torsion box";
              unit = "x/c", help = "Nominal rear spar location in the BASE trapezoid chord. Every rear spar perturbation is an offset from this value and follows changes to it"),
    ParamSpec("box.front_spar_points", "Front spar perturbation points", :planformpoints, Any[], "Torsion box";
              help = "Front-spar eta/dxc offsets from the nominal Front spar location: zero nominal, positive aft, negative forward in base-chord fractions. Straight segments join the physical points. Missing endpoints use zero offset. Both spars must remain inside the refined wing through End ETA"),
    ParamSpec("box.rear_spar_points", "Rear spar perturbation points", :planformpoints, Any[], "Torsion box";
              help = "Rear-spar eta/dxc offsets from the nominal Rear spar location: zero nominal, positive aft, negative forward in base-chord fractions. Each point has stringer_angle in degrees (default 0) for its incoming segment relative to the rear spar; the final segment repeats the last angle. An eta=0 angle is unused unless it is the only point"),
    ParamSpec("box.end_eta", "End ETA", :float, 0.9, "Torsion box";
              help = "Final closed rib position as a fraction of the full wing semispan (0 < ETA <= 1). Aerodynamics retain the full wing; outboard loads transfer to this rib with their moment arms"),
    ParamSpec("box.rib_pitch", "Root outgoing rib pitch", :float, 0.6, "Ribs";
              unit = "m",
              help = "Target pitch from the root master to the next master. With intermediate masters, pitch is measured along the 3D rear-spar reference path and rounded to whole bays per interval. Without intermediate masters the existing reference-line spacing is preserved"),
    ParamSpec("box.stringer_pitch", "Stringer pitch", :float, 0.150, "Torsion box";
              unit = "m",
              help = "Exact root x-spacing, constant along the span between parallel stringer planes"),
    ParamSpec("box.stringer_angle", "Stringer angle to rear spar", :float, 0.0,
              "Torsion box"; unit = "deg",
              help = "Used only when there are no rear-spar perturbation points: angle relative to the untwisted rear-spar datum, positive aft. With rear-spar points, their individual Stringer angle values define continuous kinked stringer paths and this global value is ignored"),

    ParamSpec("ribs.masters", "Intermediate master ribs", :masterribs, Any[], "Ribs";
              help = "Intermediate masters: ETA at the rear spar, orientation, angle in degrees from the immediately inboard rear-spar segment's outboard tangent toward the nose (90 is perpendicular), and outgoing pitch in metres. Root/final closures are fixed line of flight. Secondary positions and absolute directions interpolate between masters; pitch follows the 3D rear-spar reference path"),

    # --- optional leading-edge structure ----------------------------------
    ParamSpec("leading_edge.enabled", "Create leading-edge structure", :bool, false, "Leading edge";
              help = "Structural skins from the nose to the front spar, between the selected physical ribs. Shares front-spar nodes and includes a closing rib at both ends"),
    ParamSpec("leading_edge.rib_orientation", "Leading-edge rib orientation", :choice, "flight_direction", "Leading edge";
              choices = ["flight_direction", "front_spar_angle"],
              help = "Line of flight keeps the existing constant-span ribs. Front-spar angle uses the same inboard/root spar segment as the reference for every leading-edge rib"),
    ParamSpec("leading_edge.rib_angle", "Rib angle to inboard front spar", :float, 90.0, "Leading edge"; unit = "deg",
              help = "Plan-view angle from the root front-spar segment's outboard tangent toward the nose; 90 degrees is perpendicular. Uses the same reference for all ribs. Rib planes hinge on the existing front-spar nodes. Angled closure ribs must reach the nose inside the wing; choose interior first/last ribs or adjust the angle if a closure would leave the wing"),
    ParamSpec("leading_edge.rib_orientations", "Individual leading-edge rib orientations", :riborientations, Any[], "Leading edge";
              help = "Optional overrides by physical rib number: flight_direction or front_spar_angle and angle in degrees. Unlisted ribs inherit the global leading-edge setting. The common inboard front-spar segment is the angle reference"),
    ParamSpec("leading_edge.start_rib", "First leading-edge rib", :int, 1, "Leading edge";
              help = "Physical rib number at the inboard end; rib 1 is the root. Shell mesh subdivisions do not change the numbering"),
    ParamSpec("leading_edge.end_rib", "Last leading-edge rib", :int, 0, "Leading edge";
              help = "Physical rib number at the outboard end; 0 follows the final box rib at End ETA. Must be beyond the first selected rib"),
    ParamSpec("leading_edge.disabled_bays", "Omit leading-edge bays", :string, "", "Leading edge";
              help = "Physical bay numbers or inclusive ranges, e.g. 2,4-6. Bay b lies between ribs b and b+1. Removes leading-edge structure only in those bays; remaining segments have closing ribs. Empty means no gaps. Valid exclusions outside the selected first/last ribs are retained but ignored; bay bounds are checked when leading-edge structure is enabled"),
    ParamSpec("leading_edge.chord_elements", "Leading-edge chord elements", :int, 8, "Leading edge";
              help = "Elements on each skin between the shared nose and front spar; approximately equal surface arc-length spacing, 2 to 100"),
    ParamSpec("leading_edge.t_skin", "Leading-edge skin thickness", :float, 0.0015, "Leading-edge properties";
              unit = "m", help = "Monolithic thickness of both leading-edge skins; sandwich construction uses its face/core dimensions"),
    ParamSpec("leading_edge.t_rib", "Leading-edge rib thickness", :float, 0.0015, "Leading-edge properties";
              unit = "m", help = "Monolithic thickness of leading-edge rib extensions; sandwich construction uses its face/core dimensions"),

    # --- fuel tank ---------------------------------------------------------
    ParamSpec("fuel.enabled", "Calculate fuel volume", :bool, false, "Fuel tank";
              help = "Gross enclosed volume between selected ribs, skins and spars. Adds a six-DOF fuel RBE3 per bay; Cases defines fuel fill and acceleration. Structure, equipment and unusable fuel are not deducted"),
    ParamSpec("fuel.start_rib", "First tank rib", :int, 1, "Fuel tank";
              help = "Physical rib number, starting with rib 1 at the root; unaffected by shell mesh subdivisions"),
    ParamSpec("fuel.end_rib", "Last tank rib", :int, 0, "Fuel tank";
              help = "Physical rib number; 0 automatically selects the final closed rib at End ETA. Must be beyond the first tank rib"),
    ParamSpec("fuel.disabled_bays", "Dry / vent bays", :string, "", "Fuel tank";
              help = "Bays excluded from fuel capacity, mass, inertia and loads. Bay b is between physical ribs b and b+1. Use numbers or ranges, for example 2,4-6; blank keeps all selected bays. Exclusions outside the selected tank range are retained and ignored. All selected bays may be dry"),
    ParamSpec("fuel.density", "Fuel density", :float, 800.0, "Weights"; unit = "kg/m3",
              help = "Density used for per-bay CONM2 fuel masses and inertia. Edit for the actual fuel and temperature; 800 kg/m3 is an assumption, not a fuel specification"),
    ParamSpec("fuel.fill_fraction", "Fuel fill fraction", :float, 1.0, "Weights"; unit = "0 to 1",
              help = "Legacy input retained for compatibility. New Studies define Fuel status separately in every load case; a legacy file without that setting inherits this fraction"),

    # --- mesh --------------------------------------------------------------
    ParamSpec("mesh.elements_between_ribs", "Elements per rib bay", :int, 3, "Mesh";
              help = "Shell elements spanwise between two consecutive ribs"),
    ParamSpec("mesh.elements_between_stringers", "Elements between stringers", :int, 1, "Mesh";
              help = "Shell subdivisions across each stringer bay, including spar margins; 1 to 100"),
    ParamSpec("mesh.stringer_runout_ratio", "Stringer runout distance / pitch", :float, 0.75, "Mesh";
              help = "Retire a stringer when either skin's projected x-clearance to a spar falls below this fraction of the stringer pitch (greater than 0, at most 1). 0.75 means 75% of the pitch. Root stringer spacing is unchanged; 1 reproduces the original runout rule"),
    ParamSpec("mesh.elements_spar_height", "Elements over height", :int, 3, "Mesh";
              help = "Shell elements through the spar web and rib height"),
    ParamSpec("mesh.aero_chord_points", "Aero chord points", :int, 41, "Mesh";
              help = "Points per surface of the aerodynamic loft mesh"),

    # --- RBE3 and supports -------------------------------------------------
    ParamSpec("rbe3.enabled", "Create RBE3 spiders", :bool, true, "RBE3 and supports";
              help = "One RBE3 per rib station with the reference node on the chord line"),
    ParamSpec("rbe3.ref_xc", "Reference node", :float, 0.25, "RBE3 and supports";
              unit = "x/c", help = "Chord fraction of the independent RBE3 node"),
    ParamSpec("supports.mode", "Support definition", :choice, "root", "RBE3 and supports";
              choices=["root","custom"], help="Root fixes global translations 1,2,3 on the main-box root skin/spar perimeter. Custom uses only the rib support sets below; an empty table leaves the structure unsupported"),
    ParamSpec("supports.items", "Rib support sets", :supportsets, Any[], "RBE3 and supports";
              help="Select a physical rib (root is 1), a spar/skin intersection or corner, and global DOFs 1=x,2=y,3=z,4=Rx,5=Ry,6=Rz. Overlapping selections are combined per GRID. Leading-edge extension and RBE3 reference nodes are excluded"),

    # --- loads -------------------------------------------------------------
    ParamSpec("loads.label", "Load case name", :string, "Load case 1", "Loads";
              help = "Name of the first load case in the deck and results selector"),
    ParamSpec("loads.method", "Load method", :choice, "analytic", "Loads";
              choices = ["analytic", "vortex_lattice"],
              help = "Prescribed lift distribution, or aerodynamic forces and moments from VortexLattice.jl"),
    ParamSpec("loads.lift_total", "Lift, semi-span", :float, 6000.0, "Loads";
              unit = "N",
              help = "Unscaled prescribed lift carried by the modelled half wing; define the intended base load level before applying the load multiplier"),
    ParamSpec("loads.load_factor", "Load multiplier", :float, 1.5, "Loads";
              unit = "dimensionless", help = LOAD_MULTIPLIER_NOTE * " Negative values reverse forces and moments."),
    ParamSpec("loads.distribution", "Spanwise distribution", :choice, "elliptical",
              "Loads"; choices = ["elliptical", "chord", "uniform"],
              help = "elliptical, proportional to the local chord, or constant"),
    ParamSpec("loads.torque_y", "Torque about global y", :float, 0.0, "Loads";
              unit = "N m", help = "Unscaled prescribed couple at RBE3 centers; right-hand +y, distributed by tributary strips and scaled once by the same load multiplier"),
    ParamSpec("loads.follower_forces", "Follower forces", :bool, false, "Loads";
              help = "OpenJFEM FORCE directions follow RBE3 station rotation. SOL101 uses a first-order load linearization at zero rotation; SOL106 rotates forces during every equilibrium trial. MOMENT vectors, including prescribed global-y torque, remain fixed. This does not recompute aerodynamic pressures."),
    ParamSpec("loads.cases", "Additional load cases", :loadcases, Any[], "Loads";
              help = "Independent cases inherit unspecified lift, torque and flight inputs from load case 1"),
    ParamSpec("loads.fuel_percent", "Fuel status", :float, 100.0, "Loads"; unit = "%",
              help = "0 empty to 100 full in each tank bay, filling upward from the lower surface. Creates fuel mass, CG and inertia for this case. Enable and bound the tank in Fuel tank"),
    ParamSpec("loads.structure_inertia", "Include structural inertia", :bool, true, "Loads";
              help = "Apply the same signed global acceleration and load multiplier to dry structural shell/bar mass as to fuel. Includes bar centroid offsets; excludes separate aerodynamic display/export shells. Existing definitions without this setting retain fuel-only acceleration until enabled"),
    ParamSpec("loads.fuel_accel_x", "Inertia acceleration x", :float, 0.0, "Loads"; unit = "g",
              help = "Signed global force per unit mass, multiplied by standard gravity and the load multiplier. Applies to fuel and, when Include structural inertia is enabled, the dry structure. Zero all axes for mass without inertia loads"),
    ParamSpec("loads.fuel_accel_y", "Inertia acceleration y", :float, 0.0, "Loads"; unit = "g",
              help = "Signed global y acceleration shared by fuel and enabled structural inertia; scaled once by the load multiplier"),
    ParamSpec("loads.fuel_accel_z", "Inertia acceleration z", :float, -1.0, "Loads"; unit = "g",
              help = "Signed global z acceleration shared by fuel and enabled structural inertia. Default -1 applies downward weight; scaled once by the load multiplier. Fixed global directions, including in SOL106; no inferred reversal for aircraft acceleration"),

    # --- aerodynamics ------------------------------------------------------
    ParamSpec("aero.speed", "Air speed", :float, 70.0, "Aerodynamics";
              unit = "m/s", help = "Steady attached VLM with linear Prandtl-Glauert subsonic compressibility through Mach 0.5; no shocks, viscous drag or stall"),
    ParamSpec("aero.density", "Air density", :float, 1.225, "Aerodynamics";
              unit = "kg/m3"),
    ParamSpec("aero.alpha", "Angle of attack", :float, 5.0, "Aerodynamics";
              unit = "deg", help = "Root chord incidence relative to the flow; positive gives positive lift. Large local incidence is allowed with an attached-flow validity warning; no stall prediction"),
    ParamSpec("aero.speed_of_sound", "Speed of sound", :float, 340.0, "Aerodynamics";
              unit = "m/s", help = "Mach = speed / speed of sound; maximum 0.5. A Prandtl-Glauert transformation accounts for linear subsonic compressibility. Attached flow is assumed; shocks and stall are not modeled"),
    ParamSpec("aero.span_panels", "Panels per semi-span", :int, 20, "Aerodynamics";
              help = "Requested minimum, 4 to 64, with cosine spacing towards the tip. Twisted geometry adds panels automatically"),
    ParamSpec("aero.chord_panels", "Panels per chord", :int, 9, "Aerodynamics";
              help = "Requested minimum, 2 to 24, with cosine spacing. Camber and twist may add panels to resolve curved geometry and local normals"),

    # --- material ----------------------------------------------------------
    ParamSpec("material.name", "Material 1 name", :string, "AL2024", "Materials"),
    ParamSpec("material.E", "Young modulus", :float, 7.1e10, "Materials"; unit = "Pa"),
    ParamSpec("material.nu", "Poisson ratio", :float, 0.33, "Materials"),
    ParamSpec("material.rho", "Density", :float, 2780.0, "Materials"; unit = "kg/m3"),
    ParamSpec("materials.library", "Additional materials", :materials, default_material_library(), "Materials";
              help = "Material 1 uses the values above. Additional rows define id >= 2, name, E in Pa, nu and rho in kg/m3. " * MATERIAL_IDEALIZATION_NOTE),
    ParamSpec("materials.shells", "Shell materials and construction", :shellmaterials, default_shell_materials(), "Materials";
              help = "Per-component monolithic MAT1 or symmetric face/core/face PCOMP. Face thickness is per face. Rib and spar-bay overrides are total thickness and change the core only, requiring total > twice face thickness"),
    ParamSpec("materials.bars", "Beam materials", :barmaterials, default_bar_materials(), "Materials";
              help = "Select an isotropic material for stringers, spar caps, rib stiffeners and fixed-area runout connectors"),

    # --- properties --------------------------------------------------------
    ParamSpec("properties.t_skin_upper", "Upper skin thickness", :float, 0.0025,
              "Properties"; unit = "m"),
    ParamSpec("properties.t_skin_lower", "Lower skin thickness", :float, 0.0022,
              "Properties"; unit = "m"),
    ParamSpec("properties.panels", "Individual stiffened-panel properties", :panelproperties, Any[], "Properties";
              help = "Physical panel key and layout token, with sparse skin and stringer properties. Blank values inherit shared defaults. Reset overrides before changing the geometry or rib/stringer/runout layout"),
    ParamSpec("properties.t_spar_web", "Spar web thickness", :float, 0.0030,
              "Spar properties"; unit = "m", help = "Default for both spars. Individual physical rib bays can override either web thickness below"),
    ParamSpec("properties.t_rib_web", "Rib web thickness", :float, 0.0020,
              "Rib properties"; unit = "m", help = "Default main-box rib thickness; override individual physical ribs below"),
    ParamSpec("properties.rib_stiffeners_enabled", "Create vertical rib stiffeners", :bool, true, "Rib properties";
              help = "Vertical T bars at physical stringer columns of each main-box rib. Skin mesh subdivisions do not add stiffeners"),
    ParamSpec("properties.rib_stiffener_flange_width", "T flange width", :float, 0.030, "Rib properties"; unit = "m"),
    ParamSpec("properties.rib_stiffener_height", "T overall height", :float, 0.032, "Rib properties"; unit = "m"),
    ParamSpec("properties.rib_stiffener_flange_thickness", "T flange thickness", :float, 0.002, "Rib properties"; unit = "m"),
    ParamSpec("properties.rib_stiffener_web_thickness", "T web thickness", :float, 0.002, "Rib properties"; unit = "m"),
    ParamSpec("properties.ribs", "Individual rib properties", :ribproperties, Any[], "Rib properties";
              help = "Overrides by physical rib number: web thickness, vertical stiffeners enabled, and PBARL T dimensions. Unset values inherit the defaults"),
    ParamSpec("properties.spar_bays", "Individual spar bay properties", :sparproperties, Any[], "Spar properties";
              help = "Optional front/rear web thickness overrides. Bay b spans physical ribs b and b+1; unset values inherit the default thickness"),
    ParamSpec("properties.stringer_flange_width", "T flange width", :float, 0.030,
              "Beam sections"; unit = "m",
              help = "PBARL T DIM1. Flange lies against the skin; the web points into the box"),
    ParamSpec("properties.stringer_height", "T overall height", :float, 0.032,
              "Beam sections"; unit = "m",
              help = "PBARL T DIM2, including flange thickness. The centroid offset is included in the CBAR"),
    ParamSpec("properties.stringer_flange_thickness", "T flange thickness", :float, 0.002,
              "Beam sections"; unit = "m", help = "PBARL T DIM3; must be less than the overall height"),
    ParamSpec("properties.stringer_web_thickness", "T web thickness", :float, 0.002,
              "Beam sections"; unit = "m", help = "PBARL T DIM4; must be less than the flange width"),
    ParamSpec("properties.spar_cap_side", "Square spar cap side", :float, 0.020,
              "Spar properties"; unit = "m",
              help = "PBARL BAR with equal DIM1 and DIM2. One face lies against the skin; the square extends into the box"),

    # --- output ------------------------------------------------------------
    ParamSpec("output.title", "Model title", :string, "Wing torsion box", "Analysis"),
    ParamSpec("output.nastran_file", "NASTRAN file", :string, "output/wing_box.bdf",
              "Analysis"; help = "Relative paths resolve against the application folder"),
    ParamSpec("output.solution", "Solution", :choice, "103", "Analysis";
              choices = ["103", "101", "105", "106"],
              help = "103 normal modes, 101 linear static, 105 linear buckling, 106 experimental geometric nonlinear static with a matching SOL101 comparison for every enabled load case"),
    ParamSpec("output.n_modes", "Modes or buckling roots", :int, 10, "Analysis";
              help = "Eigenvalues requested for SOL 103 and SOL 105"),
    ParamSpec("output.buckling_max_factor", "Buckling search limit", :float,
              50.0, "Analysis"; unit = "x load",
              help = "SOL 105 looks for load factors between 0 and this. " *
                     "Raise it if the run finds no roots"),
    ParamSpec("output.include_aero_shells", "Export aero shells", :bool, false,
              "Analysis"; help = "Also write the aerodynamic loft as CQUAD4 elements"),
    ParamSpec("output.t_aero_shell", "Aero shell thickness", :float, 0.0005,
              "Analysis"; unit = "m"),
    ParamSpec("nonlinear.load_steps", "Nonlinear load increments", :int, 8, "Analysis";
              help = "SOL106 nominal increments to the full selected load; native JFEM can cut back failed increments"),
    ParamSpec("nonlinear.max_iterations", "Iterations per increment", :int, 25, "Analysis";
              help = "SOL106 maximum equilibrium iterations per attempted load increment"),
    ParamSpec("nonlinear.displacement_tolerance", "Displacement convergence tolerance", :float, 1.0e-6, "Analysis";
              help = "SOL106 relative displacement-correction tolerance (JFEM NLTOL)"),
    ParamSpec("nonlinear.residual_tolerance", "Residual convergence tolerance", :float, 1.0e-6, "Analysis";
              help = "SOL106 relative force-residual tolerance (JFEM NLRESTOL)"),
    ParamSpec("nonlinear.max_cutbacks", "Maximum increment cutbacks", :int, 8, "Analysis";
              help = "SOL106 cutback attempts before reporting incomplete convergence. If full load fails, the last verified accepted state is compared with SOL101 scaled to the same load, with a red warning"),

    ParamSpec("sensitivity.settings", "Sensitivity setup", :string, "", "Sensitivity";
              help="Saved sensitivity objective and property selections; evaluated only when a sensitivity job is started"),

    # --- JFEM solver -------------------------------------------------------
    ParamSpec("jfem.repo", "JFEM repository", :string, "", "JFEM solver";
              help = "Folder holding src/OpenJFEM.jl and the jfem launcher. " *
                     "Leave empty to find the enclosing solver checkout automatically. Relative paths are resolved from the app; jfem.path is accepted as an input alias."),
    ParamSpec("jfem.output_dir", "Results folder", :string, "output/jfem",
              "JFEM solver";
              help = "Parent results folder, relative to the app. Each run keeps its own timestamped folder; SOL106 comparisons keep separate case/SOL101 and case/SOL106 decks and results"),
    ParamSpec("jfem.output_formats", "Output formats", :string, "jrs",
              "JFEM solver";
              help = "Letters passed to the launcher: j viewer file, " *
                     "r report, s results JSON, v VTK, h HDF5"),
    ParamSpec("jfem.timeout_minutes", "Run timeout", :int, 30, "JFEM solver";
              unit = "min",
              help = "Timeout for each individual solver run, including each SOL101/SOL106 case. The first run also precompiles the solver and is slow"),
]

const SCHEMA_BY_KEY = Dict{String,ParamSpec}(s.key => s for s in SCHEMA)

"""
    default_params() -> Dict{String,Any}

Flat, dotted-key parameter dictionary holding every schema default.
"""
default_params() = merge(Dict{String,Any}(s.key => deepcopy(s.default) for s in SCHEMA),
                         Dict{String,Any}(REFERENCE_METADATA_KEY => Any[], PLAN_VIEW_METADATA_KEY => "", DRAWINGS_METADATA_KEY => ""))

"""
    flatten_toml(nested, prefix = "") -> Dict{String,Any}

Turn the nested dictionary produced by `TOML.parse` into a flat dictionary
keyed on dotted paths.
"""
function flatten_toml(nested::AbstractDict, prefix::String = "")
    out = Dict{String,Any}()
    for (k, v) in nested
        key = isempty(prefix) ? String(k) : string(prefix, ".", String(k))
        if v isa AbstractDict
            merge!(out, flatten_toml(v, key))
        else
            out[key] = v
        end
    end
    return out
end

"""Nominal base-chord location about which a point's dxc is defined."""
function point_nominal(p::AbstractDict, key::AbstractString)
    key == "planform.trailing_edge_points" && return 1.0
    for edge in ("front", "rear")
        key == "box.$(edge)_spar_points" || continue
        scalar = "box.$(edge)_spar_xc"
        return Float64(get(p, scalar, SCHEMA_BY_KEY[scalar].default))
    end
    return 0.0
end

"""Canonical delta points; legacy absolute xc is converted once using the loaded nominal."""
function normalize_planform_points(value, key::AbstractString = "planform points";
                                   nominal::Real = point_nominal(Dict(), key))
    value isa AbstractVector || throw(ArgumentError("$key must be an array of eta/dxc tables"))
    length(value) <= 100 || throw(ArgumentError("$key supports at most 100 points"))
    out = Dict{String,Float64}[]
    used = Set{Float64}()
    rear = key == "box.rear_spar_points"
    for (i, raw) in enumerate(value)
        raw isa AbstractDict || throw(ArgumentError("$key point $i must be an eta/dxc table"))
        all(k -> k isa AbstractString || k isa Symbol, keys(raw)) ||
            throw(ArgumentError("$key point $i has invalid field names"))
        fields = Set(String(k) for k in keys(raw))
        coordinate = "dxc" in fields ? "dxc" : "xc"
        (fields == Set(["eta", coordinate]) || rear && fields == Set(["eta", coordinate, "stringer_angle"])) ||
            throw(ArgumentError("$key point $i must contain eta and dxc (or legacy xc, never both)" * (rear ? ", optionally stringer_angle" : " only")))
        row = Dict(String(k) => v for (k, v) in raw)
        rear && !haskey(row,"stringer_angle") && (row["stringer_angle"] = 0.0)
        for field in (rear ? ("eta", coordinate, "stringer_angle") : ("eta", coordinate))
            v = row[field]
            v isa Real && !(v isa Bool) && isfinite(v) && isfinite(Float64(v)) ||
                throw(ArgumentError("$key point $i $field must be a finite number"))
        end
        eta = Float64(row["eta"])
        dxc = Float64(row[coordinate]) - (coordinate == "xc" ? Float64(nominal) : 0.0)
        isfinite(dxc) || throw(ArgumentError("$key point $i dxc must be finite"))
        0.0 <= eta <= 1.0 || throw(ArgumentError("$key point $i eta must be between 0 and 1"))
        eta == 0.0 && (eta = 0.0) # canonicalize -0.0 before Set/Dict endpoint handling
        eta in used && throw(ArgumentError("$key has duplicate eta $eta"))
        push!(used, eta)
        normalized = Dict("eta" => eta, "dxc" => dxc)
        rear && (normalized["stringer_angle"] = Float64(row["stringer_angle"]))
        push!(out, normalized)
    end
    sort!(out; by = row -> row["eta"])
    return out
end

"""Parse physical leading-edge bay exclusions without expanding unbounded ranges."""
function leading_edge_disabled_bays(value::AbstractString)
    length(value)<=100000||throw(ArgumentError("leading_edge.disabled_bays is too long"))
    isempty(strip(value))&&return Int[]
    bays=Set{Int}();expanded=0
    for token in split(value,',')
        entry=match(r"^\s*([0-9]+)\s*(?:-\s*([0-9]+)\s*)?$",token)
        entry===nothing&&throw(ArgumentError("leading_edge.disabled_bays needs positive bay numbers or ranges such as 2,4-6"))
        first_bay=tryparse(Int,entry.captures[1]);last_bay=entry.captures[2]===nothing ? first_bay : tryparse(Int,entry.captures[2])
        first_bay!==nothing&&last_bay!==nothing&&1<=first_bay<=last_bay||
            throw(ArgumentError("leading_edge.disabled_bays needs positive ascending integer ranges"))
        last_bay-first_bay<10000||throw(ArgumentError("leading_edge.disabled_bays supports at most 10000 listed bay entries"))
        expanded+=last_bay-first_bay+1
        expanded<=10000||throw(ArgumentError("leading_edge.disabled_bays supports at most 10000 listed bay entries"))
        union!(bays,first_bay:last_bay)
    end
    return sort!(collect(bays))
end

leading_edge_disabled_bays(value)=throw(ArgumentError("leading_edge.disabled_bays must be a string such as 2,4-6"))
function leading_edge_disabled_bays(p::AbstractDict)
    value=get(p,"leading_edge.disabled_bays","")
    value isa AbstractString||throw(ArgumentError("leading_edge.disabled_bays must be a string such as 2,4-6"))
    return leading_edge_disabled_bays(value)
end
function leading_edge_disabled_bays(p::AbstractDict,rib_count::Integer)
    bays=leading_edge_disabled_bays(p)
    if p["leading_edge.enabled"]&&!isempty(bays)
        last(bays)<rib_count||throw(ArgumentError("leading_edge.disabled_bays must use physical bays 1 to $(rib_count-1); got bay $(last(bays))"))
    end
    return bays
end

"""Strict table normalization shared by TOML, Studies and interactive rib editors."""
function normalize_rib_tables(value, key::AbstractString; end_eta::Real=1.0)
    value isa AbstractVector || throw(ArgumentError("$key must be an array of rib tables"))
    length(value)<=100 || throw(ArgumentError("$key supports at most 100 rows"))
    master=key=="ribs.masters";out=Dict{String,Any}[];seen=Set{Float64}()
    for (index,raw) in enumerate(value)
        raw isa AbstractDict || throw(ArgumentError("$key row $index must be a table"))
        all(k->k isa AbstractString||k isa Symbol,keys(raw))||throw(ArgumentError("$key row $index has invalid field names"))
        row=Dict(String(k)=>v for (k,v) in raw)
        allowed=master ? Set(["eta","mode","angle","pitch"]) : Set(["rib","mode","angle"])
        all(k->k in allowed,keys(row)) || throw(ArgumentError("$key row $index has unsupported fields"))
        field=master ? "eta" : "rib"
        for required in (master ? (field,"mode","pitch") : (field,"mode"))
            haskey(row,required)||throw(ArgumentError("$key row $index needs $required"))
        end
        get!(row,"angle",90.0)
        modes=master ? ("flight_direction","rear_spar_angle") : ("flight_direction","front_spar_angle")
        row["mode"] in modes || throw(ArgumentError("$key row $index mode must be $(join(modes," or "))"))
        for number in (master ? (field,"angle","pitch") : (field,"angle"))
            v=row[number];v isa Real&&!(v isa Bool)&&isfinite(v)&&isfinite(Float64(v)) ||
                throw(ArgumentError("$key row $index $number must be a finite number"))
        end
        position=Float64(row[field])
        if master
            0<position<end_eta||throw(ArgumentError("$key row $index ETA must be strictly between 0 and box.end_eta=$end_eta; endpoint masters are automatic"))
            row["pitch"]>0||throw(ArgumentError("$key row $index outgoing pitch must be positive"))
            row["pitch"]=Float64(row["pitch"])
        else
            isinteger(position)&&1<=position<=100001||throw(ArgumentError("$key row $index rib must be a positive integer"))
        end
        position in seen&&throw(ArgumentError("$key has duplicate $field=$position"));push!(seen,position)
        0<row["angle"]<180||throw(ArgumentError("$key row $index angle must be strictly between 0 and 180 degrees"))
        row[field]=master ? position : Int(position);row["angle"]=Float64(row["angle"])
        push!(out,row)
    end
    sort!(out;by=row->row[master ? "eta" : "rib"])
    return out
end

function coerce_value(spec::ParamSpec, v)
    # Preserve useful row-specific diagnostics for interactive point editing.
    spec.kind === :planformpoints && return normalize_planform_points(v, spec.key)
    spec.kind in (:masterribs,:riborientations) && return normalize_rib_tables(v,spec.key)
    spec.kind === :airfoilstations && return normalize_airfoil_stations(v)
    spec.kind === :supportsets && return normalize_support_sets(v)
    spec.kind in (:ribproperties,:sparproperties) && return normalize_component_properties(v,spec.key)
    spec.kind === :panelproperties && return normalize_panel_properties(v)
    spec.kind === :materials && return normalize_material_library(v)
    spec.kind in (:shellmaterials,:barmaterials) && return normalize_material_assignments(v,spec.key)
    if spec.key=="leading_edge.disabled_bays"
        v isa AbstractString||throw(ArgumentError("leading_edge.disabled_bays must be a string such as 2,4-6"))
        leading_edge_disabled_bays(v)
        return strip(v) # preserve range notation; signatures compare the visible string
    end
    if spec.key=="fuel.disabled_bays"
        v isa AbstractString||throw(ArgumentError("fuel.disabled_bays must be a string such as 2,4-6"))
        fuel_disabled_bays(v)
        return strip(v)
    end
    try
        if spec.kind === :float
            v isa AbstractString && return parse(Float64, strip(v))
            return Float64(v)
        elseif spec.kind === :int
            v isa AbstractString && return round(Int, parse(Float64, strip(v)))
            return round(Int, Float64(v))
        elseif spec.kind === :bool
            v isa Bool && return v
            v isa Number && return v != 0
            return lowercase(strip(String(v))) in ("true", "yes", "on", "1")
        elseif spec.kind === :loadcases
            return normalize_load_cases(v)
        else
            return String(v)
        end
    catch
        throw(ArgumentError("parameter $(spec.key): cannot read $(repr(v)) as $(spec.kind)"))
    end
end

"""
    normalize_params(flat) -> (params, unknown_keys)

Merge a flat dictionary of user values over the schema defaults, coercing each
value to its declared type, then validate the result.
"""
function normalize_params(flat::AbstractDict)
    if haskey(flat,"jfem.path")
        flat=Dict{String,Any}(String(k)=>v for (k,v) in flat)
        haskey(flat,"jfem.repo")&&!isempty(strip(String(flat["jfem.repo"])))&&flat["jfem.repo"]!=flat["jfem.path"]&&
            throw(ArgumentError("jfem.repo and jfem.path specify different solver locations"))
        flat["jfem.repo"]=pop!(flat,"jfem.path")
    end
    p = default_params()
    # Saved panel overrides refer to the old physical runout boundaries. Keep
    # their original one-pitch rule; genuinely new definitions use 0.75.
    !isempty(flat) && !haskey(flat,"mesh.stringer_runout_ratio") &&
        (p["mesh.stringer_runout_ratio"]=1.0)
    if !isempty(flat)&&!haskey(flat,"loads.structure_inertia")
        p["loads.structure_inertia"]=false
        p["structure_inertia_migration_note"]="Legacy definition: structural inertia remains disabled, preserving its prior fuel-only acceleration loads. Enable Include structural inertia to load the dry structure too."
    end
    # Old definitions contain neither setting and must keep their original loft.
    !haskey(flat,"airfoil.interpolation") && !haskey(flat,"airfoil.stations") &&
        (p["airfoil.interpolation"]="linear")
    !haskey(flat,"loads.fuel_percent") && haskey(flat,"fuel.fill_fraction") &&
        (p["loads.fuel_percent"]=100coerce_value(SCHEMA_BY_KEY["fuel.fill_fraction"],flat["fuel.fill_fraction"]))
    unknown = String[]
    for (k, v) in flat
        key = String(k)
        if key == "structure_inertia_migration_note"
            # Derived import provenance may accompany a native parameter snapshot.
            # It is not a model input and never overrides the actual boolean.
            v isa AbstractString && (p[key]=String(v))
            continue
        end
        if key == REFERENCE_METADATA_KEY
            p[key] = normalize_references(v)
            continue
        end
        if key == PLAN_VIEW_METADATA_KEY
            p[key] = normalize_plan_view(v)
            continue
        end
        if key == DRAWINGS_METADATA_KEY
            p[key] = normalize_drawings(v)
            continue
        end
        key in LEGACY_SECTION_KEYS && continue
        spec = get(SCHEMA_BY_KEY, key, nothing)
        if spec === nothing
            push!(unknown, key)
            continue
        end
        # Point migration needs all scalar nominal locations, independent of
        # dictionary iteration order. Normalize these arrays after the merge.
        p[key] = spec.kind in (:planformpoints,:masterribs,:riborientations) ? v : coerce_value(spec, v)
    end
    p["loads.structure_inertia"] && pop!(p,"structure_inertia_migration_note",nothing)
    for spec in SCHEMA
        spec.kind === :planformpoints || continue
        p[spec.key] = normalize_planform_points(p[spec.key], spec.key; nominal=point_nominal(p, spec.key))
    end
    p["ribs.masters"]=normalize_rib_tables(p["ribs.masters"],"ribs.masters";end_eta=p["box.end_eta"])
    p["leading_edge.rib_orientations"]=normalize_rib_tables(p["leading_edge.rib_orientations"],"leading_edge.rib_orientations")
    migrate_legacy_sections!(p, flat)
    validate_params(p)
    return p, unknown
end

"""
    read_input(path) -> Dict{String,Any}

Read a TOML input file and return the validated flat parameter dictionary.
"""
function read_input(path::AbstractString)
    isfile(path) || throw(ArgumentError("input file not found: $path"))
    params, unknown = normalize_params(flatten_toml(TOML.parsefile(path)))
    isempty(unknown) || @warn "ignoring unknown input keys" file = path keys = unknown
    return params
end

"""
    validate_params(p)

Check the parameter set for the constraints the mesh generator relies on and
throw an `ArgumentError` naming the offending parameter.
"""
function validate_params(p::AbstractDict; check_cases::Bool = true)
    normalize_sensitivity_settings(get(p,"sensitivity.settings",""))
    for spec in SCHEMA
        spec.kind in (:float, :int) || continue
        isfinite(p[spec.key]) || throw(ArgumentError("$(spec.key) must be finite"))
    end
    pos(key) = p[key] > 0 ||
        throw(ArgumentError("$key must be positive, got $(p[key])"))
    for k in ("planform.area", "planform.aspect_ratio", "box.rib_pitch",
              "box.stringer_pitch", "mesh.stringer_runout_ratio", "material.E", "material.rho",
              "properties.t_skin_upper", "properties.t_skin_lower",
              "properties.t_spar_web", "properties.t_rib_web",
              "properties.stringer_flange_width", "properties.stringer_height",
              "properties.stringer_flange_thickness", "properties.stringer_web_thickness",
              "properties.spar_cap_side", "fuel.density", "leading_edge.t_skin", "leading_edge.t_rib")
        pos(k)
    end
    for k in ("output.t_aero_shell",)
        p[k] >= 0 || throw(ArgumentError("$k must not be negative, got $(p[k])"))
    end
    p["properties.stringer_flange_thickness"] < p["properties.stringer_height"] ||
        throw(ArgumentError("T stringer flange thickness must be less than its overall height"))
    p["properties.stringer_web_thickness"] < p["properties.stringer_flange_width"] ||
        throw(ArgumentError("T stringer web thickness must be less than its flange width"))

    0 < p["planform.taper_ratio"] <= 1.0 || throw(ArgumentError(
        "planform.taper_ratio must be in (0, 1], got $(p["planform.taper_ratio"])"))
    0.0 <= p["material.nu"] < 0.5 || throw(ArgumentError(
        "material.nu must be in [0, 0.5); negative (auxetic) ratios are not supported by the current solver input path, got $(p["material.nu"])"))

    fs = p["box.front_spar_xc"]
    rs = p["box.rear_spar_xc"]
    0.0 < fs < rs < 1.0 || throw(ArgumentError(
        "spar positions must satisfy 0 < front_spar_xc < rear_spar_xc < 1, " *
        "got $fs and $rs"))
    0.0 < p["box.end_eta"] <= 1.0 || throw(ArgumentError(
        "box.end_eta must be in (0, 1], got $(p["box.end_eta"])"))
    p["fuel.start_rib"] >= 1 || throw(ArgumentError("fuel.start_rib must be at least 1 (the root rib)"))
    p["fuel.end_rib"] >= 0 || throw(ArgumentError("fuel.end_rib must be 0 (the final rib) or a positive rib number"))
    fuel_disabled_bays(p)
    p["leading_edge.start_rib"] >= 1 || throw(ArgumentError("leading_edge.start_rib must be at least 1 (the root rib)"))
    p["leading_edge.end_rib"] >= 0 || throw(ArgumentError("leading_edge.end_rib must be 0 (the final rib) or a positive rib number"))
    get(p,"leading_edge.rib_orientation","flight_direction") in ("flight_direction","front_spar_angle") ||
        throw(ArgumentError("leading_edge.rib_orientation must be flight_direction or front_spar_angle"))
    0.0 < p["leading_edge.rib_angle"] < 180.0 ||
        throw(ArgumentError("leading_edge.rib_angle must be strictly between 0 and 180 degrees; 90 is perpendicular to the inboard front spar"))
    leading_edge_disabled_bays(p)
    0 <= p["fuel.fill_fraction"] <= 1 || throw(ArgumentError("fuel.fill_fraction must be between 0 (empty) and 1 (full)"))
    0 <= p["loads.fuel_percent"] <= 100 || throw(ArgumentError("Fuel status must be between 0% and 100%"))
    validate_rib_stiffener_defaults(p)
    validate_materials(p)
    validate_panel_properties(p)

    for k in ("planform.sweep_ref_xc", "planform.twist_axis_xc", "rbe3.ref_xc")
        0.0 <= p[k] <= 1.0 || throw(ArgumentError("$k must be in [0, 1], got $(p[k])"))
    end

    p["mesh.elements_between_ribs"] >= 1 ||
        throw(ArgumentError("mesh.elements_between_ribs must be at least 1"))
    p["mesh.stringer_runout_ratio"] <= 1 ||
        throw(ArgumentError("mesh.stringer_runout_ratio must be greater than 0 and at most 1; the root layout reserves at least one pitch beside each spar"))
    2 <= p["leading_edge.chord_elements"] <= 100 ||
        throw(ArgumentError("leading_edge.chord_elements must be between 2 and 100"))
    1 <= p["mesh.elements_between_stringers"] <= 100 ||
        throw(ArgumentError("mesh.elements_between_stringers must be between 1 and 100"))
    p["mesh.elements_spar_height"] >= 1 ||
        throw(ArgumentError("mesh.elements_spar_height must be at least 1"))
    p["airfoil.n_points"] >= 21 ||
        throw(ArgumentError("airfoil.n_points must be at least 21"))
    p["mesh.aero_chord_points"] >= 7 ||
        throw(ArgumentError("mesh.aero_chord_points must be at least 7"))
    p["output.n_modes"] >= 1 ||
        throw(ArgumentError("output.n_modes must be at least 1"))

    abs(p["planform.dihedral"]) < 89.0 ||
        throw(ArgumentError("planform.dihedral must be below 89 deg"))
    abs(p["planform.sweep"]) < 89.0 ||
        throw(ArgumentError("planform.sweep must be below 89 deg"))
    abs(p["planform.twist_tip"]) < 45.0 ||
        throw(ArgumentError("planform.twist_tip must be below 45 deg"))

    # The edge difference is linear between the union of all point stations;
    # a positive chord at those stations is sufficient over the whole wing.
    planform = planform_geometry(p)
    spar_geometry(p)
    normalize_rib_tables(get(p,"ribs.masters",Any[]),"ribs.masters";end_eta=p["box.end_eta"])
    normalize_rib_tables(get(p,"leading_edge.rib_orientations",Any[]),"leading_edge.rib_orientations")
    get(p,"supports.mode","root") in ("root","custom") ||
        throw(ArgumentError("supports.mode must be root or custom"))
    support_sets=normalize_support_sets(get(p,"supports.items",Any[]))

    # Every active stringer segment must advance towards the tip; explicit
    # rear points supply local angles and ignore the scalar fallback angle.
    stringer_path(p)

    sol = String(p["output.solution"])
    sol in ("101", "103", "105", "106") ||
        throw(ArgumentError("output.solution must be 101, 103, 105 or 106"))
    for (key,lo,hi) in (("nonlinear.load_steps",1,1000),
            ("nonlinear.max_iterations",1,1000),("nonlinear.max_cutbacks",0,50))
        lo <= p[key] <= hi || throw(ArgumentError("$key must be between $lo and $hi"))
    end
    for key in ("nonlinear.displacement_tolerance","nonlinear.residual_tolerance")
        1e-12 <= p[key] < 1 || throw(ArgumentError("$key must be at least 1e-12 and less than 1"))
    end

    String(p["loads.distribution"]) in ("elliptical", "chord", "uniform") ||
        throw(ArgumentError("loads.distribution must be elliptical, chord or uniform"))
    isfinite(p["loads.lift_total"]) && p["loads.lift_total"] >= 0 ||
        throw(ArgumentError("loads.lift_total must not be negative"))
    isfinite(p["loads.load_factor"]) ||
        throw(ArgumentError("loads.load_factor must be a number"))
    String(p["loads.method"]) in ("analytic", "vortex_lattice") ||
        throw(ArgumentError("loads.method must be analytic or vortex_lattice"))
    for k in ("aero.speed", "aero.density", "aero.speed_of_sound")
        pos(k)
    end
    4 <= p["aero.span_panels"] <= 64 || throw(ArgumentError(
        "aero.span_panels must be between 4 and 64"))
    2 <= p["aero.chord_panels"] <= 24 || throw(ArgumentError(
        "aero.chord_panels must be between 2 and 24"))
    if p["loads.method"] == "vortex_lattice"
        p["rbe3.enabled"] || throw(ArgumentError(
            "vortex_lattice transfers loads to RBE3 centers; rbe3.enabled must be true"))
        p["aero.speed"] / p["aero.speed_of_sound"] <= 0.5 || throw(ArgumentError(
            "vortex_lattice supports Mach <= 0.5 with a linear Prandtl-Glauert compressibility approximation; reduce speed or increase the physically appropriate speed of sound. Shocks and transonic flow are not modeled"))
        abs(p["aero.alpha"]) < 89 ||
            throw(ArgumentError("vortex_lattice angle of attack must stay strictly within +/-89 deg"))
        abs(p["planform.sweep"]) <= 60 && abs(p["planform.dihedral"]) <= 30 ||
            throw(ArgumentError("vortex_lattice supports sweep within +/-60 deg and dihedral within +/-30 deg"))
        planform.aspect_ratio >= 2 || throw(ArgumentError(
            "vortex_lattice requires actual planform aspect ratio >= 2"))
    end
    # Aerodynamic loads use station spiders; fuel has separate bay spiders.
    if sol in ("101", "105", "106")
        aero_loading=p["loads.method"]=="vortex_lattice" || abs(p["loads.lift_total"])+abs(p["loads.torque_y"])>0
        fuel_loading=p["fuel.enabled"] && p["loads.fuel_percent"]>0 &&
            any(p["loads.fuel_accel_"*axis]!=0 for axis in ("x","y","z"))
        structure_loading=p["loads.structure_inertia"] && any(p["loads.fuel_accel_"*axis]!=0 for axis in ("x","y","z"))
        (!aero_loading || p["rbe3.enabled"]) || throw(ArgumentError(
            "SOL $sol applies the lift at the RBE3 reference nodes, so " *
            "rbe3.enabled must be true"))
        (aero_loading || fuel_loading || structure_loading) && abs(p["loads.load_factor"])>0 ||
            throw(ArgumentError(
                "SOL $sol needs nonzero lift, torque, enabled structural acceleration or fuel acceleration with fuel present, and a nonzero load multiplier"))
    end

    p["jfem.timeout_minutes"] >= 1 ||
        throw(ArgumentError("jfem.timeout_minutes must be at least 1"))
    fmt = strip(String(p["jfem.output_formats"]), ['-', ' '])
    (!isempty(fmt) && all(c -> c in "jrsvhmc", fmt)) || throw(ArgumentError(
        "jfem.output_formats must be a non-empty combination of the letters " *
        "jrsvhmc, got $(repr(String(p["jfem.output_formats"])))"))
    occursin('s', fmt) || throw(ArgumentError(
        "jfem.output_formats must include 's', the results JSON the viewer reads"))

    # The generator needs both airfoil codes to be readable before meshing.
    validate_airfoil_selection(p, "root")
    validate_airfoil_selection(p, "tip")
    normalize_airfoil_stations(get(p,"airfoil.stations",Any[]))
    get(p,"airfoil.interpolation","linear") in ("linear","cosine") ||
        throw(ArgumentError("airfoil.interpolation must be linear or cosine"))
    if p["fuel.enabled"] || p["leading_edge.enabled"] || !isempty(get(p,"ribs.masters",Any[])) || !isempty(p["properties.ribs"]) || !isempty(p["properties.spar_bays"]) || get(p,"supports.mode","root")=="custom" && !isempty(support_sets)
        _, physical_ribs, _ = span_stations(make_wing(p), p)
        validate_component_property_bounds(p,length(physical_ribs))
        p["fuel.enabled"] && fuel_rib_bounds(p, length(physical_ribs))
        p["fuel.enabled"] && fuel_disabled_bays(p,length(physical_ribs))
        p["leading_edge.enabled"] && leading_edge_rib_bounds(p, length(physical_ribs))
        p["leading_edge.enabled"] && leading_edge_disabled_bays(p,length(physical_ribs))
        get(p,"supports.mode","root")=="custom" && validate_support_ribs(support_sets,length(physical_ribs))
        if p["leading_edge.enabled"]
            all(row["rib"]<=length(physical_ribs) for row in get(p,"leading_edge.rib_orientations",Any[]))||
                throw(ArgumentError("leading_edge.rib_orientations references a rib beyond the generated $(length(physical_ribs)) physical ribs"))
        end
    end
    if check_cases
        normalize_load_cases(p["loads.cases"])
        for spec in load_case_specs(p)[2:end]
            try
                validate_params(spec.params; check_cases = false)
            catch e
                throw(ArgumentError("load case $(spec.id) ($(spec.label)): " * sprint(showerror, e)))
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
#  Writing the parameter set back out
# ---------------------------------------------------------------------------

function toml_string_literal(value::AbstractString)
    io = IOBuffer()
    TOML.print(io, Dict("value" => String(value)))
    return strip(split(String(take!(io)), '='; limit = 2)[2])
end

function toml_value(spec::ParamSpec, v)
    if spec.kind === :airfoilstations
        # Nested coordinate tables remain ordinary TOML data, not JSON strings.
        io=IOBuffer();TOML.print(io,Dict("stations"=>normalize_airfoil_stations(v)))
        return String(take!(io))
    elseif spec.kind === :panelproperties
        panel_literal(x) = x isa AbstractString ? toml_string_literal(x) : x isa AbstractDict ?
            "{"*join((string(k," = ",panel_literal(value)) for (k,value) in sort!(collect(x);by=first)),", ")*"}" : string(x)
        return "["*join(panel_literal.(normalize_panel_properties(v)),", ")*"]"
    elseif spec.kind in (:loadcases, :planformpoints, :masterribs, :riborientations, :supportsets, :ribproperties, :sparproperties, :materials, :shellmaterials, :barmaterials)
        literal(x) = x isa AbstractString ? toml_string_literal(x) : string(x)
        return "[" * join(("{" * join((string(k, " = ", literal(v)) for (k, v) in sort!(collect(row); by = first)), ", ") * "}" for row in v), ", ") * "]"
    elseif spec.kind === :bool
        return v ? "true" : "false"
    elseif spec.kind === :int
        return string(Int(v))
    elseif spec.kind === :float
        return string(Float64(v))
    else
        return toml_string_literal(String(v))
    end
end

"""
    params_to_toml(p) -> String

Write the parameter set out as a TOML input file, preserving the schema order
and the section grouping.
"""
function params_to_toml(p::AbstractDict)
    io = IOBuffer()
    println(io, "# =========================================================================")
    println(io, "#  Wing torsion-box FE model generator - input file")
    println(io, "#  Written by WingFEGen on ",
            Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"))
    println(io, "#  Units: SI  (m, N, kg, Pa)")
    println(io, "#  Axes:  x aft, y towards the tip, z up. Right-hand semi-span wing.")
    println(io, "# =========================================================================")
    section = ""
    for spec in SCHEMA
        sec, name = split(spec.key, '.'; limit = 2)
        if sec != section
            section = String(sec)
            println(io)
            println(io, "[", section, "]")
        end
        value = spec.kind === :planformpoints ? normalize_planform_points(p[spec.key], spec.key; nominal=point_nominal(p, spec.key)) : p[spec.key]
        if spec.kind === :airfoilstations
            # A table array changes TOML scope; emit it after scalar sections.
            continue
        end
        line = string(rpad(String(name), 22), "= ", toml_value(spec, value))
        comment = isempty(spec.unit) ? spec.help :
                  isempty(spec.help) ? spec.unit : string(spec.unit, ", ", spec.help)
        isempty(comment) || (line = string(rpad(line, 46), "  # ", comment))
        println(io, line)
    end
    if !isempty(get(p,"airfoil.stations",Any[]))
        println(io)
        TOML.print(io,Dict("airfoil"=>Dict("stations"=>normalize_airfoil_stations(p["airfoil.stations"]))))
    end
    items = normalize_references(get(p, REFERENCE_METADATA_KEY, Any[]))
    if !isempty(items)
        println(io)
        TOML.print(io, Dict("references" => Dict("items" => items)))
    end
    view = Dict{String,Any}()
    plan_view = normalize_plan_view(get(p, PLAN_VIEW_METADATA_KEY, ""))
    drawings = normalize_drawings(get(p, DRAWINGS_METADATA_KEY, ""))
    isempty(plan_view) || (view["plan_view"] = plan_view)
    isempty(drawings) || (view["drawings"] = drawings)
    if !isempty(view)
        println(io)
        TOML.print(io, Dict("view" => view))
    end
    return String(take!(io))
end

"""
    schema_payload(p, input_path) -> Dict

The JSON payload the web app uses to build its parameter form. The schema is
sent as an ordered array so the browser can lay the form out without knowing
anything about the model.
"""
function schema_payload(p::AbstractDict, input_path::AbstractString)
    specs = Any[Dict{String,Any}(
        "key" => s.key, "label" => s.label, "kind" => String(s.kind),
        "group" => s.group, "unit" => s.unit, "help" => s.help,
        "choices" => s.choices) for s in SCHEMA]
    values = Dict{String,Any}(s.key => p[s.key] for s in SCHEMA)
    values[REFERENCE_METADATA_KEY] = deepcopy(get(p, REFERENCE_METADATA_KEY, Any[]))
    values[PLAN_VIEW_METADATA_KEY] = normalize_plan_view(get(p, PLAN_VIEW_METADATA_KEY, ""))
    values[DRAWINGS_METADATA_KEY] = normalize_drawings(get(p, DRAWINGS_METADATA_KEY, ""))
    return Dict{String,Any}(
        "ok" => true,
        "input_file" => input_path,
        "units" => "SI (m, N, kg, Pa)",
        "schema" => specs,
        "values" => values,
    )
end
