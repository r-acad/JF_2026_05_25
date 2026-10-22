# JFEM-Boxer

JFEM-Boxer is the finite-element generator and browser interface included
with OpenJFEM. It generates shell/bar lifting surfaces, aerodynamic lattices and
load cases, writes REFERENCE decks, launches the solver in this repository and
displays structural results and property sensitivities.

The forms follow the modelling workflow: **Geometry** and **Structure** define
the lifting surface; **Materials**, **Properties** and **Constraints** define
its FE model; **Loads → Cases** defines the conditions to solve. Shared VLM
settings and load plots are in the same Loads menu. **Analysis → FE Analysis**
shows the controls relevant to the selected solution. Results-file and deck
export settings are expandable below the solution controls; file commands
remain in **Project**.

**Analysis of imported model** appears only after loading an external FE input
file. Generated geometry forms are disabled while that model is active; use
Display and Inspect to examine it, Loads → Cases for source cases, and Analysis
to solve it. Opening a generated Study restores its editing forms. Archived
`.jfem` results provide visualization without an imported-source analysis form.

Use the single **Maximize / Restore** action in the pane header to enlarge any
form or drawing. Detailed explanations and less frequent settings are under
expandable headings; warnings and current status remain visible. The same
controls and values are saved regardless of whether their section is expanded.
Fuel density is in **Fuel tank**. Display → Environment groups each plane's
visibility, finish, color and position; choose **Customize lighting** for
individual light intensities and directions.

**Properties → Skin / Stringers / Spars / Ribs / Leading edge** defines the
initial section dimensions as **minimum gauges**. Local property overrides may
increase these dimensions, but an edit below the corresponding minimum is
rejected with an explanation; the generator never silently changes the requested
section. An empty local override inherits its minimum. You may deliberately
edit a family minimum in Properties. This changes the model and requires updated
FE results. For sandwich skins, both the active face/core minima and total
thickness minimum apply. Zero-width shell stringers omit the flange when the
minimum flange width is zero. Disabled stiffeners do not impose dormant bounds.
Movable-surface structures likewise define four minimum skin/web/rib thicknesses;
their current bay properties directly inherit the corresponding surface minimum.

**Materials → Material library** groups each material definition with its
optional allowables. Select a material once to edit both its properties and limits.
Choose **Stress** for isotropic MAT1 materials: the largest recovered von Mises
stress is divided by the specified allowable. Generated-model inputs use MPa
and save Pa; imported-model inputs use the deck's stress units. Choose **Strain**
for laminates made entirely from one orthotropic MAT8 material: enter a tensile
principal-strain limit and a positive compressive principal-strain limit.
Both are dimensionless (`0.005` means `0.5%`). All plies must use the same
material ID; their orientations may differ. Laminates mixing material IDs or
isotropic and orthotropic plies are unassessed for this strain criterion.
Generated **2024 aluminium** materials start with a **300 MPa von Mises limit**.
This is an editable design default, not a certified allowable for every temper,
product form or temperature. Existing explicit limits are preserved. Select
**Not assessed** to disable the check; that choice is saved with the Study.
Other materials and imported files with undeclared stress units receive no
automatic allowable. An empty or incomplete explicit limit is not assessed.
The generated material library remains isotropic; imported MAT8 materials expose
their strain criteria without changing their source elastic properties.

In **Results**, select **Material allowable utilization** to color assessed
elements. A ratio above 1 exceeds the limit. **Inspect** reports the governing
material, ply, face and component, the demand, allowable, reserve ratio `1/U`
and margin `1/U - 1`. Every laminate ply and both ply faces must have valid
criteria and recovery for the element to be assessed. Missing elements remain
gray and the Results note explains the coverage. Comparisons use recovered
element sample locations, not extrapolated corner maxima or interlaminar
stresses. At each ply face the two in-plane principal strains are
`εmax/min = (ε1 + ε2)/2 ± sqrt(((ε1 − ε2)/2)^2 + (γ12/2)^2)`, where
`γ12` is engineering shear strain, twice the strain tensor's off-diagonal.
Positive `εmax` is compared with the tensile limit; the magnitude of negative
`εmin` is compared with the compressive limit. The largest ratio across all
plies and both faces governs. This is a principal-strain limit check, not a
directional ply-failure or progressive-damage model. Earlier Studies containing
five directional strain limits remain loadable, but those limits are never
converted: enter the two principal-strain limits explicitly before assessment.

Checks apply to current SOL101, converged full-load SOL106 and SOL105 static
preload results. Eigenmode amplitudes are arbitrary and are not assessed. For
nonlinear results the reserve ratio is a demand ratio, not a predicted load
multiplier. Beams lacking a recovered equivalent stress are unassessed; axial
stress alone is not substituted for von Mises stress. Editing allowables updates
the comparison without rerunning the FE solution. Criteria are retained by
Study/TOML, while a newly imported model or result archive clears unrelated limits.
Old outputs without complete ply-face recovery must be rerun. Boxer-generated
and explicitly configured imported analyses request strain output; when preserving
an imported source analysis, its authored output requests remain authoritative.
If they suppress strain output, choose an explicit solution in **Analysis of
imported model** and rerun to obtain laminate strain checks.

**Results → Stress Report** contains two property tables: **Von Mises stress**
and **Reserve Factor**. It includes current SOL101 and converged, full-load
SOL106 physical solutions; modal solutions and SOL105, including its static
preload, are outside this report. Choose all eligible load cases or a particular
case. In a generated SOL106 comparison, the full-load linear SOL101 comparison
is identified separately. The largest property statistic across the selected
cases is the envelope, with the governing case shown alongside it.

Under **3D model fields**, choose **Minimum RF**, an individual failure-mode
RF, **Critical case for minimum RF**, or **Critical failure mode for minimum RF**,
then click **Show field**. The field uses the load-case scope and property
envelope selected above; the table's text filter does not exclude model regions.
Changing these settings, allowables or assessment fixities refreshes the active
field. **Clear field** restores ordinary result viewing. The RF field uses the
undeformed model because an envelope can be governed by different cases in
different regions. It works with shell surfaces, beam lines and 3D sections.

Numerical fields offer the table palettes, with fixed RF limits 0 and 2 and
minimum-gauge yellow where verified. Critical cases and failure modes use
named category colors. Gray means unassessed or inapplicable. Inspect an element
to see its RF, governing case, failure mode, physical scope and missing-check
reason. Property envelopes color the whole property; individual physical
column/panel checks color only their recorded constituent elements. Overlapping
checks use the lowest RF, but an incomplete applicable overlap remains gray.
Editing the model or starting an analysis withholds old field values until
current completed results are available.

**Open reserve factor table ↗** opens a separate, resizable table window with
the same structural-group layout as the sensitivity table. Generated models
can be arranged by rib bay and component; imported models retain their actual
property list. Shared properties appear once as shared regions rather than
being assigned fictitious local values. The window follows the Stress Report's
case selection, failure mode, envelope method and material limits. Both the
main report and the separate table offer the sensitivity color palettes.
The default RF palette maps 0–1 to red and 1–2 to blue, with a visible change
of hue immediately across 1; exactly 1 is neutral. Colors saturate at 2,
and RF values above 2 use dark-orange numbers on a light backing for contrast.
Missing or incomplete assessments remain uncolored. Export the displayed data
to CSV, Markdown or self-contained HTML.

Choose **Assessment → Minimum RF** to envelope all applicable criteria over
the selected SOL101/SOL106 cases: material stress or laminate principal strain,
Euler stringer-column buckling, free-web instability, skin-panel buckling,
spar/rib web buckling and spar-cap/rib-stiffener column buckling.
The table retains one row per actual property ID. A physical column or panel
assessment contributes to each property whose elements actually belong to it;
the details identify that shared physical scope. This does not create a separate
local stress estimate for each contributing property. The detached table's
**Presentation** selector offers **Minimum RF**, **Critical case** and
**Failure mode**; the latter two also display the governing numerical RF.

A complete RF above 1 has a **yellow background** when the relevant property
dimensions are all at their minimum gauges. In a standalone physical column or
panel assessment, all its participating properties must be at their minima;
in the combined property table, the test concerns that row's property. A larger
dimension prevents the minimum-gauge marker. Unknown bounds and imported
properties never acquire inferred minima. This highlighting overrides the chosen
palette; values above 2 retain dark-orange numbers.

If an applicable criterion lacks recovery, material limits, membership or a
supported assessment, the complete minimum RF remains unavailable. Details
retain the lowest available ratio and explain missing checks. Imported models
have an explicitly identified material-only envelope. A no-demand **99** marker
never governs over a finite calculated RF, even if that finite RF exceeds 99;
99 is shown only when every applicable assessed criterion has no demand.
Older generated Studies need a model refresh to obtain property bounds and
physical membership; existing below-minimum overrides must be corrected first.

Choose the property statistic:

- **Maximum:** the largest recovered element von Mises stress in the region.
- **Average:** the arithmetic mean of the element peak stresses, with equal
  weight for each element, independent of element area or volume.
- **Average below percentile:** compute the chosen percentile of element
  peak stresses in each property and case, discard stresses above that cutoff,
  and average the retained values. At 95%, the highest approximately 5% are
  discarded; small regions and tied values need not discard exactly 5%.
  Ties at the cutoff are retained, allowing only machine-roundoff differences
  (16 relative machine epsilons). The cutoff uses linear
  interpolation at rank `(n - 1) × percentile / 100` in the sorted sample list.

Each element contributes its largest explicitly recovered von Mises value
across its faces or integration points. Both PSHELL faces are required. The
**Absolute maximum** column always retains the peak and its EID and case,
including when the selected average excludes it. Coverage details show the
retained/discarded counts and cutoff. Stresses use MPa for generated SI models;
an imported deck's undeclared unit system remains labeled **source stress units**.

For **Assessment → Von Mises stress**, the reserve factor is the material's
allowable stress divided by the chosen
property envelope. Values below 1 exceed the specified allowable. A missing
case withholds reserve factors across the selected case envelope; incomplete
element recovery withholds the affected property's factor. Missing material
limits, mixed-material PSHELLs, laminates and beams without recovered equivalent
stress are explicitly unassessed. Zero demand has no finite reserve factor.

For constant isotropic **PBARL T** beams, JFEM recovers a documented
**thin-walled T-section equivalent-stress envelope** from the complete axial,
shear, torque and end-moment resultants. It combines the largest total
axial-plus-bending normal stress at the actual section vertices with bounded
transverse-shear flow and Saint-Venant torsional shear. This is a conservative
envelope within that beam-section model: the normal and shear maxima need not
occur at the same point. It is not an exact pointwise three-dimensional von
Mises stress and excludes junction concentrations and restrained warping.
The method requires flange thickness / full width and web thickness / clear
height no greater than 0.10, consistent section properties, and no varying
section or distributed element loading. Unsupported sections and incomplete
resultants retain an explicit unavailable reason. Recovery details identify
this approximation wherever it contributes to the RF.

