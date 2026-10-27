/* Contextual field help for schema, dynamic editors and display controls.
 * Existing author-written explanations take precedence. Native title tooltips
 * serve pointer users; the same text is described and displayed on keyboard
 * focus. No extra help buttons or per-field event handlers are created. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingFormHelp=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 const selector='input:not([type="hidden"]),select,textarea',generated=new WeakMap(),ids=Object.create(null);
 function entries(names,text){for(const name of names.split('|'))ids[name]=text;}
 entries('planform-input-method','Choose equivalent definitions of the base trapezoid. Direct chords and full projected span are converted to area, aspect ratio and taper ratio; edge perturbations remain separate.');
 entries('planform-dimension-root','Base trapezoid chord at the symmetry plane, in metres, before leading/trailing-edge perturbations.');
 entries('planform-dimension-tip','Base trapezoid chord at the tip, in metres, before leading/trailing-edge perturbations.');
 entries('planform-dimension-span','Full projected tip-to-tip span in metres. The generated lifting surface uses one half of this span.');
 entries('show-movable-preview','Show each movable aerodynamic surface at its defined deflection, including structurally meshed controls. This preview does not change FE nodes; Mesh deflected in its structure definition controls that separately.');
 entries('movable-surface-edit|movable-structure-edit','Select which movable surface to edit. Other definitions remain stored and participate in the model even while their forms are hidden.');
 entries('movable-structure-select','Choose an aerodynamic movable surface that needs a structural definition, then use Add structure to create its shells and attachment settings.');
 entries('engine-edit','Select the engine definition to edit. Other enabled engines remain included in the generated model.');
 entries('material-library-select','Select a material definition, including its elastic properties, density and assessment allowables. Changes affect every component assigned this material ID.');
 entries('material-preset-select','Choose a predefined material to add to the library. Review its listed elastic, density and allowable values before assigning it to components.');
 entries('allowable-material','Select the material whose assessment limits are edited. These limits affect reserve-factor comparisons, not constitutive stiffness or the FE solution.');
 entries('allowable-mode','Select the material assessment basis: von Mises stress for isotropic MAT1, principal strain for a laminate made entirely from one orthotropic MAT8 material, or Not assessed.');
 entries('allowable-stress','Positive allowable compared with recovered von Mises stress. Generated models use MPa; imported models retain the explicitly displayed source stress units. Reserve factor is allowable divided by demand.');
 entries('allowable-strain_tension','Dimensionless tensile principal-strain limit: 0.005 means 0.5%. Compared with the positive principal strain on each recovered ply face of a laminate made from this MAT8 material.');
 entries('allowable-strain_compression','Positive magnitude of the compressive principal-strain limit: 0.005 means 0.5%. Compared with the magnitude of negative principal strain on each recovered ply face.');
 entries('case-edit-select','Select the load case whose inputs you want to edit. All defined cases remain in the Study; display selectors choose which case to show.');
 entries('case-name','Descriptive case name used in result selectors, tables and exports. Use names that distinguish the aircraft condition and load direction.');
 entries('case-method','Prescribed loading applies the specified total lift and distribution. VLM calculates panel loads from flight condition, angle of attack and aerodynamic geometry.');
 entries('case-atmosphere','ISA 1976 derives density and speed of sound from altitude. Manual mode uses your entered density and sound speed independently of altitude.');
 entries('case-density','Air density in kg/m³, used with true airspeed to calculate dynamic pressure q = ½ρV². Active in Manual atmosphere mode.');
 entries('case-speed_of_sound','Local speed of sound in m/s, used to convert Mach number to true airspeed and assess the flow condition. Active in Manual atmosphere mode.');
 entries('case-lift_total','Total prescribed lift on the modeled half lifting surface, in newtons. Its spanwise distribution is selected separately. Aircraft lift matching replaces this target when enabled.');
 entries('case-distribution','Shape of the prescribed span load. The distribution is normalized to the selected half-surface lift, so changing its shape redistributes the same total force.');
 entries('case-match_aircraft_lift','Set half-wing lift to half the complete-aircraft weight times load factor. Prescribed loading uses this target directly; VLM adjusts angle of attack to achieve it.');
 entries('case-aircraft_mass','Complete-aircraft mass in kg, not half-wing structural mass. Lift matching uses L_half = mass × 9.80665 × n / 2.');
 entries('case-maneuver_factor','Aircraft lift load factor n, in multiples of weight. Used with complete-aircraft mass for the matched half-wing lift target.');
 entries('case-torque_y','Additional applied torque about BASIC Y, in N·m, combined with the case loading. Its sign follows the right-hand rule.');
 entries('case-load_factor','Multiplier applied to the case loading. This is a load scale, separate from the aircraft n value used to define a matched lift target.');
 entries('case-follower_forces','Choose whether concentrated forces follow structural rotation in the supported analysis. Fixed directions retain their original global direction; follower forces update with deformation.');
 entries('case-fuel_percent','Fuel content as a percentage of tank capacity for this case. Changes fuel mass, centre of gravity and inertia loads; it does not change tank geometry.');
 entries('case-structure_inertia','Include inertia loads from structural and non-structural mass using this case’s acceleration components. Fuel inertia uses the selected fuel status.');
 for(const axis of ['x','y','z'])entries('case-fuel_accel_'+axis,'Signed inertia-acceleration component along BASIC '+axis.toUpperCase()+', expressed in g (1 g = 9.80665 m/s²). Applied with the case mass settings; review the resulting force directions in Loads display.');
 entries('show-fuel-tank','Display the fuel volume and its boundary edges. This affects the view only; fuel mass is set by the tank definition and selected case fuel status.');
 entries('load-case-select|vlm-case-select|geometry-case-select|mass-case-select|summary-case-select|plots-case-select|inspect-case-select','Choose the load case used by this view or summary. Case-dependent loads, fuel quantities and available results follow this selection; it does not edit the case definition.');
 entries('vlm-show-forces','Show the force components transferred from the aerodynamic calculation to the structural RBE3 reference nodes.');
 entries('vlm-show-moments','Show the moment components transferred from the aerodynamic calculation to the structural RBE3 reference nodes.');
 entries('show-vlm-panel-forces','Display signed panel-normal aerodynamic force arrows at the VLM panel centres. These are panel loads before structural load transfer.');
 entries('vlm-force-scale|support-force-scale','Multiply the displayed vector lengths without changing the underlying force or moment values. Use labels to read numerical magnitudes.');
 entries('show-support-forces|results-show-support-forces','Display constraint force components as solid straight arrows from the selected static solution or buckling preload. Independent of constraint moments. Choose components and stem diameter under Display / Loads&Constraints. Available only when force reactions were recovered.');
 entries('support-force-diameter','Diameter of the solid constraint-force arrow stems in model length units (metres for generated models). Enter 0 for automatic sizing based on model size and arrow length. This changes only the glyph thickness, never the recovered forces or arrow-length scale.');
 for(const [prefix,kind,units] of [['f','force','N'],['m','moment','N·m']])for(const axis of ['x','y','z'])entries('show-support-'+prefix+axis,'Show the global '+axis.toUpperCase()+' constraint '+kind+' component ('+prefix.toUpperCase()+axis+', '+units+') and its label when enabled. Independent of the other five reaction components; filtering does not change the computed results or FE constraints.');
 entries('show-support-moments|results-show-support-moments','Display constraint moment components as right-hand arcs from the selected static solution or buckling preload. Independent of constraint forces. Available only when moment reactions were recovered.');
 entries('show-support-force-values|results-show-support-force-values','Label visible constraint force arrows with signed Fx, Fy, Fz values in N in global XYZ axes. Labels follow the selected result case.');
 entries('show-support-moment-values|results-show-support-moment-values','Label visible constraint moment arcs with signed Mx, My, Mz values in N·m in global XYZ axes. Labels follow the selected result case.');
 entries('vlm-field','Color aerodynamic panels by pressure jump in Pa or dimensionless pressure coefficient jump. Mesh only removes the contour without removing panel geometry.');
 entries('geometry-show-structure','Show the structural model in its current FE result shape. The result deformation scale is controlled in Results; undeformed geometry can be shown separately.');
 entries('show-undeformed','Overlay the original undeformed structural geometry for comparison with the current displacement or mode shape.');
 entries('show-aero-overlay','Show the aerodynamic surface interpolated from the selected structural result deformation. This visualization does not rerun VLM.');
 entries('show-loft-cuts','Intersect the aerodynamic loft with equally spaced spanwise planes. Use matching reference cuts to compare section shapes and placement.');
 entries('loft-cut-count','Number of equally spaced spanwise cutting planes used for both loft and optional reference intersections. More cuts reveal local differences but add visual clutter.');
 entries('loft-cut-color','Color of the aerodynamic loft intersection curves; independent of the reference-geometry cut color.');
 entries('reference-loft-cut-color','Color of loaded-reference intersection curves at the same cutting planes as the loft.');
 entries('show-rib-datums','Show the physical rib datum planes used to position and orient ribs. These guides are distinct from mesh subdivision rows.');
 entries('rib-datum-size','Side length of displayed rib datum squares in metres. Changes only the guide size, not rib geometry or spacing.');
 entries('show-panels','Isolate generated stiffened skin panels and their associated stringers. Panel controls temporarily manage component visibility.');
 entries('show-panel-ids','Label generated physical stiffened panels with P IDs. These identify rib-bay/stringer regions and differ from FE element IDs.');
 entries('explode-panels','Separate complete stiffened panels for inspection. This is a view-only translation; model coordinates and analysis remain unchanged.');
 entries('explode-properties','Separate groups of elements sharing a property ID for inspection. This is a view-only translation and does not alter mesh connectivity or solver coordinates.');
 entries('explode-origin|property-explode-origin','Reference centre from which displayed groups are spread: whole-model centre, bounding-box centre, or individual physical rib/rib-bay centres.');
 entries('explode-distance|property-explode-distance','View-only separation distance in metres. Zero restores physical positions; increasing it makes individual groups easier to inspect.');
 entries('property-display-field','Choose the property quantity to color, such as total shell thickness or material. Unsupported or unavailable values remain visibly unassigned.');
 entries('property-display-material','Choose which constituent to sample for layered shell material coloring; a laminate or sandwich may contain more than one material.');
 entries('surface-mode','Choose opaque or translucent structural shells. Transparency reveals internal members without changing their visibility settings or FE properties.');
 entries('surface-translucency','Amount of structural-shell transparency. Higher translucency reveals more internal geometry; mesh and property values are unchanged.');
 entries('shell-geometry','Display shell midsurfaces or their physical thickness and offsets. Thickness rendering is visual geometry; the solver still uses the shell formulation.');
 entries('beam-style','Draw beam centre lines or full section shapes from their property dimensions and local axes. This affects rendering, not beam stiffness.');
 entries('show-bars-through','Make beam lines visible through structural surfaces to inspect the internal layout. This visual aid can show members otherwise hidden by depth.');
 entries('show-celas-cylinders','Represent scalar CELAS springs by cylinders colored by their displacement component, making their connection direction easier to see.');
 entries('node-radius','Radius of displayed node markers in metres. This does not change node coordinates or connection tolerances.');
 entries('marker-radius','Base radius of displayed load/constraint markers in metres. Constraint size applies its additional multiplier to these visual markers.');
 entries('aero-deformed-style','Rendering finish of the deformed aerodynamic surface. Auto preserves readable result contours; other finishes emphasize geometry or transparency.');
 entries('show-aero-curvature','Color the aerodynamic surface by Gaussian curvature in m⁻². Positive and negative curvature distinguish locally dome-like and saddle-like regions.');
 entries('show-shell-axes','Display each shell’s local x direction used to interpret element-frame quantities. Material axes may differ and have a separate display option.');
 entries('show-bar-axes','Display the beam local x axis along its length and local y/z section directions used for bending and section orientation.');
 entries('show-coordinate-labels','Label model coordinate systems with their IDs and types so that orientation and component definitions can be checked.');
 entries('coordinate-select','Inspect the origin and orientation of an available model coordinate system. BASIC is the global reference frame.');
 entries('show-rbe3-dofs','Show RBE3 reference, independent and optional UM nodes with their participating component numbers. Applies to load-transfer and engine RBE3 connections.');
 entries('show-node-ids','Label visible finite-element GRID identifiers for inspection and cross-reference with the exported deck.');
 entries('show-element-ids','Label visible finite-element identifiers for inspection and cross-reference with property and result records.');
 entries('id-label-size','Text size of node/element ID labels in screen pixels. Increasing it improves readability without enlarging model geometry.');
 entries('mesh-labels-ribs','Show physical rib identifiers. Intermediate FE mesh rows are not extra physical ribs.');
 entries('mesh-labels-stringers','Show physical stringer identifiers, including their upper/lower-surface membership.');
 entries('show-ground-plane','Display the ground reference plane for depth and orientation cues. It is a visual environment feature and creates no FE support.');
 entries('view-ground-z','Elevation of the ground display plane along BASIC Z in metres. It provides a visual reference without changing model coordinates or boundary conditions.');
 entries('show-symmetry-plane','Display the root symmetry plane for orientation. Showing it does not add or remove symmetry boundary conditions.');
 entries('show-structural-inertia','Show structural mass and inertia aggregated per physical rib bay as ellipsoids. Solver mass representation is selected separately in Model / Mass.');
 entries('show-fuel-inertia','Show fuel inertia ellipsoids for the selected case fuel content. Their geometry represents mass distribution, not the tank boundary.');
 entries('show-fuel-cg','Show fuel centres of gravity and their offsets from associated reference nodes for the selected load case.');
 entries('structural-inertia-scale|fuel-inertia-scale','Visual multiplier on ellipsoid radii. The underlying mass, centre of gravity and inertia values remain unchanged.');
 entries('study-note','Record the intent of the latest model edit. Notes are saved with the Study to explain design decisions when it is reopened.');
 entries('sensitivity-solution','Analysis used for the sensitivity baseline. Modal sensitivities use the selected case mass; buckling sensitivities use its static preload.');
 entries('sensitivity-case','Case used to calculate the sensitivity response and its derivatives. This case selection is independent of display-only case selectors.');
 entries('sensitivity-objective','Scalar response to differentiate with respect to selected design variables. Its sign and units determine the meaning of raw and normalized derivatives.');
 entries('sensitivity-component','Response component in its stated coordinate frame. Choose the same component when comparing sensitivity results between runs.');
 entries('sensitivity-surface','Shell fiber or recovery location used for the stress/strain response. Upper and lower fibers may differ under bending.');
 entries('sensitivity-target','Finite-element node or element ID at which the selected response is evaluated. Inspect lets you pick the target directly from the model.');
 entries('sensitivity-method','Method used to obtain property derivatives. Analytic derivatives avoid a separate perturbed response solve for each design variable.');
 entries('sensitivity-check-step','Repeat supported operator-derivative checks with half the step to assess step-size sensitivity. This adds computation and does not change the selected response.');
 entries('sensitivity-filter-mode','Choose wildcard, plain-text or regular-expression matching for the property list. Filtering does not itself change the selected design variables.');
 entries('sensitivity-filter','Filter property names or IDs. Wildcards such as *skin* match a name fragment; Add matches adds all matching variables while keeping previous selections.');
 entries('sensitivity-map-mode','Choose a field of property sensitivities or a first-order preview of changing one property. Preview values are estimates, not a new FE solution.');
 entries('sensitivity-field-family','Property family whose recorded sensitivities are mapped onto the mesh. Different dimensions may have different derivative units.');
 entries('sensitivity-field-quantity','Raw df/dp has response units per property unit. Normalized (p/f)df/dp estimates relative response change per relative property change and is undefined at a zero baseline.');
 entries('sensitivity-visible-range','Determine color limits from currently visible elements. Hidden elements remain in the result data but no longer set this display’s limits.');
 entries('sensitivity-map-property','Select one property’s recorded derivative for the first-order change preview. The model itself is not modified by this selection.');
 entries('sensitivity-map-change','Signed percentage change used in the linear sensitivity preview. Large changes can invalidate the first-order estimate; rerun analysis to verify them.');
 entries('sensitivity-map-metric','Display the estimated change in response units or relative to the baseline response. This changes the presentation of the same derivative estimate.');
 entries('result-case-select','Select the solved load case to display. Only compatible results are available; changing the selection does not rerun analysis.');
 entries('result-analysis-select','Select the analysis or result stage, including static preload where available. Contours, mode lists and reactions follow this selection.');
 entries('compare-results','Overlay both available compatible result solutions for visual comparison using the current result display settings.');
 entries('deform-scale','Visual magnification of displacement or mode shape. A scale of one uses the stored displacement magnitude; eigenvectors have their recorded normalization.');
 entries('animate','Animate the displayed displacement or mode shape for inspection. This is a visualization of stored results, not a transient analysis.');
 entries('contour-select','Select the recovered result quantity to color on the model. Its legend gives units and range; gray elements have no applicable value.');
 entries('result-palette','Color palette for the active result contour. Signed red/blue distinguishes negative and positive values; changing the palette does not change the numerical result.');
 entries('inspect-entity','Choose the entity type to inspect, including generic RBE3 connections such as engine attachments. Picking and ID lookup use this type.');
 entries('inspect-id','Identifier of the chosen entity type. Use the exported GRID or element ID, not its position in a list.');
 entries('show-picked-axes','Display local element axes for the inspected element to interpret its section orientation and result components.');
 entries('deck-case-select','Select the generated case deck to preview. Loads and fuel mass reflect this case’s settings.');
 entries('deck-search-case','Make text searches in the deck case-sensitive. This affects matching only and does not modify the input file.');
 entries('reference-file','Load an STL, OBJ or GLB surface as reference geometry. It is displayed alongside the structural model and does not become FE elements automatically.');
 entries('reference-select','Select the loaded reference whose placement, units, scale and appearance are edited below. Other references retain their own settings.');
 entries('reference-lock','Prevent accidental placement edits of the selected reference while keeping its geometry available for comparison.');
 entries('reference-units','Units used by the imported coordinates. The selected conversion scales them into the model’s metre-based coordinate system.');
 entries('reference-axis','Interpret the imported model’s axis convention before applying placement rotations and translations. Check the preview against the global coordinate triad.');
 entries('reference-visible','Show or hide only the selected reference object. The FE model and other references retain their visibility settings.');
 entries('reference-wireframe','Show the selected reference as edges instead of filled surfaces. This affects the reference geometry only.');
 entries('reference-opacity','Opacity of the selected reference surface. Lower values reveal the FE model and other geometry behind it.');
 for(const axis of ['x','y','z']){
  entries('reference-position-'+axis,'Translation of the selected reference along model '+axis.toUpperCase()+' in metres, after source-unit conversion.');
  entries('reference-rotation-'+axis,'Rotation of the selected reference about '+axis.toUpperCase()+' in degrees. Check the preview because successive 3D axis rotations are order-dependent.');
  entries('reference-scale-'+axis,'Dimensionless scale factor along '+axis.toUpperCase()+'. A value of one retains the converted size; linked-axis scaling applies the same scale to all axes.');
 }
 entries('measure-mode','Measure the straight-line distance between two picked points or the absolute separation projected onto a selected model axis.');
 entries('measure-axis','Global axis used for the projected distance measurement. Components along the other axes are ignored.');
 entries('measure-snap-nodes','Snap picked measurement locations to visible FE nodes so that the reported distance uses exact node coordinates.');
 entries('export-scope','Export all available entities/cases or only the currently visible layers and selected case. This selection controls the content of the geometry export.');
 entries('export-state','Export original model coordinates or the currently displayed deformation and magnification. Displayed geometry is for visualization, not a new undeformed analysis model.');
 entries('export-references','Include loaded reference surfaces in the geometry export alongside the selected FE entities.');
 entries('export-line-radius','Tube radius in metres used to represent line entities in the exported 3D geometry. Leave blank for automatic sizing.');
 entries('reference-format','Input syntax of the external finite-element deck. Choose the actual source format so that nodes, elements and supported analysis settings are interpreted correctly.');
 entries('reference-local-path','Path to the main external FE input deck. Keep its included files in their expected relative locations.');
 entries('abaqus-completion-enabled','Explicitly add the analysis data below to a mesh-only Abaqus input. Review the selected sets, units, loads and constraints; this is a new analysis definition.');
 entries('planform-view-mirror','Show the opposite half for full-span visual context. The underlying generated model and its applied loads remain unchanged.');
 const svg={opacity:'Opacity of the reference background image, independent of the drawing fills. Reduce it to make model lines easier to compare.',zoom:'2D view magnification in percent. 100% is the fitted baseline; right drag pans, left drag zooms a window, and double-click fits the view.',filled:'Show or hide filled drawing regions. Turning fills off leaves outlines so that a background image remains visible.','grid-enabled':'Show a drawing grid for measurement and alignment. This is a visual guide and does not create mesh nodes.','grid-spacing':'Distance between drawing-grid lines in the displayed drawing units. It does not change FE mesh spacing.','grid-color':'Color of the 2D drawing grid, independent of geometry and background-image colors.',measure:'Select a 2D measurement mode, then pick the required points in the drawing. Measurements use drawing coordinates and the displayed units.','snap-points':'Snap measurement and image-pin picks to nearby geometry points and endpoints for precise alignment.','snap-lines':'Snap measurement and image-pin picks to nearby geometry lines and edges for precise alignment.'};
 const analysis={solution:'Choose static (101), normal modes (103), linear buckling (105) or nonlinear static (106), as supported by this imported model.',follower:'Choose whether concentrated force directions remain fixed globally or follow structural rotation in the supported static analysis.',modes:'Number of eigenmodes requested from the analysis. Fewer modes reduce result output; a model may return fewer valid modes than requested.',buckling_max_factor:'Upper search bound for positive buckling load factors. A finite bound can omit modes above it; zero uses the configured unbounded search.',buckling_output_override:'Replace the imported deck’s SOL105 output selections with the explicit options shown here. Turn off to retain source output requests.',load_steps:'Initial number of increments used to apply the nonlinear load. Smaller increments can improve convergence at the cost of more solves.',max_iterations:'Maximum equilibrium iterations allowed per nonlinear load increment before cutback or failure handling.',max_cutbacks:'Maximum number of times a failed nonlinear increment may be reduced and retried.',displacement_tolerance:'Convergence tolerance for the nonlinear displacement update. Smaller values require a tighter displacement convergence check.',residual_tolerance:'Convergence tolerance for nonlinear force equilibrium. Smaller values require a tighter residual convergence check.'};
 const completion={solution:analysis.solution,E:'Young’s modulus for the added isotropic material, in the source deck’s consistent stress units. It must match the units of geometry and force.',nu:'Dimensionless Poisson ratio of the added isotropic material; it relates transverse contraction to axial strain.',rho:'Mass per unit volume in the source deck’s consistent units, required for meaningful modal frequencies.',element_set:'Abaqus element-set name receiving the added section/material. ALL assigns it to every supported element.',constraint_dofs:'Restrained translational components: 1 = X, 2 = Y, 3 = Z. Only constrain the physical supports intended for this case.',force_set:'Abaqus node-set name receiving the specified total static force.',total_force:'Total static force distributed across the selected force node set, expressed in the source deck’s force units.',force_x:'X component of the force direction vector. Together with Y and Z it defines the direction of the total applied force.',force_y:'Y component of the force direction vector. Together with X and Z it defines the direction of the total applied force.',force_z:'Z component of the force direction vector. Together with X and Y it defines the direction of the total applied force.',modes:analysis.modes};
 const movable={enabled:'Include this movable surface’s structural mesh and connections in the FEM. Turning this off preserves its definition and aerodynamic preview.',skin_material:'Library material ID used by this movable surface’s upper and lower structural skins.',web_material:'Library material ID used by this movable surface’s structural spar webs.',rib_material:'Library material ID used by this movable surface’s ribs, including the ribs at attachments. Attachment triangle material is selected separately.',span_elements:'Number of FE divisions along each physical movable-surface rib bay. Increasing it refines the mesh without adding physical ribs.',chord_elements:'Number of FE divisions across the movable structural chord. Refine this direction when short spanwise features create overly wide shell cells.',height_elements:'Number of FE divisions through movable-surface web height. Increasing it resolves the web with more shell elements.',spar:'Main-box spar receiving the attachment fitting. The selected physical rib locates the connection along that spar.',fitting:'Shell fittings create physical triangle meshes from the boxes to the hinge. Idealized fittings use constraint-based load transfer instead of those shell triangles.',kind:'Hinge joins translations and rotations perpendicular to the hinge while allowing relative rotation about it; an optional axial actuator provides restraint. Rigid joins all relative motion.'};
 const localProperties={thickness:'Monolithic shell thickness in mm.',front_thickness:'Front spar-web thickness in mm.',rear_thickness:'Rear spar-web thickness in mm.',face_thickness:'Thickness of each sandwich face in mm; total thickness is twice this value plus core thickness.',core_thickness:'Sandwich core thickness in mm between the two faces.',flange_width:'Stringer or stiffener flange width in mm. Zero defines a blade-only section where supported.',height:'Overall section height in mm, including its attached flange where present.',flange_thickness:'Attached flange thickness in mm. Inactive for a blade-only section.',web_thickness:'Section web thickness in mm.',width:'Section width in mm.',side:'Square spar-cap section side length in mm.',kind:'Monolithic uses one through-thickness material; sandwich uses face/core/face construction.',material:'Library material assigned to this local physical property region.',face_material:'Material shared by the two sandwich faces of this local property region.',core_material:'Material of the sandwich core in this local property region.',enabled:'Include or omit the local member while retaining its editable definition.'};
 const clean=text=>String(text||'').replace(/\s+/g,' ').trim();
 function label(el){
  const explicit=el.getAttribute('aria-label');if(explicit)return clean(explicit);
  const source=el.labels?.[0]||el.closest('label');if(source){const copy=source.cloneNode(true);copy.querySelectorAll('input,select,textarea,button,.boxer-form-help-description').forEach(n=>n.remove());return clean(copy.textContent);}
  const cell=el.closest('td');return clean(cell?.closest('table')?.querySelectorAll('thead th')[cell.cellIndex]?.textContent);
 }
 function lookup(el){
  const id=el.id||'',name=label(el),d=el.dataset;
  if(ids[id])return ids[id];if(svg[d.svgv])return svg[d.svgv];if(completion[d.completion])return completion[d.completion];if(analysis[d.key])return analysis[d.key];if(movable[d.movableStructureField])return movable[d.movableStructureField];
  if(name==='Twist (deg)')return 'Section twist at this eta station, in degrees about the defined twist-axis x/c. A nonempty twist schedule replaces the simple Tip twist distribution; values are interpolated with the selected method.';
  if(localProperties[d.field]&&el.closest('.rf-property-editor,.component-properties'))return localProperties[d.field]+' Clear the field to inherit the current default. Local overrides affect this region; family minimum gauges remain unchanged.';
  if(d.field==='rib')return 'Physical rib number receiving this local override. Intermediate mesh divisions do not renumber physical ribs.';
  if(d.field==='bay')return 'Physical rib bay receiving this override: bay b lies between ribs b and b+1. Mesh refinement does not change this identity.';
  if(d.field==='stiffener_enabled')return 'Override whether this rib has its stiffener. A blank selection inherits the family setting.';
  if(d.field==='dxc')return 'Signed chordwise offset from the nominal edge or spar, as a fraction of the base trapezoid chord at this eta. Positive moves aft; 0.01 moves by one percent of that base chord, before edge perturbations.';
  if(d.field==='pitch')return 'Desired physical rib spacing in metres after this datum. Additional FE subdivisions are controlled independently in Mesh.';
  if(d.pointIndex!==undefined)return 'Stringer angle in degrees for this span interval, relative to the selected rear spar, front spar or Global Y. Zero follows that reference; positive sweeps aft.';
  if(/^airfoil-.*-search$/.test(id))return 'Filter the UIUC profile catalogue by name or designation. Selecting a match previews its coordinates before you apply it.';
  if(/^airfoil-.*-choices$/.test(id))return 'Preselect a UIUC airfoil to preview its shape. Use selected profile commits it; Cancel selection restores the previous profile.';
  if(/^airfoil-.*-file$/.test(id))return 'Read local XFoil-format airfoil coordinates. Coordinates are embedded in the Study for reuse without the original file.';
  if(/^Material \d+ name$/i.test(name))return 'Descriptive library name for this material ID. Renaming it preserves existing component assignments.';
  if(/^E \(GPa\)$/i.test(name))return 'Young’s modulus in gigapascals: 71 GPa = 71,000 MPa. Controls elastic axial and bending stiffness; saved model values use Pa.';
  if(/Poisson ratio/i.test(name))return 'Dimensionless ratio of transverse contraction to longitudinal strain for the isotropic material. It also affects shear stiffness.';
  if(/^Density \(kg\/m/.test(name))return 'Material mass per unit volume in kg/m³. Used for structural mass, inertia loads and modal mass; it does not change elastic stiffness.';
  if(/ minimum face thickness \(mm\)$/.test(name))return 'Minimum thickness of each sandwich face, in millimetres. There are two faces; total thickness is twice this value plus the core thickness.';
  if(/ minimum core thickness \(mm\)$/.test(name))return 'Minimum sandwich core thickness in millimetres, between the two faces. Local total-thickness overrides vary the core while retaining the face gauges.';
  if(/ construction$/.test(name))return 'Monolithic uses one material through the shell thickness. Sandwich uses two equal face layers around a core with separately assigned materials and minimum gauges.';
  if(d.materialValue!==undefined)return / face material$/.test(name)?'Library material used for both faces of this sandwich. Face thickness is specified per face.':/ core material$/.test(name)?'Library material used for the sandwich core between its two face layers.':'Library material assigned to this structural component. Its elastic properties, density and allowables come from that material ID.';
  if(/^(Main|Fill) direction [XYZ]$/.test(name))return 'Component of the '+name.split(' ')[0].toLowerCase()+' light direction vector. Change the vector to illuminate different faces; this affects rendering only.';
  if(/\beta\b|\beta station\b/i.test(name)||/\beta\b/.test(name.replaceAll('η','eta')))return 'Spanwise fraction of the modeled semi-span: 0 is the root and 1 is the tip. This places the station without changing the overall span.';
  if(/^Constraint rib$/.test(name))return 'Physical rib number at which the constraint is applied. Intermediate FE rows are not additional physical ribs.';
  if(/^Constraint location$/.test(name))return 'Location on the selected rib where the chosen displacement components are restrained.';
  return '';
 }
 function explain(el){
  if(!el?.matches?.(selector)||el.type==='file'&&el.hidden)return '';
  const owned=generated.get(el),own=clean(el.getAttribute('title'));
  if(own&&own!==owned&&(own!==label(el)||(own.length>60&&/[.!?]/.test(own))))return own;
  for(const parent of [el.closest('label[title]'),el.closest('.row[title],.case-field[title]')])if(clean(parent?.title))return clean(parent.title);
  const row=el.closest('.row,.case-field'),help=row?.querySelector('.help-icon[title]');if(help?.title)return clean(help.title);
  return lookup(el);
 }
 function eligible(el){return el.matches?.(selector)&&!el.hidden;}
 function install(doc=globalThis.document){
  if(!doc?.body)return null;if(doc.__boxerFormHelp)return doc.__boxerFormHelp;
  let serial=0,pending=false,keyboard=false,active=null,destroyed=false;const records=new Map(),queue=new Set(),listeners=[];
  const tooltip=doc.createElement('div');tooltip.className='boxer-form-help-tooltip';tooltip.setAttribute('role','tooltip');tooltip.setAttribute('popover','manual');tooltip.hidden=true;doc.body.append(tooltip);
  function hide(){active=null;tooltip.hidden=true;try{if(tooltip.matches(':popover-open'))tooltip.hidePopover?.();}catch(_){} }
  function describe(el){if(!eligible(el)||!el.isConnected)return;const text=explain(el);if(!text)return;
   let r=records.get(el);if(!r){const span=doc.createElement('span');span.className='boxer-form-help-description';span.id='boxer-field-help-'+(++serial);el.after(span);r={span,originalTitle:el.getAttribute('title')};records.set(el,r);}
   if(r.span.textContent!==text)r.span.textContent=text;
   const tokens=new Set((el.getAttribute('aria-describedby')||'').split(/\s+/).filter(Boolean));tokens.add(r.span.id);const value=[...tokens].join(' ');if(el.getAttribute('aria-describedby')!==value)el.setAttribute('aria-describedby',value);
   if(!el.title||generated.get(el)===el.title||clean(el.title)===label(el)){generated.set(el,text);if(el.title!==text)el.title=text;}
  }
  function show(el){describe(el);const text=explain(el);if(!text)return hide();active=el;tooltip.textContent=text;tooltip.hidden=false;try{tooltip.showPopover?.();}catch(_){}
   const r=el.getBoundingClientRect(),width=Math.min(400,doc.defaultView.innerWidth-24);tooltip.style.width=width+'px';tooltip.style.left=Math.max(12,Math.min(r.left,doc.defaultView.innerWidth-width-12))+'px';tooltip.style.top='0px';const height=tooltip.getBoundingClientRect().height;tooltip.style.top=Math.max(8,Math.min(r.bottom+8,doc.defaultView.innerHeight-height-8))+'px';
  }
  function collect(node){if(node.nodeType!==1&&node.nodeType!==9)return;if(eligible(node))queue.add(node);for(const el of node.querySelectorAll?.(selector)||[])if(eligible(el))queue.add(el);}
  function flush(){pending=false;if(destroyed)return;let count=0;for(const el of queue){queue.delete(el);describe(el);if(++count>=80)break;}for(const [el,r]of records)if(!el.isConnected){r.span.remove();records.delete(el);}if(queue.size)schedule();}
  function schedule(){if(pending||destroyed)return;pending=true;(doc.defaultView.requestIdleCallback||((fn)=>doc.defaultView.setTimeout(fn,0)))(flush,{timeout:250});}
  const containsControls=node=>node.nodeType===1&&(node.matches(selector)||node.querySelector(selector));
  const observer=new doc.defaultView.MutationObserver(changes=>{let removed=false;for(const c of changes){if(c.type==='attributes'){if(eligible(c.target))queue.add(c.target);else if(c.target.matches?.('label,.row,.case-field'))collect(c.target);}else{for(const node of c.addedNodes)collect(node);removed ||= [...c.removedNodes].some(containsControls);}}if(queue.size||removed)schedule();});
  observer.observe(doc.body,{childList:true,subtree:true,attributes:true,attributeFilter:['title']});
  function on(type,fn,capture=false){doc.addEventListener(type,fn,capture);listeners.push(()=>doc.removeEventListener(type,fn,capture));}
  on('keydown',e=>{keyboard=true;if(e.key==='Escape'){hide();return;}if(e.key==='F1'&&eligible(e.target)){e.preventDefault();show(e.target);}});
  on('pointerdown',()=>{keyboard=false;hide();},true);
  on('focusin',e=>{if(!eligible(e.target))return;describe(e.target);if(keyboard)show(e.target);});on('focusout',hide);on('pointerover',e=>{if(eligible(e.target))describe(e.target);});on('scroll',()=>{if(active)hide();},true);
  const api={refresh(node=doc){collect(node);schedule();},audit(node=doc){const all=[...node.querySelectorAll(selector)].filter(eligible);return{total:all.length,covered:all.filter(e=>explain(e)).length,missing:all.filter(e=>!explain(e)).map(e=>({id:e.id,label:label(e),data:{...e.dataset},group:e.closest('fieldset')?.id||''}))};},destroy(){destroyed=true;observer.disconnect();listeners.forEach(fn=>fn());hide();tooltip.remove();for(const [el,r]of records){const tokens=(el.getAttribute('aria-describedby')||'').split(/\s+/).filter(v=>v!==r.span.id);if(tokens.length)el.setAttribute('aria-describedby',tokens.join(' '));else el.removeAttribute('aria-describedby');if(generated.get(el)===el.title){if(r.originalTitle===null)el.removeAttribute('title');else el.setAttribute('title',r.originalTitle);}generated.delete(el);r.span.remove();}records.clear();delete doc.__boxerFormHelp;}};
  doc.__boxerFormHelp=api;api.refresh();return api;
 }
 return{install,explain,label,lookup};
});