Boxer's native-result reader can reprocess existing generated records containing
all required force resultants without another FE solve. Legacy imported results
require a fresh solve to establish section and loading provenance. The method
does not change element stiffness, solved displacements or buckling eigenvalues.
Its shear-flow and open-section torsion assumptions follow the
[Mississippi State structural-analysis notes](https://www.ae.msstate.edu/tupas/SA2/chA14.7_text.html)
and [open-section torsion notes](https://www.ae.msstate.edu/tupas/SA2/chA6.6_text.html).

Laminate principal-strain checks are available in FE Results and in the combined
Minimum RF assessment, and as a separate 3D RF field; percentile trimming applies only to the material-stress
criterion. For SOL106 this ratio
compares demand with a limit; it does not predict the nonlinear failure load.

Use **Maximize** for wide tables, filter by property/name/material, and export
CSV, Markdown or HTML. Exports contain all filtered properties, the selected
method and coverage notes. Values are presented with at most five significant
digits. Editing allowables updates the report without rerunning the solver.

Choose **Assessment → Euler column buckling** for a stringer and its
associated skin between two ribs. This is a separate capacity check from
the material-stress reserve factor. It uses actual generated beam or shell
stringer sections, plus half the physical skin width to the neighboring
stringer or spar on each side, including local skin thickness and section
offsets. A combined skin-and-flange shell contributes once. The report and
separate table identify each physical stringer/rib bay and the governing case.

In **Properties → Stringers**, set **Euler fixity coefficient** `c`:

- `1`: pinned at both ends (default).
- `4`: fixed at both ends.
- Approximately `2.046`: one fixed and one pinned end.
- `0.25`: one fixed and one free end.

The convention is `Pcr = c × π² × (EI)min / L²`; equivalently the effective
length factor is `K = 1 / sqrt(c)`. `L` is the full rib-to-rib stringer path
length. This input changes the assessment, not the FE constraints or the
solution, and can be edited without rerunning the solver.

Missing fixity coefficients in older Studies default to **1** for stringer,
skin, spar and rib checks. Explicit zero, negative or unfinished inputs are
invalid; they are not replaced by the default.

At each mesh cross-section, signed stringer axial force and projected shell
membrane resultants are added over the tributary section. Consecutive elements
along the span are not added together. Compression gives `RF = Pcr / Ncompression`;
the smallest ratio across the section cuts and selected SOL101/SOL106 cases
governs. Stress averaging and percentile trimming do not apply to this mode.
If all selected cases and section cuts have complete recovery and none is in
compression, the displayed RF is **99**, a no-compression marker rather than
a calculated failure multiplier. Missing, stale or incomplete data never receive 99.

The weakest principal bending rigidity is calculated about the elastic section
centroid, retaining the current material stiffnesses. For MAT1/MAT8 laminates,
the rotated laminate membrane/bending law is condensed to its axial extension
and bending terms. Coupling and eccentricity are retained when the strip
stiffnesses are assembled into the combined column section; a single isotropic
modulus is not substituted. Transverse and shear laminate resultants are free
in this strip approximation. The constitutive basis is described in
[NASA RP-1351, *Basic mechanics of laminated composite plates*](https://ntrs.nasa.gov/citations/19950009349).
This is an elementary elastic column estimate. Using local section stiffness with the full bay length
is an approximation for tapered, curved or varying sections. It does not assess
local skin buckling, stringer crippling, torsional buckling or nonlinear collapse.
Run-out fragments without two rib end restraints are explicitly unassessed.
Their known sections and associated skin membership are retained; only the
properties actually involved inherit that incomplete check. A missing run-out
end restraint does not invalidate unrelated rib-to-rib regions. Regenerate an
older mesh to replace its incomplete membership metadata.
For SOL106 the ratio compares recovered compression with an elastic capacity;
it is not a prediction of the nonlinear failure load.

Choose **Assessment → Stringer blade instability** to assess local buckling
of the free web of a generated PBARL T stringer. The table shows critical stress,
average compressive stress, RF, governing case and the web dimensions. It uses
the conventional long-outstand-plate expression

`σcr = 0.425 × π² E / [12(1 − ν²)] × (tw / hw)²`,

where `tw` is the current web thickness and `hw = H − tf` is the clear blade
height from the attached flange to the free tip. The attached longitudinal edge
is treated as simply supported and the opposite edge is free; no extra flange
rotational restraint or finite-length benefit is credited. This coefficient
and the plate equation are documented in
[FHWA-HIF-19-063, equation (29), printed page 86](https://rosap.ntl.bts.gov/view/dot/42925/dot_42925_DS1.pdf#page=102).
The Euler fixity coefficient does not affect this separate local check.

For each eligible SOL101 or converged full-load SOL106 case, the arithmetic
mean of the signed axial bar stresses in that physical rib-bay/stringer segment
is calculated. If both end axial stresses are recovered, their mean first
defines the element value. Every element has equal weight; this is an element
average, not a length-weighted average. Tension is positive. The compressive
demand is `max(0, −mean stress)`; neither von Mises stress nor the largest bending
fiber stress replaces it. Thus tensile and compressive samples can cancel in
the requested average, and this does not assess localized peak compression.

`RF = σcr / average compression`; the smallest RF across the selected load cases
governs. If section dimensions or materials vary within a segment, its lowest
local critical stress is used. Complete coverage with no average compression
gives **99**, even if an individual element is compressive. Missing stresses,
incomplete cases and stale results remain unassessed. Critical and demand
stresses are displayed in MPa. The detached RF grid and exports retain the
physical location, governing case and averaging definition.

This is an elastic, uniform-compression free-web assessment for isotropic beam
stringers, without yielding, postbuckling or crippling corrections. Shell-mode
stringers do not have the requested bar-stress recovery and are explicitly
unassessed by this method. Normal T-stringer portions ending at a run-out can
be assessed locally; the small fixed-area run-out connector bars are excluded.

Choose **Assessment → Skin panel buckling** for the skin compartments between
two ribs and adjacent stringers or spar caps. These are the full skin strips
between support lines, not the half-skin regions used in the stringer-column
check. For example, three stringers define four skin strips between the spars.
The length and width are the averages of the opposite actual 3D boundary-path
lengths; nominal rib/stringer pitches are not substituted.

For every eligible load case, recovered shell membrane resultants are rotated
into a common panel frame: x from the inboard to outboard rib midpoint,
projected into the mean skin plane, and y perpendicular to x in that plane.
The table reports area-weighted mean `σx`, `σy` and `τxy` in **MPa**, with tension
positive. Through-thickness mean stress is the membrane resultant divided by
the actual local thickness. This also applies to laminates, where averaging
outer-face stresses would not generally give the membrane mean. Buckling uses
the area-weighted resultants themselves, preserving thickness variations.

The equivalent rectangular thin plate uses a double-sine displacement series
`w = Σ amn sin(mπx/L) sin(nπy/W)`. Its bending energy and the work of the averaged
membrane loads define `c Kb a = RF Kg a`; the smallest positive multiplier is
the panel RF. This combines biaxial compression and shear in one calculation
and retains the stabilizing effect of tension. Both symmetric and antisymmetric
mode families are included. The energy approach is described in
[NACA TN 1222](https://ntrs.nasa.gov/citations/19930082111) and
[NACA TN 1223](https://ntrs.nasa.gov/citations/19930082113); the double-sine Ritz
approach also accommodates anisotropic laminate bending stiffness, as described
in [this laminate buckling study](https://doi.org/10.1016/0020-7403(90)90063-O).

If the initial basis does not converge, an additional nested refinement follows
the compressive principal-load direction. This matters when strong tension and
shear produce an oblique, short-wavelength buckle: a basis sized from panel
aspect ratio alone can miss it. Both mode directions are increased, both parity
families are retained, and two successive RF changes must remain within 0.5%.
Isotropic or specially orthotropic bending uses exact diagonal normalization to
keep the larger check efficient. Details show the actual recovery coverage,
basis size and refinement change. Missing forces and an unconverged calculation
are identified separately; neither is replaced by a passing RF. The need for
additional Ritz terms under combined tension and shear is also discussed in
[Sathiyaseelan and Baskar's plate study](https://doi.org/10.12989/sem.2012.42.6.867).

For a uniform isotropic panel under longitudinal compression alone, this reduces
to `σcr = c k π² E / [12(1−ν²)] × (t/W)²`, with
`k = min_m (m W/L + L/(m W))²` over positive integer half-wave counts `m`.
The long-plate limit is `k = 4`. The combined-load calculation uses the full
eigenproblem instead of assigning this uniaxial coefficient to shear or biaxial
loading.

Current isotropic and laminate section stiffnesses are transformed into the
panel frame and area-averaged. For membrane/bending-coupled sections the effective
matrix is `D* = D − Bᵀ A⁻¹ B`, a membrane-free bending approximation. The method
retains bending/twisting coupling. It approximates a curved, tapered or skewed
panel by a flat rectangle with averaged geometry and loading; it is not a local
mesh eigenanalysis or a postbuckling/collapse prediction. Thin-plate kinematics
neglect transverse-shear deformation. Sandwich face wrinkling and core instability
require separate checks, especially for thick skins with soft cores.

**Properties → Skin → Skin buckling fixity coefficient** sets `c` independently
of the Euler stringer coefficient. The default **1** means simply supported
plate edges. A larger value scales the capacity to represent a justified
restraint allowance; it does not impose exact clamped edges or change FE
constraints. Editing it refreshes the RF table without another FE solve.

The lowest RF across current SOL101 and converged full-load SOL106 cases governs.
The table and exports retain signed mean stresses, measured dimensions, fixity,
governing case and recovery/convergence information. Complete cases with no
destabilizing averaged membrane loading show **99**. Missing recovery, unsupported
panel boundaries and unresolved numerical convergence remain unassessed.

For **spars and ribs**, the Assessment selector also provides **Spar-web
buckling**, **Rib-web buckling**, **Spar cap column buckling**, **Rib stiffener
column buckling** and **Rib-stiffener blade instability**. Open the reserve-factor
table and select the corresponding structural group to inspect each physical
region, its governing case, dimensions, demand and capacity. These checks also
contribute to **Minimum RF** for every property actually involved. Material
strength remains a separate applicable check: a buckling ratio alone does not
establish a complete minimum RF. In particular, a beam record containing only
axial and normal fibre stresses does not supply the explicitly recovered
equivalent stress required by the material von Mises assessment.

**Web panels.** Spar panels are bounded by adjacent ribs and the upper/lower
skin lines. Rib panels are bounded by actual through-height stiffeners, or by
the spars when no intervening stiffener exists. Additional mesh divisions do
not become fictitious supports. Opposite boundary paths determine the average
length and height of an equivalent rectangle. The model records each element's
location in that rectangle and its stress transformation.

The web check uses the same simply supported double-sine thin-plate bending
model as the skin check, but retains the **spatial membrane field**: each shell
cell contributes its own signed, transformed membrane resultants. Exact
sine/cosine integrals over the mapped cells give the geometric matrix. This
retains biaxial compression, signed shear and stabilizing tension; opposite
tensile and compressive regions under bending do not disappear through whole-web
averaging. The displayed MPa values are area-weighted means for interpretation,
not the loads substituted into the spatial buckling calculation. The use of a
Fourier/Ritz energy method for spatial loads is described in
[*A generalized analytical approach to the buckling of
simply supported rectangular plates under arbitrary loads*](https://doi.org/10.1016/j.engstruct.2007.07.025).
Classical compression, bending, shear and combined-load plate cases are covered
in [NACA TN 3781](https://ntrs.nasa.gov/citations/19930084505).

Current isotropic/laminate bending laws are transformed and area-averaged,
including the membrane-free `D*` approximation described above. Two successive
basis refinements must change RF by no more than 0.5% before reporting an
individual case's numerical RF. An unresolved case can be excluded from the
governing envelope only when a conservative energy bound proves its critical
factor exceeds another case's converged factor. Its own RF remains unavailable,
and the details retain the bound and the reason it cannot govern. This shortcut
does not apply to missing recovery, missing cases or invalid geometry. If no
converged case governs and no such proof is possible, the envelope remains
unassessed. The FE mesh must resolve the stress gradient: one centroidal result
through the web height cannot reveal missing sub-element tension/compression.
Curved/skewed geometry is still an equivalent rectangular-plate approximation,
not a local FE eigenanalysis. Holes, overlapping cells, incomplete boundaries
and missing recovery are not assigned a fabricated RF.

**Caps and rib stiffeners.** The Euler check uses the actual member path
between ribs for a spar cap, or between skins for a rib stiffener. It uses the
current PBARL section's weakest centroidal bending rigidity and recovered axial
force at the section cuts. Only the member contributes stiffness and force;
no tributary skin/web stiffness or intermediate elastic bracing is credited.
`Pcr = c π² (EI)min / L²`; the lowest local capacity-to-compression ratio across
the member and selected cases governs. The classical elastic-column basis is
described in [MIT's beam buckling notes](https://www.ocw.mit.edu/courses/2-002-mechanics-and-materials-ii-spring-2004/bc25a56b5a91ad29ca5c7419616686f7_lec2.pdf).
This is a bare-member engineering estimate; it does not assess lateral-torsional
buckling or crippling. Rib T-stiffeners additionally use the free-web formula
above, with the signed arithmetic mean of their recovered axial bar stresses.

**Properties → Spars** contains the spar-web and spar-cap fixity coefficients;
**Properties → Ribs** contains the rib-web and rib-stiffener coefficients.
All default to **1**. Web coefficients scale the plate capacity; column
coefficients follow the Euler convention above. Changing them recalculates the
report without changing FE constraints or rerunning the solution. The rib-stiffener
free-web check has no additional fixity multiplier. Complete cases without
destabilizing web loading or member compression show the **99** marker;
incomplete or unsupported assessments remain unavailable. For SOL106, all these
ratios compare recovered full-load demand with elastic capacities, rather than
predicting a nonlinear collapse load. Imported models require verified component
support topology before these generated-component checks can be used.

FE stress legends, element inspection and stress-based sensitivity display
adapters use **MPa** when the source stress units are known. Stored solver values
and raw result exports retain their recorded units. Imported results with no
declared unit system remain labeled with source units. The default palette for
**Shells · Total thickness (mm)** is **Blue–green–red**; an explicitly chosen
property palette is preserved.

Use **Project → Open JFEM results…** (also available on the opening screen)
to choose a `.jfem` result file from any folder with the normal system file
browser. Boxer reads the mesh and all stored result states in the background,
then displays the complete model together. The original deck is not required.
Use the Results case selector for static subcases and the mode list for
eigenmodes. Version 5 and 7 buckling files also expose their static preload as a
separate analysis. Eigenvalue files without an analysis identifier do not distinguish SOL103
from SOL105; choose the analysis that produced the file when prompted.

Archived results are a read-only view. They retain GRID/EID/PID IDs, shell
thicknesses, bar/rod areas, displacements, rotations and exported field slots.
Bars without a stored section shape use an area-equivalent display section;
solids have inspectable full volume connectivity and shaded exterior faces.
Shared interior faces are hidden. Quadratic tetrahedra retain all ten nodes,
including midside nodes in their face tessellation. The binary does
not embed full material/coordinate definitions, the original solver input,
constraint reactions, units or convergence history. Values keep their source
unit system; unrequested static field slots can contain zero placeholders.
The original shell/bar property card type is unknown; the inspector labels
these as archived properties and retains their IDs and geometric thickness or
area. Reconstructed element axes are geometric; material axes and their
coordinate labels remain unavailable. Static binaries do not distinguish
SOL101 from SOL106 and are labeled as static archives.
Open the corresponding Study or source deck to edit, solve or calculate
sensitivities. Opening another result file replaces the archived view and
resets case selections; an invalid file leaves the previous view available.

The shared readers accept `.jfem` versions 1-7. Version 6 adds the actual node
count to each tetrahedron record, preserving both four-node and ten-node
tetrahedra; version 7 also carries an available buckling static preload.
Older archives remain readable. These format extensions retain geometry and
stored results; they do not add missing original material or analysis definitions.

Try the ready-to-open results in the [illustrated benchmark collection](../../validation/README.md).

Start with the [illustrated installation guide](<../../__Start here!__/jfem_2026_installation_guide.pdf>)
or the [OS-specific setup instructions](<../../__Start here!__/README.md>).

![JFEM-Boxer displaying a generated lifting-surface model](<../../utils/images/fgen-model.png>)

**Geometry** groups **Planform**, **Airfoils**, **Loft** and **Movable surfaces**. In Airfoils, each root,
tip or intermediate section can use a NACA code, the catalogue, or **XFoil file**.
Browse to a local coordinate file; its normalized coordinates and filename are
embedded in the Study and TOML definition, so reopening does not need the
original file or a network connection. The [XFoil coordinate formats](https://web.mit.edu/drela/Public/web/xfoil/xfoil_doc.txt)
describe a contour from the trailing edge around the leading edge and back to
the trailing edge, with an optional name line. These are geometry coordinates,
not polar or pressure-coefficient output.

In **Loft**, add optional **Target t/c** stations: `0.12` means a maximum
chordwise thickness of 12% of local chord. The generator scales the blended
section's half-thickness about its unchanged mid-camber line. This changes the
shared aerodynamic/structural outer geometry, rather than the shell property
thickness. Clear the schedule to keep the selected airfoils' original thickness.
The separate **Twist** schedule accepts multiple eta/angle pairs in degrees,
including nonzero root twist. Clear it to restore the original zero-root to
**Tip twist** law. The twist schedule, its interpolation, twist axis and fallback
Tip twist value are grouped in the same **Twist distribution** box.

Each schedule independently selects **Linear**, `w=s`, or **Cosine**,
`w=(1-cos(πs))/2`, between adjacent eta stations, where
`s=(eta-eta_i)/(eta_j-eta_i)` and `value=(1-w)value_i+w value_j`.
Cosine gives zero interpolation slope at the anchors. Outside the entered
range, the nearest value is held constant; one station defines a constant
schedule. Airfoil shape interpolation remains a separate choice in Airfoils.

In **Movable surfaces**, use **Add movable surface** to define a flap, aileron,
slat, elevator, rudder, tab or other named surface. Set its leading/trailing
edge, start/end semi-span fractions (eta), hinge x/c at each end, preview
deflection in degrees and color. Hinge x/c interpolates linearly between the
span limits. Adjacent surfaces may share an endpoint; overlapping footprints
are rejected. The plan drawing shows neutral footprints and dashed hinge cuts;
the 3D preview rotates the trimmed loft about the straight axis joining the two
midcamber hinge endpoints. Positive deflection lowers a horizontal trailing
edge. Use the question-mark help for the sign convention and curved-loft limits.
Definitions save with the Study and TOML and respect the Planform editing lock.
Surfaces without an enabled structure are **geometry previews** and do not
change FE results. Use **Structure → Movable surfaces** to add their shell
structure and attachments. Editing geometry then invalidates the corresponding
FEM, just as changes to the main box do.

In **Structure → Movable surfaces**, select a geometry and click **Add structure**.
Set skin, web and rib materials from the Materials library, their thicknesses,
rib bays and mesh subdivisions. The generated monolithic shell structure has
upper/lower skins, a hinge closure web, optional secondary spar and end/internal
ribs sharing nodes. Each component has separate properties per movable rib bay.
**Secondary spar fraction** is measured from the hinge toward the outer edge;
zero omits it. **Mesh at preview deflection** uses the geometry angle in the
actual FE mesh; otherwise the structure is generated in its neutral position.

Each attachment specifies a hinge eta, physical main-box rib and front/rear
spar. The default **Restrained hinge** uses translation stiffness in N/m,
tilt stiffness in Nm/rad and hinge/actuator stiffness in Nm/rad, all **per
attachment**. The local x-axis follows the straight hinge axis; actuator
stiffness acts about x and tilt stiffness about y/z. The initial values are
modeling examples to be replaced with joint data. A zero actuator value gives
a free hinge and may leave a rigid-body mode or prevent static equilibrium
under hinge torque. **Rigid attachment** joins all six relative DOFs exactly.
Massless RBE3/RBE2 fittings distribute the load to the selected box spar/rib
and movable hinge web. Inspect the fittings and their coordinate systems in
Display or Inspect. Study and TOML files retain all these settings.

Click **Create FEM** after edits. The added structure contributes mass and
stiffness to FE analyses and enabled structural inertia loads. Use **Distributed**
structural mass to retain its hinge dynamics. Its footprint must remain outside
the adjacent main-box spar; turn off the existing Leading Edge structure before
meshing a leading-edge movable surface. VLM continues to use the original
common loft and does not automatically load these new surfaces. The fittings
represent idealized load paths, without bearing contact or bracket detail.

All 2D drawings provide exact **View zoom (%)** entry. Hold **Alt** while using
the wheel for one tenth of the normal zoom step; combine it with **Ctrl/Cmd**
for fine image-only scaling. To register a reference image, choose **Pin image
point**, pick a point on the image, then its matching point in the drawing.
The image moves to align those two points immediately. Subsequent zooms keep this match fixed until you clear the pin or move the image
independently. **Filled figures** switches the dimensioned plan view between
filled areas and outlines. Image alignment, pins, zoom and fill visibility are
saved with the Study's drawing settings.

Use **right-button drag** to pan any 2D drawing, including the detached
**Dimensioned plan view**. Drag with the left button around the region to enlarge; window zoom is
available immediately without choosing a tool. Middle-drag does not pan.
Geometry handles retain their editing gestures; **Window zoom** also allows
selection over these handles. Hold **Ctrl/Cmd** while right-dragging to move
only the reference image. The window expands to the canvas aspect ratio
without distorting geometry; a very small selection does nothing. Press **Esc**
to cancel window zoom. Panning remains available while other drawing tools are
selected.

**Structure / Spars**, **Ribs** and **Stringers** use the same untwisted plan
background: lifting-surface outline, structural box, spar paths and rib datums.
Each drawing has its own camera and reference image. **Maximize** gives Spars,
Ribs and Stringers a large drawing beside an independently scrolling parameter
column. The rib editor retains
its draggable position and angle handles. The stringer drawing shows pitch,
segment angles and approximate run-outs before generating the FEM. A reference
run-out ends the normal stringer at the preceding physical rib datum and shows
its connector to the spar immediately outboard. When the current FEM is
available, it shows the actual upper/lower attachment paths and connectors;
after geometry edits it returns to the labeled reference preview until the FEM
is rebuilt. Large layouts sample only the drawing, preserving the complete
model. Right-button pan, exact zoom, window zoom, grid, dimensions and SVG
export work in all three views.

In **Image settings** (or **Image tools** in the dimensioned plan), **Image
zoom (%)** changes only the reference image; 100% fits it to the initial drawing
area. **Window zoom image** enlarges the selected image region while keeping
geometry fixed. An unpinned selection is centered; a pinned image scales about
its registered point to retain the match. **Width / height** sets the displayed
image aspect ratio by stretching its horizontal axis about its center or pin.
**Original ratio** restores the image file's proportions. These controls never
change model geometry. Image proportions, alignment and pins are retained in
Studies, TOML and SVG exports.

On Windows, double-click **JFEM-Boxer.cmd** in `__Start here!__/Windows`, at the
repository root, or in this app folder. Setup builds the shared JFEM/app sysimage automatically; the launcher checks
and loads it. The Julia entry point is **JFEM-Boxer.jl**. Existing `.wingfem.json`
studies and internal parameter keys remain readable.

**Structure / Stringers / Stringer elements** selects the existing **Beam**
T-section or **Shell** webs with an attached flange. In **Properties / Stringers**,
set **Stringer flange width** to **0** for a blade without a flange; panel-table
overrides can do the same for individual panels. Positive flange widths refine
the skin at their edges and share its nodes. Each flange footprint replaces the
skin faces there with one combined property: **thinnest adjacent skin thickness +
specified added flange thickness**. The thinnest skin is selected from either
side of that flange, within the same skin and rib bay. Equal-thickness ties use
the lowest property ID. Skin outside the footprint remains unchanged.
Web and combined flange have separate properties for each panel. Matching
monolithic materials use a PSHELL when centered; different materials, composite
layers or inward offsets use a combined PCOMP. The skin is included once in
stiffness and mass. No normal
stringer beam is retained in shell mode; small run-out connectors remain beams.

In **Properties / Stringers**, the added-flange material initially follows the
stringer material, including panel overrides. Clear **Use stringer material**
to assign a separate monolithic material or sandwich. For a sandwich flange,
**Stringer flange thickness** remains its total added thickness; the core is
that total minus twice the face thickness. Panel thickness overrides use the
same rule. The combined PCOMP places added-flange layers inside and the selected
skin layers outside, preserving their individual materials and thicknesses.

For shell stringers, **Blade direction** follows the inward skin normal or a
selected coordinate-system **X**, **Y** or **Z** axis. ID **0** means global BASIC;
a positive ID selects a generated skin, spar or rib frame visible under
**Display / Axes & labels**. The inward sign is selected on each skin. An axis
tangent to the skin is rejected. Coordinate IDs follow the current mesh, so
check the selected frame after changing its discretization.

**Mesh / Elements through stringer blade height** sets the nominal blade layers.
Bay height changes may introduce extra layers to keep shared boundaries
conforming. Spanwise refinement follows **Elements per rib bay**. Flange
edges add chordwise columns; **Elements between stringers** subdivides
the remaining gap between their footprints. The shell
idealization centers the combined flange section on the skin reference nodes by
default. **Structure / Stringers / Offset attached flanges inward** keeps the
original selected skin outer face and places the added material inside the box.
It uses the PCOMP reference plane (Z0), retaining bending coupling and mass
eccentricity, without moving the nodes. **Display / Appearance / Shell thickness**
shows these physical bounds. Web depth is overall height minus added flange
thickness (the full height for a blade without a flange).
With distributed structural mass, combined PCOMP flanges automatically request
consistent mass (`PARAM,COUPMASS,1`) so modal analysis retains the laminate's
through-thickness mass eccentricity and rotary inertia. The optional rib-bay
concentrated-mass model continues to use its aggregated mass and inertia.
Rib attachment is through the skin/flange footprint; blade interiors
crossing rib webs are not welded to them. Overlapping flange footprints are
rejected. Shell stringer mass is distributed through these plates, and added
stringer mass in kg/m is applied once through the web.

Shell-stringer sensitivity variables include web thickness and materials.
Flange width, overall height and flange thickness change the mesh geometry and
are excluded from the fixed-mesh property adjoint. They remain editable model
inputs and require regenerating the mesh and rerunning an analysis.
Combined PCOMP flange sections, including inward-offset sections, require
**Operator differences** for supported linear sensitivity analyses; the exact
adjoint does not yet support their laminate coupling and reports this explicitly.
When adjacent skins have the same minimum thickness, a variable changing only
one of those skins has no unique derivative of the minimum. Such local variables
are omitted from the catalogue; shared variables moving all tied skins together
remain available. Strictly thinner skins retain their dependent flange properties
in the sensitivity calculation.

**Display constraint reactions** shows the reaction arrows. The separate
**Label constraint forces and moments** toggle immediately below it shows signed
force components in N and moment components in N·m. Both controls are available
in FE Results and Display / Loads&Constraints, including static preload results.
Labels become available when reaction arrows are shown for a result with reactions.

Right-click and drag on the model to pan: the point under the cursor stays under
it throughout the drag. Dragging empty space uses a plane through the camera
target. This works in both perspective and parallel views and preserves the
middle/right-button CATIA zoom gesture.

Load cases support true airspeed in m/s, knots or Mach and altitude in metres,
feet or flight levels. ISA 1976 provides pressure, temperature, density and
sound speed. FL300 means pressure altitude 30,000 ft. Existing studies with
manually specified atmosphere data retain that setting until ISA is selected.

**Analysis / Sensitivity / Inspect** lets you pick the response GRID or element
without leaving the sensitivity form. Saved runs let you reopen earlier results
without solving again; the run directory must still exist and model identity is checked.

**Display / Mass properties** offers one combined structural mass ellipsoid per
physical rib bay, anchored at the bay center, and separate fuel inertia
ellipsoids. Structural mass, its true center of gravity and its inertia are
aggregated across the bay's skins, webs, caps and stiffeners; an interior rib
contributes half to each adjacent bay. **Environment** includes ground Shadows and Self
shadows; both are display settings. **Entities** separates Connections from Constraints.

Project provides **Read Reference** for bulk-data decks and **Read Abaqus**
for `.inp` and `.inp.gz` files. Both use the existing imported-model workflow.
Restart the application after updating; reimport external decks when reopening an older imported Study.

**Display / Axes & labels** greys out rib and stringer labels when the model has
no physical layout metadata. **Coordinate IDs and types** also enables the
coordinate glyph layer. Coincident origins share a compact label; the coordinate
selector identifies every CID, its type and parent frame separately. These
reference labels remain visible when their origins lie inside opaque structure.
Panel isolation has an independent **Panel IDs** toggle saved with the Study.
A newly defined wet fuel tank is shown by default; an explicit hide is retained.
Dry/vent bay inputs accept physical bay numbers and ranges such as `2,4-6`:
bay `b` lies between ribs `Rb` and `R(b+1)` and contains no fuel capacity or mass.

Airfoil previews dimension the maximum thickness and camber, relative to chord,
and their `x/c` locations. The midcamber curve averages upper/lower ordinates at
fixed `x/c`; extrema use the actual sampled piecewise-linear surfaces. Between
stations, `t=(eta-eta_i)/(eta_j-eta_i)` and each surface ordinate is blended with
`w=t` (Linear) or `w=(1-cos(pi*t))/2` (Cosine). Cosine gives zero blend slope at
each station; chord, twist and planform transformations follow the section blend.

Detached tables in **Properties / Spars**, **Ribs** and **Leading Edge** edit
webs, caps, stiffeners, skins and leading-edge ribs by physical rib or bay.
They support materials, applicable section dimensions, sandwich layers and
inherited defaults. Edits save with the Study/TOML and mark results stale;
analysis starts only when requested. The skin/stringer panel tables remain
available with the same dark-blue button style.

**Properties / Mass** selects the structural mass representation:

- **Distributed shell and bar mass** is the default and retains element mass
  for detailed local and global vibration modes.
- **Concentrated mass per rib bay** places one structural CONM2 at each bay's
  center GRID, coupled to its bounding ribs through an RBE3. It retains the
  bay's total mass, true center-of-gravity offset and central inertia, while
  removing distributed structural density and non-structural mass from the
  exported element cards to avoid counting them twice. This is a reduced mass
  description for global modes; local panel and stiffener vibration needs the
  distributed option. Fuel remains a separate mass at the bay reference.

The choice is saved with the Study and marks previous results stale. Run the
analysis explicitly after updating the model. The ellipsoids show bay totals
with either solver representation; changing their visibility changes no physics.

The same form assigns non-structural kg/m² to upper/lower skins, spar/rib
webs and leading-edge skins/ribs, and kg/m to stringers, spar caps, rib stiffeners
and run-outs. Each structural-group value applies across bays and contributes
to dry mass, inertia loads, exported properties and solver mass. Values default
to zero and save with the Study. This form is for generated models; imported
decks retain their own non-structural mass, including PCOMP values read from
BDF or raw JSON. These values are not currently sensitivity design variables.

**Displayed load case** selectors in Geometry, Mass properties, Inspect,
Summary, Loads and FE Results stay synchronized. They switch the displayed
loads, fuel state and available results without solving or changing the Study
definition. Sensitivity results retain their recorded analysis case; choose a
different saved sensitivity run to view derivatives for another case.

**Summary / General** and **Summary / Mass properties** have **Export summary**
buttons for **CSV**, **Markdown (.md)** and **HTML**. Select the displayed load
case before exporting. The files capture the current summary tables and text,
including units, model/source identification, load case, export time and any
stale-data indication. CSV opens in a spreadsheet; Markdown works in text and
documentation tools; the styled HTML file opens or prints independently in a
browser without Boxer or a network connection. Exports are disabled until a
model provides summary tables. Downloads use the browser's selected download
folder; enable its **Ask where to save each file** setting to choose a folder.

**Undeformed aero** and the deformed aerodynamic loft controls are grouped
together in **Display / Geometry / Aerodynamic geometry**.
Each geometry entity groups its visibility and appearance controls together.
Choose **Show loft intersections**, select **Color** (cyan by default), and set **Number of cuts** (1–200)
to slice the displayed aerodynamic loft at equally spaced internal span planes.
For N cuts their positions are `eta = i/(N+1)`, for `i=1…N`; root and tip are
excluded. The intersections use the rendered loft triangles, follow the active
deformation and magnification, and can remain visible with the loft surface
hidden. The planes retain their undeformed span positions. Changing the count
does not remesh or rerun the solver. Imported models without an aerodynamic
loft have these controls disabled. Visibility, count and color are saved in the Study.

Each physical rib bay now has separate front/rear spar-web properties and four
separate spar-cap properties (front/rear, upper/lower). Rib webs and stiffeners
are separate by rib; leading-edge skins are separate by bay and leading-edge
ribs by rib. These local properties exist even without overrides and inherit
their shared defaults. They provide independent component sensitivity variables.
Regenerate the FEM and rerun analyses to use the new property IDs.

In **Analysis / Sensitivity**, component family selections expand into their
independent bay/rib variables, including overridden properties. Reading model
properties converts older shared-component selections and saves the local IDs
with the Study. Individual locations can be deselected. **Run sensitivity**
computes a separate derivative for each selected location; no analysis runs
automatically. Material variables keep their shared scope. Historical tables
retain their recorded shared results until a new analysis is explicitly run;
one shared derivative is never copied or divided among bays.

Sensitivity data offers a **red-negative / blue-positive** palette, with
unit-specific scales fitted to the displayed values. Numbers use at most five
significant digits; CSV retains full precision. Units sit beside the scales.

**Display / Axes & labels** includes RBE3 component, weight and UM markers.
**CELAS properties and coordinate axes** labels visible springs with their
element ID, PELAS property or directly specified stiffness, and each endpoint's
DOF and GRID displacement coordinate system (CD, type and parent). Scalar or
grounded endpoints have no spatial axis; stiffness values use source deck units.
**Display / Appearance** can draw CELAS components as symbolic cylinders,
colored x red, y green and z blue in each endpoint's coordinate system.
The adjacent **Radius** input sizes these display symbols independently of
other markers: metres for generated models, unconverted source length units
for imported decks. The default is 0.01; the setting is retained in Studies
and changes no spring stiffness or physical dimensions.
The **Loads** dropdown contains Visualization, VLM settings and Load plots.

In **Loads → Load plots**, **Section lift coefficient × chord · cₗ c [m]**
overlays a dashed elliptical reference with the same signed total lift as the
selected case. Both traces are strip averages: the ellipse is integrated over
each actual strip, including nonuniform VLM spacing, rather than sampled at
its centre. Negative lift reverses the reference; zero net lift gives a zero
reference. The load multiplier scales both curves. The reference uses the full
aerodynamic semi-span, even where the structural box stops before the tip.

For VLM cases, the plot also shows the full-wing lift coefficient `CL`, induced
drag coefficient `CDi`, aspect ratio `AR = span² / area`, and **inviscid span
efficiency** `e = CL² / (π AR CDi)`. `CDi` comes from the VLM far-wake calculation;
these aerodynamic coefficients precede the structural load multiplier. The
efficiency is the inviscid counterpart of the Oswald factor, without a fitted
viscous/profile-drag correction. An ideal planar elliptical loading has `e = 1`;
nonplanar configurations are not artificially capped at 1. See
[NASA's induced-drag explanation](https://www1.grc.nasa.gov/beginners-guide-to-aeronautics/induced-drag-coefficient/).
Prescribed-load cases still show the equal-lift reference, but do not invent a
drag coefficient or efficiency. Undefined ratios, including zero lift with
zero induced drag, remain unavailable.

SOL105 results include the actual **SOL101 preload** as a separate analysis
alongside buckling modes. Export recovers requested stress, force and reaction
fields from the retained static state without repeating the equilibrium solve.
Older outputs may contain only preload displacements. Eigenmode amplitudes
remain normalized independently of static deformation.

The complete application source and browser libraries are in this directory.
Run setup once to prepare the shared Julia environment, then open the app launcher.

## Install and start

Read the [illustrated JFEM-Boxer user's guide](../../Reference_documentation/00_Getting_Started/jfem_2026_fgen_user_guide.pdf)
for the complete workflow with screenshots.

Install **Julia 1.13.1**, then clone the repository:

```sh
git clone https://github.com/r-acad/JF_2026_05_25.git
cd JF_2026_05_25
julia APPS/JFEM-Boxer/setup.jl
julia --project=. APPS/JFEM-Boxer/JFEM-Boxer.jl
```

`APPS/JFEM-Boxer/setup.jl` delegates to the same unified installer as the repository-root
`setup.cmd` (Windows) or `bash setup.sh` (macOS/Linux). The installer prepares
one root environment and verifies JFEM, JFEM-Boxer, PANDEATOR and the static viewer.
The shared sysimage is built automatically as part of setup. The first setup can
take several minutes while Julia downloads and compiles packages. All apps use
the same package versions and source tree.

The app opens a browser at `http://127.0.0.1:8080`. If the browser does not open,
visit that address manually. It is a local desktop web app, not a hosted service.
Keep its terminal open while using it. Stop the server with Ctrl+C in that terminal.

Alternatively, run the launchers in this directory:

- Windows: `setup.cmd`, followed by `JFEM-Boxer.cmd`.
- Linux/macOS: `sh setup.sh`, followed by `sh run_fe_generator.sh`.

The repository may be cloned to a different folder name, including a path with
spaces. JFEM-Boxer uses the enclosing OpenJFEM source and the repository root
Project/Manifest. Keep the complete checkout together.

Useful command-line options, from the repository root:

```sh
julia --project=. APPS/JFEM-Boxer/JFEM-Boxer.jl --port 8090 --no-browser
julia --project=. APPS/JFEM-Boxer/JFEM-Boxer.jl --reference
julia --project=. APPS/JFEM-Boxer/JFEM-Boxer.jl /path/to/my_wing.toml
```

Without a specified input, the first start creates a writable
`input/wing_input.toml` from [examples/wing_default.toml](examples/wing_default.toml).
Later starts retain that input. The example is a factory definition, not a user
Study. Generated decks, caches and solver jobs go under `output/` by default.
Relative output paths are resolved from this application directory.

Internet access is needed for initial Julia dependency installation. The normal
viewer uses bundled JavaScript. NACA profiles work locally; downloading a new
UIUC database profile or importing remote resources requires access to its
source. Previously embedded airfoil and reference data travel with a saved Study.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for vendored components and
optional external-resource details.

## First study

1. In **Study Options**, choose **Start new study**, **Load last study**,
   **Open existing study**, or **Read Reference file**.
   **Open existing study** shows the same newest-first catalogue as
   **Project / Load Study**, with all studies previously saved or opened at
   this browser address. Open a linked disk file or its identified stored copy,
   or use **Browse for a Study** to select another file. Closing the catalogue
   returns to Study Options; cancelling Browse leaves the list available.
2. Define the planform, airfoils, spars, ribs and optional leading-edge mesh.
   Planform edge perturbations refine the aerodynamic outline; spar perturbations
   define the structural spar paths independently.
   **Structure / Stringers** contains default pitch, global or rear-spar-segment
   angles, and the normalized **Run-out threshold**.
3. Use **Model / Structural Mesh** to create or refine the FEM. Live mesh
   rebuilds it after valid edits. Geometry and mesh locks help retain the layout
   while assigning properties.
   **Vertical elements: spars, ribs and leading edge** is a shared positive
   integer (default 3). Refinement retains common nodes at the front-spar and
   leading-edge interfaces; it does not create disconnected coincident meshes.
   **Leading-edge skin elements, nose to spar** independently sets the chordwise
   shell divisions on each leading-edge skin (2–100, default 8), using the saved
   `leading_edge.chord_elements` key. Spanwise rows still follow Elements per rib
   bay. **Aero chord points** samples the displayed wetted loft and optional
   disconnected aero-shell export; it does not refine structural skins or VLM.
   Leading-edge rib angles are measured from the **local front-spar segment at
   each attachment**, toward the nose; 90 degrees is perpendicular. If an
   attachment is exactly at a spar kink, **Spar segment at a kink** chooses the
   inboard or outboard tangent. Individual rib overrides can inherit that choice
   or choose their own side. Root/tip attachments use their only adjacent segment.
   The Spars drawing includes the physical rib datum lines. **Snap to rib** beside
   a perturbation point moves its eta onto the nearest available rib datum while
   preserving delta x/c; it also handles oblique rib datums. This is a one-time
   edit, not a persistent geometric constraint. Eta and x/c field arrows use 0.1
   increments; typed values retain their full precision.
4. Define materials, skins, stringers, ribs, spars and leading-edge properties
   under **Model / Properties**. Detached panel tables assign local overrides;
   blank entries inherit the shared values. Rows are stringers, columns are rib
   bays, and P-numbers match the panel display.
   All property tables color the active field using its actual effective range
   and units, with a choice of palettes. Material fields use named swatches;
   inactive sandwich fields and disabled stiffeners stay neutral. The Leading
   Edge properties tab is enabled after defining a leading edge.
5. Define constraints and cases. Cases include aerodynamic settings, load multiplier,
   fuel state and inertia options. Aerodynamic loads use rib-plane RBE3s; mass
   loads use rib-bay-center references. The default multiplier of 1.5 converts
   specified limit aerodynamic loads to ultimate loads.
6. Use **Analysis / FE Analysis / Run in JFEM**. Open **Results / FE Results** for displacements, shell/bar
   stresses and forces, modes, buckling or linear/nonlinear comparisons.
7. **Save Study** stores the complete model definition, display settings and
   selected portable reference data. **Save TOML** exports the text definition.
   The first save chooses a destination; subsequent saves update that linked
   file. **Save Study as…** selects another filename and folder. The Save Study
   button is orange for unsaved definition changes and green after saving.
   Camera, palette and display edits leave its status unchanged; an explicit
   save still captures their current settings. If the browser picker is unavailable
   or blocked, a system Save dialog lets you choose any accessible folder. If no
   system dialog is available or it fails, the app explicitly offers a browser
   download; canceling that offer leaves the Study unsaved. Browser downloads
   use the browser's download settings, so enable **Ask where to save each file**
   to choose a folder. Windows system dialogs are called directly through Julia
   and the Windows file-dialog API: no unsigned PowerShell script is executed,
   and no execution-policy changes are needed.

**Autosave**, to the left of **Live mesh**, saves significant definition edits
after they settle, including geometry, properties, loads, notes and selected
design variables. Enabling it makes an initial save to the linked Study file,
choosing a destination if needed. Subsequent background saves keep property
editing available and combine rapid edits. Camera and display changes alone do
not trigger saves. Autosave reuses the browser or system-selected file without
reopening the dialog. System file links last for the running app-server session;
after restarting it, use **Save Study as** to select the file again. If you chose
a download because neither picker was available, Autosave keeps a persistent
browser recovery copy and never downloads repeatedly. Write or storage errors
leave Project orange and explain what remains unsaved.

The definition is saved independently from solved results. Exported decks and
solver result files remain in their run directories. A stale model/result is
identified in the GUI rather than being silently presented as current.

The **Deck** tab caches the current deck and lays out large text in contained
blocks, so reopening or resizing does not relayout every line. The complete text
remains searchable, selectable and downloadable. New Write deck or solver output
replaces the cache; pane dragging coalesces viewport resizing to animation frames.
**Find first** (or Enter in the search box) highlights the first literal match
in the displayed case deck, scrolls to it and reports its line/column. Search
ignores case unless **Match case** is checked. Escape clears the highlight.
Large-deck search changes only the matching text chunks; copying/downloading
still gives the original deck text.

The **Project** dropdown groups New Study, Study/TOML reading and saving,
Read Reference, Read Abaqus input, Write deck, geometry export and
configured-input operations.
**Export geometry…** opens the STL/GLB options. Save Study retains its orange
or green saved-state indicator inside the menu. The Project button is orange
for unsaved definition changes and green when the definition is saved;
navigation and display changes do not affect it.

Recent-study actions include explanatory tooltips. **Open latest disk file**
reads the linked file, including changes made outside this browser. **Open
stored copy** opens the last saved or loaded browser snapshot, useful when the
disk file is unavailable; it does not link that snapshot for disk overwriting.
**Relink file…** selects the file again after it moves or browser access is lost.

Manual **Save Study** and **Save Study as…** offer an optional change/intent
comment and show previous comments. Each successful save appends changed,
nonempty text with its timestamp; canceled or failed saves do not append it.
Autosave remains silent. **Show comments** in the recent-study list previews
the stored copy without loading it. Opening a selected file also previews that
file's comments before **Load Study**, so the current model can be kept intact.

An undefined **Fuel tank** has a grey tab label and a **Create Fuel Tank** button.
Click it to enable the full tank form. The **Dimensioned plan view** draws wet
tank bays and marks dry/vent bays along the actual rib and spar boundaries.

**Plan View** is blue when a generated lifting-surface drawing is available and
disabled for imported Reference decks. Panel isolation, explosion and panel-property
tables are unavailable when the model has no stiffened panels.

### Read an existing Reference deck

**Project / Read Reference** opens a complete `.bdf`, `.dat` or `.nas` deck
using the native JFEM parser. By default, **Browse** selects a file on the
JFEM-Boxer computer, or you can paste its full path. INCLUDE files are read
automatically relative to their containing files. The former 32 MiB import
limit is removed. Import progress shows elapsed time and the current stage;
errors remain fully visible in the import dialog.

Opening another BDF starts with a fitted isometric view, default entity
visibility, expanded lists and fresh case/result/sensitivity selections. Filters,
external references and analysis results from the previous model are cleared
only after the new deck loads successfully. A failed import leaves the previous
model available. Opening a saved Study restores its saved display settings.

Read Reference opens the normal Windows **Open** dialog immediately. **Browse**
reopens it; the selected full path remains editable in the import form.
Cancel returns to the form, and **Read deck** starts the import. The dialog
runs in a small Julia child process and calls the Windows API directly, so
Windows restrictions on unsigned PowerShell scripts do not affect this picker. The Windows picker supplies the
actual folder so INCLUDE files can be resolved without selecting them again.
On other platforms, paste the main deck's full local path. Parser preparation
starts while you choose the file, with a stage and timer. The first import can
include Julia package loading and compilation; later imports reuse the parser.
The import-only worker loads the parsers, model definitions and viewer support
without starting the numerical solver or loading its analysis/export pipeline.
It stays warm for subsequent imports; **Run in JFEM** starts or reuses the
separate analysis worker when a solve is actually requested.
The Log reports source/INCLUDE reading, parser startup, native model creation,
viewport conversion and delivery separately. Preparation runs no analysis and
does not modify the current Study.

The previous complete model remains on screen while the new one is decoded
and prepared. Geometry, property visibility and camera are committed together;
an import error restores the previous view. Logs separate transfer, decoding
and viewport preparation. Large imported property groups use preallocated axis
buffers, and viewport material/visibility updates are batched to avoid repeated
whole-model work. These optimizations preserve element/property identities,
case-specific constraints and loads, and inspection data.

Large imported models retain their individual property groups for visibility and
inspection, while sharing bounded GPU geometry batches. Entity lists are paged
instead of creating thousands of controls at once. Binary arrays and repeated
material records share transport storage; native model data is restored only
when a later backend operation needs it. Import still includes building material
and composite constitutive data, preparing viewer geometry and caching the model.
These stages can exceed the time spent reading and parsing a large deck; the
stage timings in Log distinguish them from file I/O and from an analysis solve.
Fit view and context planes use the connected structural extent by default, so
distant orientation or unused GRIDs do not dwarf the model. Showing all GRID
markers includes their full source extent; no source nodes are removed.

The form needs only the main file on your computer; no model-folder selection
is required. Missing files and cyclic INCLUDE dependencies are reported.
A local import is saved as a self-contained expanded source in the Study, so
reopening does not depend on the original file locations. **Study Options**
also offers **Read Reference file** directly at startup.

**Loads / Cases** displays imported case-control settings, selected load sets,
equivalent nodal loads and the source-card inventory. **Model / Constraints**
displays the selected case's effective SPC constraints, prescribed values,
source sets and GRID displacement coordinate systems. Both selectors update
the viewport. Click a GRID in the tables to inspect its conditions and results.
Tables can be filtered and paged for large models. Constraint cones and rotation
boxes follow each GRID's displacement axes, including non-BASIC coordinates.
The inventory reports cards without a native interpretation; retaining every
source card does not imply that every Reference formulation is supported.
Linear static solves apply selected SPCD prescribed values before constraint
recovery, overriding SPC values without double-counting them. SOL106 currently
rejects nonzero prescribed SPC/SPCD motion with an explicit capability message;
it must not silently solve a different boundary condition.

Coordinate systems are available in **Display > Entities**, with optional
CID/type labels in **Axes & Labels**. Labels also identify the parent RID for
CORD2 definitions (including BASIC 0), or the defining G1/G2/G3 nodes for CORD1.
Their triads use resolved BASIC origins
and defining axes for rectangular, cylindrical and spherical systems.
Generated shell MCIDs retain their actual shared BASIC origin; element-centered
shell axes remain a separate display. **Inspect** also accepts coordinate IDs
(including 0), rigid connections, springs and concentrated masses. Miscellaneous
element families use distinct pink/magenta/violet colors, with pickable lines
and mass/zero-length-spring markers and retained source properties.

The imported source is authoritative: original GRID/EID/PID values,
subcases, constraints and loads are retained. **Analysis > FE Analysis > Imported deck analysis**
selects the original solution or SOL101, SOL103, SOL105 or SOL106. An analysis
override creates a separate run deck; it never modifies the stored source or
regenerates wing geometry. SOL105 adds a buckling companion for each static
case. Imported SOL106 runs only the selected nonlinear solution. Modes and
nonlinear convergence controls appear for the corresponding solution.

Concentrated FORCE loads can keep their source settings, use fixed directions,
or follow nodal rotation in SOL101/SOL106. SOL101 uses the first-order load
tangent; SOL106 updates directions during nonlinear iterations. MOMENT,
pressure and body loads stay fixed. Modal/buckling overrides reject retained
follower FORCE cards; choose fixed directions for those analyses. Source
geometry and analysis options both participate in result compatibility checks.
Study files preserve these options. **Run in JFEM** solves the selected deck;
**Results** displays its supported physical fields. **Inspect** and
**Display / Properties** show native shell/beam/material data where supported.
Cards without a viewport representation are reported and remain in the source;
solver support is still governed by JFEM. Displayed units assume consistent SI
input because Reference files do not declare a unit system.

**Bars 3D** preserves explicit section shapes. Where only an area is available,
it shows an equal-area square for bars/beams or a polygonal circular section for
rods. These are display approximations and do not infer section inertias.
**Display > Appearance > Shell geometry > Physical thickness** extrudes the
property thickness, including laminate Z0. Midsurface remains the default.
Imported element-level ZOFFS and corner thickness overrides are not represented
by this display. Filled shell state is restored when layers are re-enabled,
including after sensitivity and FE-result changes.

Imported Run preparation streams the deck bytes for checksums and reuses the
imported source without restoring the native graph in the GUI process. Log
separates preparation from worker parsing, assembly and solve. A first request
can still include Julia compilation; the solver worker independently reads and
assembles the chosen run deck.

Imported static sensitivities use analytic adjoints for supported PSHELL,
symmetric isotropic PCOMP, MAT1 and T/BAR/ROD PBARL variables. The catalog and
failed-row messages identify unsupported formulations and load-derivative
branches; no finite-difference fallback is used. Imported modal/buckling
sensitivity objectives are unavailable. Generated wing sensitivities retain
their existing modal/buckling support.

**Save Study** embeds the original deck and INCLUDE sources along with view
settings, references, notes and sensitivity setup. Reopening reparses those
sources; it does not depend on an old server token. **Write deck** produces a
self-contained deck with INCLUDE text expanded. Wing geometry/property forms
and TOML export are disabled for imported models. **New Study**, **Load TOML**
or loading a generated Study returns to the wing generator.

### Read an Abaqus input

1. Choose **Project / Read Abaqus**, or **Read Abaqus input** on the opening
   screen. On Windows, select the local `.inp` or `.inp.gz` file in the normal
   system dialog. On other platforms, enter its full path on the Boxer server.
   Gzip inputs are decompressed automatically; `*INCLUDE, INPUT=...` files are
   resolved relative to each containing file.
2. Leave **Add the material, constraints and analysis below** unchecked to
   inspect a mesh without supplying missing physics. Readiness diagnostics
   explain missing or unsupported data. **Run in JFEM** is disabled until a
   supported, complete analysis has been defined.
3. Inspect named **Node sets**, **Element sets** and **Surfaces** under
   **Analysis / FE Analysis / Imported deck analysis**. Loads and constraints
   are shown for the selected source step. Solid picking identifies the original
   volume-element ID, property and complete connectivity; exterior faces are a
   display tessellation, not replacement solver elements.
4. For a solid mesh with no authored materials, sections, constraints or steps,
   enable the explicit setup. Enter Young modulus, Poisson ratio and density;
   select **ALL** or an element set covering the complete mesh. Enter the
   constrained node-set name and fixed translation components, where
   `1=X`, `2=Y`, `3=Z`. Multiple constraint sets use semicolons, for example
   `BLOCK_FIXED;CYLINDER_TO_BLOCK`.
5. Select **SOL101 (linear static)** with a force node set, total force and
   direction, or **SOL103 (normal modes)** with a positive density and requested
   mode count. Static completion normalizes the direction and distributes the
   total force equally among the selected nodes. The value is a resultant,
   not a force repeated at every node or a uniform face pressure. Choose
   **Read deck**, then run the completed analysis normally.

**Units and saved Studies.** The input reader performs no unit conversion.
Geometry, modulus, density and loads must form one consistent unit system;
Boxer's displayed unit labels assume SI. Defaults in the optional setup are
visible and are applied only after its checkbox is enabled. **Save Study**
embeds the captured source and the explicit completion choices. A run uses a
separate expanded `.inp`; a source filename ending in `.inp.gz` is not used
for already-decompressed run text. Reopening the Study repeats the same setup
without depending on the original file location.

**Example: JuliaFEM/FEModels.** Obtain the `block-and-cylinder` mesh from the
[upstream model collection](https://github.com/JuliaFEM/FEModels). It contains a
hexahedral block and a quadratic-tetrahedral cylinder as two disconnected
bodies, with named sets and surfaces but no material or analysis steps. A
simple deliberate setup constrains `BLOCK_FIXED;CYLINDER_TO_BLOCK` and applies
a total force to `CYLINDER_LOAD`. This independently clamps both bodies and
loads only the cylinder; the block is unloaded. No contact, tie or interface
load transfer is created between the bodies. Choose the boundary conditions
that represent your intended model before interpreting its results.

The tower archives in that repository use Git LFS. After cloning, run
`git lfs pull`, or download the actual original file through GitHub. A small
Git LFS pointer is not the mesh, even when its filename ends in `.inp` or
`.inp.gz`. The importer identifies these small text placeholders and explains
how to obtain the real object, rather than parsing or analyzing the pointer.

**Executable subset.** Flat meshes with isotropic `*ELASTIC` materials,
`*DENSITY`, solid/shell sections and the following elements are translated into
JFEM's native formulations:

| Input element | Native topology |
| --- | --- |
| `C3D4`, `C3D10` | Four-node or full ten-node tetrahedron |
| `C3D6`, `C3D8` | Six-node wedge or eight-node hexahedron |
| `S3`, `S4` | Three-node or four-node shell |

Small-displacement `*STATIC` maps to SOL101; unprestressed `*FREQUENCY` maps to
SOL103. The supported load subset includes nodal `*CLOAD`, global gravity and
supported planar element-face pressures. Named sets, boundary constraints and
source step labels are retained. The full quadratic tetrahedral stiffness,
consistent mass, stress recovery, geometric stiffness and all midside
connectivity are available in the native solver; the Abaqus translator still
limits executable procedures to the static/modal subset above.

Part/instance assemblies, contact/ties, nonlinear `NLGEOM`, plasticity,
prestressed frequency extraction, `*BUCKLE`, and other unsupported mechanics
produce explicit diagnostics and block analysis. Reduced-integration, hybrid
and modified element variants are not silently replaced with a different
formulation. Abaqus-input sensitivities and Reference-only solution/follower
controls are unavailable in this workflow. Use a supported source step or the
explicit mesh setup; importing an element name does not establish numerical
equivalence to every formulation bearing that name in another solver.

For the source format, see the official
[Abaqus node/set definitions](https://docs.software.vt.edu/abaqusv2025/English/SIMACAEMODRefMap/simamod-c-node.htm)
and [exporting a flat input without parts and assemblies](https://docs.software.vt.edu/abaqusv2025/English/SIMACAECAERefMap/simacae-c-dbsflatteninput.htm).
These describe the upstream format; JFEM implements the subset listed here.

## Display and editing

Every left pane collapses with **−** and restores with **+**. Drawing panes
retain a separate Maximize action while expanded. **Collapse all trees / Expand all trees** changes the entity-list layout without
changing model visibility. Rib/stringer labels are under **Display / Axes & labels**;
rib datum planes are under **Display / Geometry**.
**Ribs** and **Stringers** are independent on/off checkboxes, like the datum
toggle. Enable both to show both label sets or clear both to hide them. Older
Studies using Off/Ribs/Stringers/Both are migrated without losing the choice.

**Display / Geometry** groups aerodynamic surfaces and VLM layers, individual
airfoil sections, fuel volume, undeformed/deformed overlays, ground/symmetry/rib
planes and imported reference geometry. Each available geometric layer can be
shown or hidden. Appearance controls provide colors and, for surfaces, solid,
wireframe, translucent or metallic finishes with opacity where applicable.
Individual airfoil visibility is retained when toggling the whole airfoil layer.
Reference files retain their visibility, transform, opacity and wireframe controls.
These settings are saved with the Study without changing FE materials or results.
The **Ground plane / Finish** choices are solid, wireframe, translucent and
metallic. Metallic reflects the actual visible model across the chosen ground
height. The reflection follows visibility/deformation and uses a bounded render
target only while the metallic ground is shown. Translucent provides opacity.
The current aerodynamic loft has one control; a separate **Undeformed aero
reference** appears when a deformed result can be compared with the original.

Coordinate inspection identifies frame usage: **CP** locates GRIDs, **CD** defines
GRID displacement components, and **MCID** orients shell material directions.
Generated shells each have an explicit rectangular MCID frame at BASIC (0,0,0).
Their coincident origins are intentional and do not attach them to an RBE3 node
that happens to share that position. Show shell local axes to inspect directions
at the elements. Imported coordinate locations remain those of the source deck.

Hovering a **?** now shows the explanatory text; clicking opens the full help.
Parameter help describes purpose, units, applicable ranges and the effects of
refinement or physical changes, rather than repeating field names.

The viewport supports entity filters, inspection, node/element IDs, local axes,
solid/translucent surfaces, beam sections, reference STL/OBJ/GLB geometry,
measurement and geometry export. Fuel-tank volume and mass properties include
rib-bay contributions. Panel isolation assigns distinct colors and P-labels.
While isolation is active, it controls the shell/beam visibility switches;
loads, aerodynamic surfaces, constraints and other overlays remain independent.
**Display / Properties** colors the generated shell and beam properties and
material assignments without an analysis. Values include thickness, area,
section inertias and material E/nu/density, with units and a color scale. For a
sandwich, select its face or core material; no equivalent elastic modulus is
invented. This view uses the current generated FEM and warns about pending edits.
The **Ground** toolbar control includes a synchronized elevation input, shown
only while the ground is visible. Applied
forces and moments are drawn as signed global-axis components (X red, Y green,
Z blue); their lengths/radii retain the chosen display scaling.
VLM-panel arrows are magenta and show the signed normal pressure force at each
panel center. The full aerodynamic resultant is still applied at the rib RBE3s.
Structural faces and solid beam sections use lighting to distinguish orientation,
including when quantitative colors are shown; legends retain the selected palette.
**Display → Environment → Lighting** defaults to **Bright studio**, with six
neutral lights: ambient, main, opposite fill, camera fill, underside fill and
an edge/rim light. The underside stays readable while directional shading
distinguishes skins, webs and 3D beam sections. The six preset choices are Bright
studio, Soft studio, Technical contrast, All-angle inspection, Presentation and
Diffuse daylight. Each light intensity can also be adjusted independently.
Metallic surfaces use a brighter local studio reflection, including below the
model; no online image download is needed. Numerical palettes retain their RGB
values, and shadows remain optional. Element edges use a softer slate color
and partial opacity so dense meshes do not obscure the surface colors.
Saved copies of old unedited lighting presets adopt the improved defaults;
custom lighting remains unchanged. Select Bright studio to replace a saved
custom setup with the new default. Lighting and presets are saved with Studies.

**Display / Entities / Explode stiffened panels** moves each panel and its
normal stringer rigidly away from the structural-node centroid, midspan,
its own rib-bay center, or the corresponding inboard rib center. Rib origins
follow the actual rib centers, including sweep and twist; runout panels keep
their owning bay. For a panel in R3–R4, the corresponding rib is R3.
Choose the separation distance with the numeric input or manual slider;
uncheck Explode panels to reassemble. Panel edges,
labels, axes and picking follow the displayed panel; shared GRID markers,
loads, aerodynamic geometry and comparison overlays stay at their physical
positions. This changes neither the FEM nor any result. SVG captures the
exploded view; STL/GLB retain physical geometry. The settings travel with a Study.

**Structure / Stringers / Run-out threshold** defaults to 0.75 for
new studies. A run-out is triggered when either skin's projected x-clearance
to a spar falls below that fraction of its nominal pitch. The normal stringer
ends at the preceding physical rib datum of the bay containing the trigger;
its connector starts at that datum and joins the spar immediately outboard.
Both upper and lower stringers terminate together. Mesh rows and geometry
kinks are not extra rib supports.

The ratio must be greater than zero and at most one. Legacy studies and TOML
definitions without this setting retain a clearance ratio of 1.0; they use
the same rib-datum termination rule when regenerated. Root stringer pitch is
unchanged. This changes the physical panel boundaries from earlier versions:
regenerate the FEM, reset obsolete panel overrides when requested, and rerun
analyses before using previous results.

Run-out connectors use a fixed **5 mm² square section**: side 2.2361 mm,
`I1 = I2 = 2.0833333e-12 m⁴`, and square torsional constant
`J = 3.515e-12 m⁴`. This replaces the former 1,000 mm² connector; recreate the
FEM and rerun analyses before treating older results as current.

VLM flight cases now support **Mach up to 0.5**, using a Prandtl-Glauert
wind-axis lattice transformation and physical Kutta-Joukowski force recovery.
For example, 120 m/s with a speed of sound of 340 m/s is valid. The model
assumes attached, subsonic small-disturbance flow and does not predict shocks,
stall or aeroelastic feedback. Displayed geometry and applied loads remain in
physical coordinates. The full guide documents the transformation and tests.
Previously saved generated results remain inspectable as historical values
when their geometry matches; rerun analyses before treating them as current.
Imported Reference results retain their independent source-based checks.

**Display / Environment / Lighting** includes an adjustable camera fill for
underside views. Neutral ambient light and a balanced directional key improve
underside visibility without washing out face contrast. The aerodynamic loft
offers Auto, Solid, Metallic, Wireframe and Translucent finishes, plus a surface
color. Metallic uses local studio reflections. Wireframe draws explicit quad
edges that remain visible against coincident skins. Auto uses wireframe
while shell contours are displayed; explicit finishes are always respected.
Sensitivity fields use the undeformed geometry; switch to the primal case in
FE Results for the deformed aero surface. Imported decks without an aero loft
explain why these controls are unavailable. Loading a sensitivity primal case
also exits temporary fuel isolation.

**Gaussian curvature** colors the displayed aerodynamic surface in **m⁻²**,
using discrete angle defects divided by mixed Voronoi area. Positive values
indicate locally dome-like curvature; negative values indicate saddle-like
curvature. Its scale has independent palette and limit controls. Open root/tip
boundaries, the sharp trailing edge and degenerate vertices have no reliable
smooth-surface estimate and remain grey. This display calculation uses the
chosen displacement scale and adds no stiffness or loads to the FEM.

The viewport toolbar switches bars between lines and 3D sections. Selecting
Translucent reveals a percentage slider; Fully solid restores opaque shells.
Supported WebGL 2 devices order translucent fragments by pixel depth, including
batched imported shells. Five dual passes retain up to ten depth layers per
pixel; deeper interiors can be omitted in dense or grazing views, and coincident
faces remain ambiguous. Isolate components or use Solid to inspect such regions.
Unsupported devices keep approximate mesh sorting and report the fallback in
the Log. Explicit **Show bars through surfaces** and measurement overlays stay
visible above the composed surfaces.
Surface-mode changes batch shader invalidation in one traversal instead of
rescanning the scene for each material. This reduces CPU switching cost on
models with many property groups; first-use shader compilation and depth-peeling
GPU work still depend on the device and visible geometry.
Ground elevation appears only when the ground is visible, with source units
identified for imported decks. Panning scales to the viewport and model size,
including millimetre-scale decks; ground bounds follow the imported geometry.
For CATIA-style zoom, press **middle + right mouse buttons**, then release
**right** while continuing to hold **middle**. Drag up to zoom in or down to
zoom out; releasing middle ends zoom. It works in perspective and parallel
views without recentering, rotating or panning the model. Wheel zoom remains
available.
Entity lists have independent collapse/expand buttons saved in the Study.
RBE3 lines are light pink. Aerodynamic-load reference nodes at rib planes are
magenta; fuel/structural-mass reference nodes at bay centers are dark green.
**Label constraint force and moment values** adds signed
component values at the visible reaction arrows, using the axis colors.
**Undeformed model color** changes the reference lines and beam sections without
changing result contours. The color and CELAS label option are saved with the
Study. Clicking **Inspect** again leaves inspection; its entity selector appears
only while Inspect is selected. The permanent lower-left mouse hint is removed;
the canvas tooltip retains the mouse controls.
Returning to **FE Results** exits temporary panel/fuel isolation and restores
the selected physical deformation. Saved sensitivity baselines retain their
binary displacement/rotation buffers through the server response. Malformed
buffers are rejected before they can corrupt the displayed geometry. Modal
section rendering tolerates very small rotations and exaggerated display
scales; an unavailable section shape falls back to its source beam line with
a diagnostic, leaving the analysis deck unchanged.

Planform and structural 2D editors support pan/zoom, background images, snapping,
distance/angle dimensions and SVG export. The dimensioned plan view and property
tables can open in separate browser tabs for another monitor. Detached property
and sensitivity tables include a shared light/dark theme switch.
Consecutive table edits are queued without starting an analysis. Live mesh waits
for unfinished cell edits, then rebuilds after they settle. Existing results stay
marked out of date until an explicitly requested analysis matches the definition;
fields are not mapped onto an incompatible rebuilt mesh.

Every active viewport quantitative color scale provides palette selection, hide/show and
manual minimum/maximum limits. **Automatic** restores the data-driven range.
Manual limits clip only the endpoint colors; numerical data are not changed.
Limits are independent for each quantity/unit. FE, sensitivity and VLM displays
have independent palettes, so changing one legend leaves the others unchanged.
The detached **Sensitivity data** table also has an independent Color scale
selector. Its legend and cell colors use the same fitted data limits; CSV values
remain unchanged. Text contrast adapts to the selected palette.
Unavailable result types have gray labels. Current results are green, while
retained results from an outdated definition retain their warning state. JFEM
activity indicators alternate blue and white (steady blue with reduced motion).
These settings are saved with the Study.

## Analyses and sensitivities

The GUI supports SOL101 static, SOL103 modal, SOL105 linear buckling and an
experimental SOL106 geometric nonlinear comparison. SOL106 also runs a linear
case for comparison and labels partial convergence and accepted load levels.
Follower-force options follow the solver's documented supported formulations.
For `LGDISP=1`, eligible planar isotropic shell models use the Green-Lagrange
membrane-energy residual and tangent automatically, with linear CBAR members.
Composite/offset shells and smoothed normals retain the existing experimental
path. Solver diagnostics identify the selected formulation and its scope;
this does not establish general finite-rotation shell behavior.
Automatic selection keeps geometric nonlinearity off when LGDISP is omitted or
disabled, and keeps CBAR-only systems linear even when it is enabled.
Boxer explicitly enables LGDISP in generated nonlinear models. Converting an
imported model to SOL106 also enables it when absent; an explicit imported
LGDISP setting is preserved for both FE analysis and sensitivity.
**Analysis / FE Analysis** contains the solver form; **Analysis / Sensitivity**
contains sensitivity setup. The **Results** menu separately presents FE results
and completed sensitivity results.

Under **Analysis / Sensitivity**, choose **Analysis** independently of the response,
then select an eligible load case and the design variables. SOL101 offers
displacement/shell/bar stress, SOL103 modal eigenvalues, SOL105 buckling factors,
and SOL106 displacement at the converged full-load nonlinear state. The current
model catalogue controls availability and explains disabled analyses, responses
and load cases. SOL106 stress derivatives are not supported. The sensitivity
analysis choice does not change the ordinary FE Analysis choice or the source
solution of an imported deck. Panel-local variables and shared
defaults are distinct variables; the interface shows their actual scope.
Study files save the selected design-variable IDs and response setup. On
reopening, Sensitivity automatically reads the current property catalogue and
restores the checked variables when the model is ready. An explicitly empty
selection stays empty; unavailable saved IDs are reported until removed by the
user. An unavailable saved analysis or case remains visible and blocked until
corrected explicitly. Older studies infer SOL103 from modal objectives, SOL105
from buckling objectives, and SOL101 from displacement/stress objectives.
Restoring or changing a selection does not start an analysis; press **Run
sensitivity** explicitly. Completed historical requests remain unchanged.
Use **Add component variables** to add independent spar-web/cap, rib and
leading-edge variables to an existing selection. Newly available variables are
not silently added to a saved selection. Shared-default derivatives describe all
their attached components together; separate rib/bay derivatives require selecting
the local variables and explicitly running sensitivity again. Component grids
show unselected physical locations as **Not selected**, rather than copying a
shared derivative into every location.
The property filter defaults to **Wildcards**. Examples: `P*` (or `P_`) selects names
beginning with P, `*skin*` finds "skin" anywhere, and `*bar*lower*` finds "bar"
followed by "lower" within a name, group or ID. Other characters are literal;
a trailing underscore is a name-prefix shortcut. **Text** and **Regex** modes
remain available for literal phrases and regular expressions. **Add matches**
adds matching variables without clearing earlier selections, so successive
patterns build a selection. Invalid expressions show an error without changing
it. After a mesh update, an existing catalog refreshes to the new definition;
the Run button explains any remaining blocker and offers the relevant recovery
action. Refreshing properties or editing a selection never starts a solve.
There is no fixed variable-count limit: **Add matches** includes every match in
the current model, including entries outside the visible scrolling window.
Study files and saved sensitivity results retain the complete selection. Large
lists render only the nearby rows; the range shown above the list describes
the displayed rows, not a limit on selection or calculation. To extend a Study
previously stopped at 4,096 variables, refresh model properties and click
**Add matches** with the desired filter (clear the filter to select everything).
The **? Help** button beside the filter explains regex syntax, examples,
additive selection and the difference between clearing a filter and selection.

The default is an **analytic discrete adjoint**. For a static scalar response it
uses one forward solve and one shared adjoint solve, followed by exact chain-rule
element derivatives and contractions. Explicit formulas and automatic
differentiation of native kernels replace property finite differences. The
legacy operator-difference method remains an explicit comparison option.
Read [SENSITIVITY_METHOD.md](SENSITIVITY_METHOD.md) for equations, work counts,
supported formulations and limitations.

Results include signed and normalized derivatives, residual checks, analytic
derivative/solve counts and timings (step comparisons in legacy mode). **Open data table** opens
component grids and complete/shared-property lists with CSV export. Choose
upper/lower skins and stringers, spar webs, spar caps, rib webs, rib stiffeners,
leading-edge skins or leading-edge ribs. Local derivatives are arranged by
component and rib/bay; shared default/material derivatives appear once in a
separate list with their full scope. They are not divided into artificial local
sensitivities. Groups reflect the recorded run; uncomputed values are explicit.
Color fields
automatically fit the actual finite minimum and maximum of the relevant data.
The component table uses its selected group, property family, quantity and filter;
raw derivatives with different units have separate scales. All-negative or
all-positive values no longer create an unused opposite half of the scale.
The viewport uses mapped properties and, when enabled, only visible elements.
Explicit manual viewport limits still take precedence. Uniform values have a
single-valued scale; missing derivatives stay gray and are excluded from bounds.

Sensitivity color fields
display the derivative of the selected scalar response with respect to the
property attached to each element, not a new local stress solution. A shared
property repeats its one derivative on its member elements. Local panel
derivatives take precedence over shared defaults in the corresponding field.
Sensitivity table numbers use a selectable signed scale with a neutral zero
where zero is within the actual range. Raw derivatives have separate ranges for each unit; normalized values
share a dimensionless range. Limits follow the displayed rows and filter.
Failed/unavailable values remain uncolored, and CSV keeps full precision.

Sensitivity and import workers reuse the selected solver's precompiled package
instead of loading a fresh copy of its source module. Progress and timing files
separate package loading, baseline parsing, analysis, compilation and export.
Installation or source changes can still require a one-time cache rebuild, and
first-use compilation can remain within the generator/solver process. No
stiffness, solve tolerance or derivative formula is changed by this optimization.
Native imports use a separate reusable parser process and avoid parsing the
same deck twice. Its reduced compilation optimization affects import only;
analysis workers retain their normal solver settings. First import still
includes package startup/compilation; subsequent imports reuse that work.

**Results / Sensitivity** becomes available after a sensitivity analysis. Its
**Show sensitivity field** button is orange until the field is displayed, then
green. The primal solution is also available in **Results / FE Results** without
another solve. **Show baseline case** selects that original solved case;
the retained baseline deck and native/portable result files can be
downloaded. Existing solved cases remain available. Completed sensitivity runs
can be reopened without solving. Historical/stale compatibility is checked before
mapping values onto a current mesh.

VLM mesh, pressure/Cp, panel-force vectors and applied RBE3 loads can be displayed
with sensitivities. Each legend names its case. The aerodynamic view represents
the prescribed undeformed lattice, not a newly computed aeroelastic solution.

## Portable Reference export

The in-process API can write 16-column large fields when additional coordinate
and property precision is needed with traditional Reference line-length limits:

```julia
include("APPS/JFEM-Boxer/src/WingFEGen.jl")
using .WingFEGen
model = build_model(read_input("APPS/JFEM-Boxer/examples/wing_default.toml"))
write_reference(model, "wing_large.bdf"; large_field=true)
```

The default eight-column export remains available. Large-field cards use paired
`*` continuation lines. Generated CBAR entries leave the default convention
field blank, preserving BASIC-frame bar offsets. SOL105 explicitly applies
the selected SPC set to both
the static preload and its buckling subcase. Exact Float64 free-field output
used for native sensitivities remains separate from this portable format.

## Analysis timings and buckling preload results

**Analysis → FE Analysis → Run timeout (0 = unlimited)** sets an optional
elapsed-time limit in minutes, saved with the Study. The default, **0**, allows
FE and sensitivity analyses to finish without a time limit; **Stop** remains
available. A positive value limits each FE run, including startup/compilation,
or the whole sensitivity study. SOL101/SOL106 comparison children each get
their own limit. There is no separate two-hour sensitivity cap. The control
also applies to imported models. Existing studies retain their saved timeout;
set it to 0 to remove that limit.

The first FE or sensitivity analysis starts a Julia solver worker. Later analyses reuse that
process, its loaded packages and compiled methods. The worker uses the same
root `Project.toml`, `Manifest.toml` and verified shared sysimage as the app.
First-use code can still compile during an analysis. Only one solver request runs
at a time; every request gets a fresh model, immutable deck snapshot, output
directory, result files and log. Per-request `JFEM_*` flags and CLI output
options are applied independently.

Sensitivity no longer starts a separate Julia process for each calculation.
Repeated runs can reuse both the baseline solver and derivative specializations.
The timing log distinguishes compilation from execution; the first run after
installation, a source update or worker restart can take longer. Installation's
precompile workload covers imported properties and generated skin, T-stringer
and material derivatives; uncommon model features may still compile on first use.

The Log identifies the worker PID and session. Each run's `solver_worker.json`
records its runtime, project, manifest hash, request index and start/finish
times; `run_manifest.json` also identifies the worker. `jfem_run.log` remains
the full downloadable log, including progress and timings. The unmodified
per-request console log is `solver_stdout.log`; startup diagnostics remain in
`solver_bootstrap.log` in the run that created the worker.

A failed analysis normally leaves the worker available. Cancelling or timing
out an active analysis stops its worker; the next run starts a fresh process.
Cancelling a queued request leaves the active request alone. A crashed worker
is replaced on the next run, and closing the app stops its owned worker and
rejects further submissions. Source, manifest or initialization-only runtime
setting changes also cause a fresh worker. The lightweight import worker keeps
its separate lifecycle; FE and sensitivity requests share the solver queue.

The focused regression runs with
`julia --project=. APPS/JFEM-Boxer/test/solver_worker_test.jl OUTPUT --native`
from the repository root. It checks real SOL101/103/105/106 reuse, load and
output isolation, recovery after errors, cancellation, crash/restart, timeout
and application shutdown. Use a separate output folder.

**Analysis / FE Analysis** explains the current EIGRL fields beside the modal
and buckling controls. The compact example
`EIGRL          11.0000-650.00000      10` consists of eight-character fields:
`EIGRL | SID=1 | V1=1e-6 | V2=50 | ND=10`. `METHOD=1` selects request 1;
`ND` requests ten roots. For SOL105 the bounds are dimensionless multipliers
of the selected static preload, not frequencies in Hz, and the interval may
contain fewer than ten roots. `1.0000-6` is compact notation for 0.000001.
Generated SOL103 requests leave the frequency bounds blank and use mass
normalization. Imported decks retain their source extraction settings unless
an analysis override is selected; inspect **Deck** for their exact values.

The completion message reports numerical solution time with Julia compilation
excluded. The Log and result summary separately show compilation within analysis
stages, deck/model preparation, export, and startup/package-loading overhead.
The solver writes the underlying per-stage measurements to `<deck>.TIMINGS.JSON`.
Assembly, constraints, equilibrium/eigenvalue solves and numerical recovery count
as solution work; result-file reading and viewport preparation are timed separately.
Older solver runs without measurements report unavailable solution time rather
than substituting their total elapsed time.

Every SOL105 calculation uses a static equilibrium preload. Its actual recovered
displacements and requested fields are available through **SOL101 preload** in
Results, without another static solve. When an imported source deck lists a
separate static subcase, selecting that original case also shows its preload.
Legacy local-METHOD decks use the solver's recorded preload ownership, even when
the source has no explicit STATSUB. Static fields suppressed by case-control
output requests remain suppressed; the retained preload displacement is still
available for visualizing the reference shape.

In **Analysis → FE Analysis**, the SOL105 **Export element strain energy and
density (ESE)** option writes `ESE(PLOT) = ALL` in Case Control. This standard
request includes both quantities for each static preload and buckling mode.
Imported decks may use `ESE = NONE` to disable a subcase, or `ESE(PLOT) = n`
to select the element IDs in Case Control `SET n`. Global requests apply to
subcases unless overridden. The source settings remain unchanged unless the
imported-analysis output override is enabled. The resulting energy and density
fields are available in the results JSON and field-view contours. Their units
are J and J/m³ for N-m inputs; modal values depend on arbitrary eigenvector
amplitude, so they are not physical critical-load energies. Compact eigenvalue
output suppresses these fields. See the [output request examples](../../utils/julia_tools/README.md)
for element-set syntax and supported request qualifiers.

Buckling modes use their own normalized display amplitude; changing the static
preload magnitude does not change the displayed mode size.

**Constraint reactions** shows recovered forces and moments for ordinary SOL101,
accepted SOL106 states, and their sensitivity baselines. SOL105 sensitivity
baselines retain a separate **SOL101 preload** variant; its reactions also follow
the buckling static-preload shape. Reaction arrows and numeric labels follow the
displayed constrained nodes, while the arrow multiplier changes only glyph size.
Normalized eigenmodes do not inherit physical preload reactions. Missing or
suppressed SPCFORCES output is explained beside the disabled controls.

## Portable checks

Startup prints the Julia version, thread count, package names and versions,
package timings, source-loading phases and local-listener readiness. A separate
progress process keeps elapsed-time messages visible during first-use Julia
compilation. No FEM or analysis is run while loading the application.

From the repository root:

```sh
julia --project=. APPS/JFEM-Boxer/test/portable_smoke_test.jl
julia --project=. APPS/JFEM-Boxer/test/reference_large_field_test.jl
julia --project=. APPS/JFEM-Boxer/test/portable_smoke_test.jl --native
```

The SOL105 preload regression compares its fields with an independent SOL101
solution and checks that exporting the preload does not solve equilibrium again.
Its saved synthetic results can also exercise the browser case selectors:

```sh
julia --project=. APPS/JFEM-Boxer/test/sol105_preload_results_test.jl <preload-output-dir>
julia --project=. APPS/JFEM-Boxer/test/export_sol105_preload_browser_fixtures.jl <preload-output-dir> <browser-fixture-dir>
node APPS/JFEM-Boxer/test/sol105_imported_case_selection_browser_test.cjs <browser-fixture-dir>
```

The optional browser check requires Playwright and its Chromium browser
(`npx playwright install chromium` after installing the Playwright package).
`WING_PLAYWRIGHT_MODULE` can specify the module path. By default it uses
Playwright's bundled browser; set `CHROME_PATH` only to use an explicit browser
executable. It reads the saved solver results and starts no new analysis.

The analytic CBAR derivative regression also checks coupled mass and section
offset derivatives against assembled native operators. Pass two scratch folders
for its synthetic input decks and numerical outputs:

```sh
julia --project=. APPS/JFEM-Boxer/test/sensitivity_analytic_beams_test.jl <scratch-input-dir> <scratch-output-dir>
```

The ordinary smoke test checks the factory model, mesh/deck generation,
aerodynamics, source discovery and browser assets without user data. The native
option additionally exercises a small solver case and adjoint worker, so it takes
longer on first use. Test-generated data are temporary or in an explicitly
selected output directory. Portable browser/data unit checks use Node.js only
when running those developer checks; Node is not a runtime prerequisite.

```sh
node APPS/JFEM-Boxer/test/portable_frontend_test.cjs
node APPS/JFEM-Boxer/test/study_files_test.cjs
node APPS/JFEM-Boxer/test/result_palettes_test.cjs
node APPS/JFEM-Boxer/test/property_display_test.cjs
node APPS/JFEM-Boxer/test/load_glyphs_test.cjs
node APPS/JFEM-Boxer/test/sensitivity_filter_test.cjs
node APPS/JFEM-Boxer/test/sensitivity_component_selection_test.cjs
node APPS/JFEM-Boxer/test/jfem_timing_test.cjs
node APPS/JFEM-Boxer/test/sensitivity_component_availability_test.cjs
node APPS/JFEM-Boxer/test/sensitivity_component_tables_test.cjs
node APPS/JFEM-Boxer/test/import_and_table_colors_test.cjs
node APPS/JFEM-Boxer/test/panel_explode_test.cjs
node APPS/JFEM-Boxer/test/scene_lighting_test.cjs
node APPS/JFEM-Boxer/test/support_glyphs_test.cjs
node APPS/JFEM-Boxer/test/reference_import_large_test.cjs
node APPS/JFEM-Boxer/test/abaqus_import_test.cjs
node APPS/JFEM-Boxer/test/solid_geometry_test.cjs
node APPS/JFEM-Boxer/test/solid_binary_test.cjs
node APPS/JFEM-Boxer/test/sections_viewer_test.cjs
node APPS/JFEM-Boxer/test/imported_analysis_test.cjs
node APPS/JFEM-Boxer/test/imported_follower_display_test.cjs
julia --project=. APPS/JFEM-Boxer/test/startup_progress_test.jl
julia --project=. APPS/JFEM-Boxer/test/job_log_progress_test.jl
julia --project=. APPS/JFEM-Boxer/test/imported_analysis_overlay_test.jl
julia --project=. APPS/JFEM-Boxer/test/shell_display_payload_test.jl
julia --project=. APPS/JFEM-Boxer/test/portable_paths_test.jl
julia --project=. APPS/JFEM-Boxer/test/sensitivity_component_selection_test.jl /path/to/test-output
julia --project=. APPS/JFEM-Boxer/test/payload_roundtrip_test.jl
julia --project=. APPS/JFEM-Boxer/test/reference_source_test.jl
julia --project=. APPS/JFEM-Boxer/test/reference_import_smoke_test.jl
julia --project=. APPS/JFEM-Boxer/test/abaqus_import_test.jl
julia --project=. APPS/JFEM-Boxer/test/abaqus_import_worker_test.jl
julia --project=. APPS/JFEM-Boxer/test/reference_case_metadata_test.jl
julia --project=. APPS/JFEM-Boxer/test/model_entities_payload_test.jl
julia --project=. APPS/JFEM-Boxer/test/follower_metadata_test.jl
julia --project=. APPS/JFEM-Boxer/test/imported_analysis_test.jl
```

The importer readiness check also uses Playwright's bundled Chromium by default:

```sh
node APPS/JFEM-Boxer/test/reference_ready_browser_test.cjs
node APPS/JFEM-Boxer/test/abaqus_import_browser_test.cjs
```

For this check, `WINGFEGEN_PLAYWRIGHT_MODULE` overrides the module path and
`CHROME_BIN` selects an explicit browser executable. No solver is started.

Analysis-selector and Study-persistence checks use synthetic capability metadata
and do not start a solver:

```sh
node APPS/JFEM-Boxer/test/sensitivity_setup_persistence_test.cjs
node APPS/JFEM-Boxer/test/sensitivity_variant_persistence_test.cjs
node APPS/JFEM-Boxer/test/sensitivity_solution_selection_browser_test.cjs <evidence-dir> playwright
```

The browser check uses bundled Chromium unless `CHROME_PATH` names an explicit
browser executable. Its second argument may be an installed Playwright module
directory. It covers all four analyses, imported case eligibility, nonlinear
displacement restrictions, saved settings, stale catalogue responses and
immutable historical requests.

Constraint-reaction presentation can reuse the completed synthetic preload
fixture without additional solver calls:

```sh
julia --project=. APPS/JFEM-Boxer/test/sensitivity_baseline_reactions_test.jl <preload-test-output> <reaction-evidence-dir>
node APPS/JFEM-Boxer/test/sensitivity_reactions_browser_test.cjs <reaction-evidence-dir> playwright
```

`<preload-test-output>` is the output directory of
`sol105_preload_results_test.jl`, containing `SOL105.bdf` and its `results/`
native JSON. The check exports a separate presentation fixture and verifies
ordinary and sensitivity preload reactions, normalized-mode exclusions,
deformed glyph positions, visibility controls and explicit unavailable states.
The browser uses bundled Chromium or the explicit `CHROME_PATH` override.
For an additional check of an already completed generated SOL106 baseline, append
its saved study TOML and baseline run directory to the Julia command. The exporter
rebuilds only that model and reads its existing `baseline_native.json`; the same
browser command then also checks the actual nonlinear reactions, deformed
positions, numeric labels and signed nodal inspection values. No new solve is run.

Component-table routing can be reproduced with the included synthetic fixture
producer. Its derivatives are deliberately synthetic and verify display routing,
selection, and persistence only:

```sh
julia --project=. APPS/JFEM-Boxer/test/component_sensitivity_table_fixture.jl <table-fixture-dir>
node APPS/JFEM-Boxer/test/sensitivity_component_availability_test.cjs <table-fixture-dir>/table_fixture.json
node APPS/JFEM-Boxer/test/sensitivity_component_selection_browser_test.cjs <evidence-dir> playwright <table-fixture-dir>/table_fixture.json
```

The separate numerical-table integration check consumes an **already completed**
SOL101 analytic-adjoint run. It does not generate derivatives or start a solve:

```sh
node APPS/JFEM-Boxer/test/sensitivity_component_numeric_table_test.cjs <numeric-fixture.json> <evidence-dir>
```

The JSON contract is `{ "catalog": ..., "result": ..., "rib_count": R }`.
`catalog` must come from `sensitivity_catalog` for the exact saved baseline
model, `result` is the unchanged saved numerical result, and `R` is that model's
rib count. The qualifying fixture has at least three ribs, all 11 component
parts, single-thickness web/leading-edge shell families, square spar caps, and
four-dimension T rib stiffeners. Its request and returned rows contain exactly
all catalogue variables with a `component_key`, one successful finite derivative
per physical PID. The result records `method="analytic_discrete_adjoint"`, one
forward solve, one adjoint solve, zero perturbed forward solves, and zero
finite-difference samples. At least two front-web bay derivatives must differ.

To package a qualifying saved run, start `julia --project=.` at the
repository root and run the following, replacing the three example filenames.
This rebuilds only the saved baseline model and retains the result values:

```julia
include("APPS/JFEM-Boxer/src/WingFEGen.jl")
using .WingFEGen, JSON
model = build_model(read_input("saved_baseline.toml"))
result = JSON.parsefile("saved_result.json")
@assert result["baseline_model_signature"] == WingFEGen.sensitivity_model_signature(model)
fixture = Dict("catalog" => WingFEGen.sensitivity_catalog(model),
               "result" => result, "rib_count" => length(model.grid.ribs))
write("numeric-fixture.json", JSON.json(fixture))
```

The synthetic routing fixture cannot substitute for this numerical fixture.
Keep saved runs, fixtures, generated CSVs, and screenshots in a scratch directory
outside the repository.

The solver's separate curated validation suite is described in the repository
[validation guide](../../validation/README.md).

## Source layout

| Path | Purpose |
| --- | --- |
| `src/` | Geometry, mesh, properties, loads, solver integration, sensitivities and HTTP server |
| `web/` | Browser UI, rendering and detached editors |
| `web/vendor/` | Bundled browser dependencies and their license notices |
| `examples/wing_default.toml` | Portable factory model definition |
| `test/` | Selected self-contained checks |
| `setup.jl`, platform launchers | Dependency setup and local startup |
| Root `Project.toml`, `Manifest.toml` | Shared solver/app dependency environment |

Original application source is covered by the repository [LICENSE](../../LICENSE).
Third-party libraries retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Results availability is evaluated for the selected load case. With no physical
or sensitivity results for that case, its Results labels are gray; retained
results that no longer match the definition remain marked as stale.

For static result display, load-glyph origins, the VLM lattice and VLM force
centers follow the deformed structural shape. Participating aerodynamic FORCE
vectors use SOL101's first-order or SOL106's finite-rotation follower law.
Display magnification affects geometry but never the physical force direction.
Inertial loads and MOMENT directions remain fixed in global axes. Prescribed
VLM pressure is not recomputed as an aeroelastic solution.
