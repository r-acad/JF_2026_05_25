/* =========================================================================
   WingFEGen web app
   -------------------------------------------------------------------------
   Parameters arrive from Julia as JSON together with the schema that drives
   this form. Live mesh and Create FEM post the parameters back as JSON;
   the generated mesh comes back as MsgPack with
   the coordinates and the connectivity carried in binary blobs, which are
   reinterpreted as typed arrays and handed straight to Babylon.js.

   Run in JFEM writes the deck, starts the solver, streams its console output
   while it works, and when it finishes pulls the results back and draws them
   as a deformed shape with a contour.
   ========================================================================= */
"use strict";

/* --- layer appearance ---------------------------------------------------- */

const GROUP_STYLE = {
  UPPER_SKIN:     { color: "#4a90d9", alpha: 0.55 },
  LOWER_SKIN:     { color: "#2a6aa8", alpha: 0.55 },
  UPPER_SKIN_RUNOUTS: { color: "#4a90d9", alpha: 0.55 },
  LOWER_SKIN_RUNOUTS: { color: "#2a6aa8", alpha: 0.55 },
  FRONT_SPAR_WEB: { color: "#e2761b", alpha: 0.95 },
  REAR_SPAR_WEB:  { color: "#b05a10", alpha: 0.95 },
  RIB_WEBS:       { color: "#3fa65a", alpha: 0.95 },
  RIB_STIFFENERS: { color: "#a9e4ef" },
  LE_UPPER_SKIN:  { color: "#6eafe6", alpha: 0.55 },
  LE_LOWER_SKIN:  { color: "#397eb8", alpha: 0.55 },
  LE_RIB_WEBS:    { color: "#62bc7c", alpha: 0.95 },
  LE_RIB_NOSE:    { color: "#62bc7c", alpha: 0.95 },
  STRINGERS:      { color: "#ffdf00" },
  STRINGER_RUNOUTS: { color: "#ffdf00" },
  SPAR_CAPS:      { color: "#ff8c00" },
};

for(const name of ["UPPER_SKIN","LOWER_SKIN","FRONT_SPAR_WEB","REAR_SPAR_WEB","LE_UPPER_SKIN","LE_LOWER_SKIN"]) GROUP_STYLE[name+"_KINKS"] = GROUP_STYLE[name];

// Bars render last, but obey structural depth unless the user explicitly
// enables "Show bars through surfaces".
const BAR_RENDER_GROUP = 3;
const FOREGROUND_BARS = new Set(["STRINGERS", "STRINGER_RUNOUTS", "SPAR_CAPS", "RIB_STIFFENERS"]);
const isForegroundBar = group => !!group && FOREGROUND_BARS.has(group.base_group || group.name);

const EXTRA_STYLE = {
  NODES:        { color: "#ecf4ff", label: "Structural nodes" },
  AERO_SURFACE: { color: "#8fa0b3", alpha: 0.12, label: "Aerodynamic loft overlay" },
  MESH_EDGES:   { color: "#101720", label: "Element edges" },
  RBE3:         { color: "#f4b8d6", label: "RBE3 spiders" },
  RBE3_NODES:   { color: "#f8cee2", label: "RBE3 ref nodes" },
  FUEL_RBE3:    { color: "#f4b8d6", label: "Fuel RBE3 spiders · 123456" },
  FUEL_RBE3_NODES: {color: "#91f5d5", label: "Fuel mass reference nodes"},
  SPC:          { color: "#ff4d6d", label: "Supports (SPC)" },
  SUPPORT_FORCES: { color: "#b8cadb", label: "Support forces / moments (XYZ)" },
  AERO_LOADS:   { color: "#b8cadb", label: "Applied force components · aero, structure and fuel" },
  AERO_MOMENTS: { color: "#b8cadb", label: "Applied moment components (Nm)" },
  VLM_MESH:     { color: "#b5cbdf", label: "Vortex lattice mesh" },
  VLM_PRESSURE: { color: "#e9b04d", label: "VLM pressure jump" },
  VLM_FORCES:   { color: "#e45ad4", label: "VLM normal pressure forces" },
  FUEL_TANK:    { color: "#50dfa3", label: "Fuel tank volume (undeformed)" },
  SHELL_AXES:   { color: "#ef5f6b", label: "Shell local x axes" },
  BAR_AXES:     { color: "#4cc38a", label: "Bar local x/y/z axes" },
};

const DEFAULT_HIDDEN = new Set(["NODES", "UNDEFORMED", "AERO_SURFACE", "AIRFOIL_SECTIONS", "REFERENCE_AERO", "VLM_MESH", "VLM_PRESSURE", "VLM_FORCES", "SHELL_AXES", "BAR_AXES", "COORDINATE_SYSTEMS"]);

/* A mode is animated at a fixed, comfortable rate rather than its real
   frequency, which would be a blur above the first few modes. */
const ANIMATION_HZ = 0.5;

/* --- application state --------------------------------------------------- */

const state = {
  schema: [],
  values: {},
  inputFile: "",
  importedDeck: null,
  data: null,
  engine: null,
  scene: null,
  camera: null,
  root: null,
  layers: new Map(),   // name -> { meshes, visible, color, count, label }
  layerRowControls: new Map(),
  edgeVisibilityKey: null,
  bbox: null,
  diag: 1,
  busy: false,
  // geometry that follows a result
  baseline: null,      // Float32Array, undeformed Babylon positions of all nodes
  deformed: null,      // Float32Array, scratch for the deformed positions
  deformable: [],      // { mesh, map, buf }  map null means one vertex per node
  markers: [],         // { mesh, node }
  shellMeshes: [],     // meshes that can carry a contour
  barMeshes: [],
  // results
  results: null,
  activeMode: -1,
  contourIdx: 0,
  contourPreference: null,
  phase: 0,
  realScale: false,
  solverProgress: null,
  jobId: null,
  polling: false,
  logCursor: 0,
  modelDirty: false,
  studyDirty: true,
  studyRevision: 0,
  studyViewRevision: 0,
  studyRestoring: false,
  studyNotes: {text:"",history:[]},
  studyCreatedAt: null,
  studySavedAt: null,
  recentStudies: null,
  studyRecentId: null,
  modelSignature: null,
  jobSignature: null,
  selectedElement: null,
  selectedCoordinate: null,
  selectedNode: null,
  selectionMesh: null,
  geometryTools: null,
  nodeIds: null,
  elements: new Map(),
  viewPlanes: null,
  supportGlyphs: null,
  aeroDisplay: null,
  layerGroupControls: new Map(),
  layerGroupCollapsed: new Map(),
  deckUrl: null,
  lastDeck: null,
  deckLoadPromise: null,
  deckRevision: 0,
  loadCases: [],
  editingCase: null,
  activeCase: 1,
  resultCases: null,
  resultVariantPreference: "",
  comparisonMeshes: [],
  vlm: null,
  loadPlots: null,
  sensitivity: null, sensitivityBusy: false, sensitivityJob: null, sensitivityTimer: null, sensitivitySignature: null, sensitivityActivity: null,
  sensitivityResult: null, sensitivityMeta: null, sensitivityMap: null,
  panelIndex: null, panelView: null, propertyDisplay: null,
  weightsView: null,
  fuelIsolation: null,
  lastTransfer: { bytes: 0, seconds: 0 },
  loadLayerVisibility: new Map(),
  autoMeshEnabled: true,
  autoMeshReady: false, // enabled only after the real input form has loaded
  autoMeshPending: false,
  autoMeshDueAt: 0,
  lastEditedSignature: null,
  autoMeshTimer: null,
  meshRequestInFlight: false,
  solverStarting: false,
  loadingInput: false,
  pollTimer: null,
  workspaceBusy: false,
  studyFile: null,
  studyFileHandle: null,
  tomlFile: null,
  lastFileSave: null,
  parameterLocks: null,
  planformEditor: null,
  sparEditor: null,
  leadingEdgeGaps: null,
};
if (typeof WingParameterLocks !== "undefined") state.parameterLocks = WingParameterLocks.create({ document, getSchema: () => state.schema });

/* --- logging ------------------------------------------------------------- */

const logEl = document.getElementById("log");
const LIVE_LOG_LINES = 1200, LIVE_LOG_BATCH = 120, LIVE_LOG_LINE_CHARS = 8192;
const liveLog = { queue: [], timer: null, discarded: 0, follow: true };

function log(msg, cls) {
  logBatch([{ text: msg, kind: cls }]);
}

function logBatch(messages) {
  const time = new Date().toLocaleTimeString();
  for (const item of messages) {
    const text = String(typeof item === "string" ? item : item.text);
    liveLog.queue.push({ text: text.length > LIVE_LOG_LINE_CHARS ? text.slice(0, LIVE_LOG_LINE_CHARS) + " … [full line in disk log]" : text,
      kind: typeof item === "string" ? "info" : item.kind || "info", time });
  }
  if (liveLog.queue.length > LIVE_LOG_LINES) {
    liveLog.discarded += liveLog.queue.length - LIVE_LOG_LINES;
    liveLog.queue.splice(0, liveLog.queue.length - LIVE_LOG_LINES);
  }
  if (liveLog.timer === null) liveLog.timer = setTimeout(flushLog, 16);
}

function flushLog() {
  liveLog.timer = null;
  const visible = !logEl.getClientRects || logEl.getClientRects().length > 0;
  // At most one scroll measurement per batch. Never force layout per line.
  const follow = !visible ? liveLog.follow : logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight < 32;
  const fragment = document.createDocumentFragment();
  const lines = liveLog.queue.splice(0, LIVE_LOG_BATCH);
  for (const item of lines) {
    const line = document.createElement("div"), stamp = document.createElement("span"), span = document.createElement("span");
    stamp.className = "t"; stamp.textContent = item.time + "  ";
    span.className = item.kind; span.textContent = item.text;
    line.appendChild(stamp); line.appendChild(span); fragment.appendChild(line);
  }
  const oldTop = logEl.scrollTop;
  const pruneCount = Math.max(0, logEl.childElementCount + lines.length - LIVE_LOG_LINES);
  const first = logEl.firstElementChild, lastPruned = pruneCount ? logEl.children[Math.min(pruneCount, logEl.childElementCount)-1] : null;
  const removedHeight = visible && !follow && first && lastPruned ? lastPruned.offsetTop + lastPruned.offsetHeight - first.offsetTop : 0;
  logEl.appendChild(fragment);
  while (logEl.childElementCount > LIVE_LOG_LINES) { logEl.firstElementChild.remove(); liveLog.discarded++; }
  if (visible && follow) logEl.scrollTop = logEl.scrollHeight;
  else if (visible && !follow) logEl.scrollTop = Math.max(0, oldTop - removedHeight);
  const note = document.getElementById("log-retention");
  if (note) note.textContent = liveLog.discarded ? "Live view limited to the latest " + LIVE_LOG_LINES + " lines. " + liveLog.discarded.toLocaleString() + " older lines hidden; the complete solver log is preserved on disk." : "Live output is batched to keep the interface responsive. The complete solver log is preserved on disk.";
  if (liveLog.queue.length) liveLog.timer = setTimeout(flushLog, 16);
}

if (logEl.addEventListener) logEl.addEventListener("scroll", () => {
  if (logEl.getClientRects().length) liveLog.follow = logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight < 32;
}, { passive: true });
document.getElementById("btn-clear-log").onclick = () => {
  if (liveLog.timer !== null) clearTimeout(liveLog.timer);
  liveLog.timer = null; liveLog.queue = []; liveLog.discarded = 0; liveLog.follow = true;
  logEl.innerHTML = "";
  const note = document.getElementById("log-retention"); if (note) note.textContent = "Live display cleared. The full solver log remains on disk.";
};

function solverActivity(running, progress = null) {
  if (running && !state.solverActivityToken) state.solverActivityToken = activity()?.begin("JFEM is running", {detail:"Solver output is available in Log."});
  if (running && progress && state.solverActivityToken) activity()?.update(state.solverActivityToken, {
    detail:(progress.solution ? "SOL" + progress.solution + " · " : "") +
      (Number.isFinite(progress.target_percent) ? "Attempting " + progress.target_percent.toFixed(1) + "% load; accepted " + (progress.accepted_percent || 0).toFixed(1) + "%" : progress.message || "See Log for solver progress.")+
      (!Number.isFinite(progress.target_percent)&&Number.isFinite(progress.stage_seconds)?" · "+progress.stage_seconds.toFixed(0)+" s in this stage":"")});
  if (!running && state.solverActivityToken) { activity()?.end(state.solverActivityToken); state.solverActivityToken = null; }
  if (progress) state.solverProgress = progress;
  else if (running) state.solverProgress = null;
  updateLoadClock(running, state.solverProgress);
  const indicator = document.getElementById("jfem-running"), tab = document.getElementById("tab-log");
  if (indicator) { indicator.hidden = !running; indicator.textContent = "JFEM is running"; }
  if (tab) {
    tab.classList.toggle("jfem-running", running);
    tab.setAttribute("aria-label", running ? "Log — JFEM is running" : "Log");
  }
  const status = document.getElementById("solver-progress");
  if (status && progress) {
    const label = progress.case_label ? "Case " + progress.case_id + ": " + progress.case_label + " · " : "";
    const percent = Number.isFinite(progress.target_percent) ? " · applied load target " + progress.target_percent.toFixed(2) + "%" : "";
    const accepted = Number.isFinite(progress.accepted_percent) ? " · last accepted " + progress.accepted_percent.toFixed(2) + "%" : "";
    status.textContent = label + (progress.solution ? "SOL" + progress.solution : "JFEM") + percent + accepted +
      (progress.iteration ? " · iteration " + progress.iteration : "")+
      (progress.message ? " · "+progress.message : "")+
      (Number.isFinite(progress.stage_seconds)?" · "+progress.stage_seconds.toFixed(0)+" s":"");
    status.hidden = false;
  } else if (status && running) { status.textContent = "Starting solver…"; status.hidden = false; }
  const runBadge = document.getElementById("run-badge");
  if (runBadge) runBadge.classList.toggle("jfem-running", running);
}

function updateLoadClock(running, progress) {
  const clock = document.getElementById("load-clock");
  if (!clock) return;
  clock.hidden = String(progress?.solution) !== "106";
  if (clock.hidden) return;
  const accepted = Math.min(100, Math.max(0, Number(progress.accepted_percent) || 0));
  const target = Math.min(100, Math.max(accepted, Number(progress.target_percent) || 0));
  const face = document.getElementById("load-clock-face");
  face.style.setProperty("--accepted-angle", accepted * 3.6 + "deg");
  face.style.setProperty("--target-angle", target * 3.6 + "deg");
  face.setAttribute("aria-valuenow", String(accepted));
  face.setAttribute("aria-valuetext", "Accepted load " + accepted.toFixed(2) + " percent; current target " + target.toFixed(2) + " percent");
  document.getElementById("load-clock-value").textContent = target.toFixed(1) + "%";
  document.getElementById("load-clock-title").textContent = "SOL106 · Case " + (progress.case_id || state.activeCase) + (running ? " · solving" : " · finished");
  document.getElementById("load-clock-accepted").textContent = "Accepted " + accepted.toFixed(2) + "%";
  document.getElementById("load-clock-detail").textContent = (running && progress.iteration ? "Iteration " + progress.iteration + " · " : "") + "Gold: target · green: accepted";
}

function badge(text, cls) {
  const b = document.getElementById("run-badge");
  if (!text) { b.hidden = true; return; }
  b.hidden = false;
  b.textContent = text;
  b.className = "badge" + (cls ? " " + cls : "");
}

/* --- binary helpers ------------------------------------------------------ */

// The blobs are written little-endian by Julia. Every mainstream platform is
// little-endian, but check once and swap if not so the viewer stays correct.
const LITTLE_ENDIAN = (() => {
  const b = new ArrayBuffer(2);
  new DataView(b).setInt16(0, 1, true);
  return new Int16Array(b)[0] === 1;
})();

function alignedBuffer(u8) {
  if (!ArrayBuffer.isView(u8) || u8.BYTES_PER_ELEMENT !== 1 || u8.byteLength % 4 !== 0)
    throw new Error("Invalid model/result buffer: expected binary 32-bit data. Reload the app and restart the server after updating; no geometry or results have been decoded from this malformed payload.");
  return (u8.byteOffset % 4 === 0)
    ? { buf: u8.buffer, off: u8.byteOffset }
    : { buf: u8.slice().buffer, off: 0 };
}

function swap32(u8) {
  const out = u8.slice();
  for (let i = 0; i < out.length; i += 4) {
    const a = out[i], b = out[i + 1];
    out[i] = out[i + 3]; out[i + 1] = out[i + 2];
    out[i + 2] = b; out[i + 3] = a;
  }
  return out;
}

function asF32(u8) {
  const src = LITTLE_ENDIAN ? u8 : swap32(u8);
  const { buf, off } = alignedBuffer(src);
  return new Float32Array(buf, off, src.byteLength / 4);
}

function asI32(u8) {
  const src = LITTLE_ENDIAN ? u8 : swap32(u8);
  const { buf, off } = alignedBuffer(src);
  return new Int32Array(buf, off, src.byteLength / 4);
}

/* --- number formatting --------------------------------------------------- */

function eng(x, digits) {
  if (typeof WingNumbers !== "undefined") return WingNumbers.format(x, digits === undefined ? 4 : digits);
  // Standalone viewer harnesses can load app.js without the optional widgets.
  if (!Number.isFinite(x)) return "—";
  const d = digits === undefined ? 4 : digits;
  if (x === 0) return "0";
  const a = Math.abs(x);
  if (a >= 1e5 || a < 1e-3) return x.toExponential(a >= 100 ? 2 : Math.max(d - 1, 1));
  const places = Math.max(d - 1 - Math.floor(Math.log10(a)), 0);
  return String(Number(x.toFixed(a >= 100 ? Math.min(2, places) : places)));
}

// Backend summary cells contain quantities with units. Format their standalone
// decimal tokens without touching entity IDs, raw logs, decks or stored data.
function reportValue(value) {
  if (typeof value === "number") return eng(value,6);
  return String(value).replace(/(?<![\w.])[+-]?\d+\.\d+(?:e[+-]?\d+)?(?![\w.])/gi,
    token => Math.abs(Number(token)) >= 100 ? eng(Number(token),9) : token);
}

/* --- form ---------------------------------------------------------------- */

const CASE_FIELDS = [
  ["method", "Load method", "loads.method"],
  ["lift_total", "Half-wing lift (N)", "loads.lift_total", "analytic"],
  ["distribution", "Lift distribution", "loads.distribution", "analytic"],
  ["speed", "Air speed (m/s)", "aero.speed", "vortex_lattice"],
  ["density", "Air density (kg/m³)", "aero.density", "vortex_lattice"],
  ["alpha", "Angle of attack (deg)", "aero.alpha", "vortex_lattice"],
  ["torque_y", "Added y torque (N m)", "loads.torque_y"],
  ["load_factor", "Load multiplier", "loads.load_factor"],
  ["follower_forces", "Follower forces (SOL101 / SOL106)", "loads.follower_forces"],
  ["fuel_percent", "Fuel status (%)", "loads.fuel_percent"],
  ["structure_inertia", "Include structural inertia", "loads.structure_inertia"],
  ["fuel_accel_x", "Inertia acceleration x (g)", "loads.fuel_accel_x"],
  ["fuel_accel_y", "Inertia acceleration y (g)", "loads.fuel_accel_y"],
  ["fuel_accel_z", "Inertia acceleration z (g)", "loads.fuel_accel_z"],
];
const CASE_GLOBAL_KEYS = new Set(["loads.label", ...CASE_FIELDS.map((field) => field[2])]);
const CHOICE_LABELS = {
  flight_direction: "Line of flight", front_spar_angle: "Angle to inboard front spar", rear_spar_angle: "Angle to local rear spar",
  analytic: "Prescribed lift", vortex_lattice: "Aerodynamic (VLM)",
  elliptical: "Elliptical", chord: "Proportional to chord", uniform: "Uniform",
  "101": "101 · Linear static", "103": "103 · Normal modes", "105": "105 · Buckling",
  "106": "106 + 101 · Nonlinear comparison",
};
const HELP_TOPICS = {
  "Ribs": { title:"Master rib layout", paragraphs:[
    "Root and final ribs are fixed masters in flight direction. With no intermediate masters, the root rib pitch generates the original layout. Add a master at its rear-spar ETA and set its outgoing pitch to the next master. The generator fits a whole number of evenly spaced rear-spar arc-length bays and interpolates the rib directions between masters.",
    "Choose flight direction or an angle from the rear-spar segment immediately inboard of that master, toward the nose. 90 degrees is perpendicular. Drag a rear-spar anchor to move a master; drag its line or front handle to rotate it. Use the table for exact values. Invalid drafts stay editable; the generator rejects ribs that cross or leave the surface.",
    "The drawing previews the untwisted reference geometry while editing and shows generated rib projections once the mesh is current. Lock mesh protects the layout. Study and TOML saves retain the master table. Leading Edge provides separate directions for individual rib extensions."
  ]},
  "Leading edge": { title:"Leading-edge ribs", paragraphs:[
    "The global orientation is the default for every leading-edge rib. Add an override by physical rib number for individual directions. Front-spar angles use the common root front-spar segment toward the nose; 90 degrees is perpendicular.",
    "A rib that misses the aerodynamic surface uses flight direction automatically. Its requested setting stays saved so later geometry edits can restore it. Red geometry and red result outlines identify fallbacks; the form and log report the affected ribs. Crossing or folded ribs still require editing. Leading-edge bays and bounds use the physical rib numbers from Structure > Ribs."
  ]},
  "Weights": { title: "Component masses and fuel", paragraphs: [
    "This tab reports the modeled half wing from its root to the final structural rib, in kilograms and newtons. Dry structure includes both skins, spar and rib webs, T stringers, square spar caps and fixed-area runout connectors. Each skin total includes its runout triangles.",
    "Shell mass is the projected FE midsurface area times its PSHELL thickness and MAT1 density. Quad area follows the native JFEM shell-mass plane, so warped quads do not depend on the viewer triangulation. Bar mass uses the PBARL or PBAR area times its effective CBAR length and the same material density. Equal end offsets preserve this length. Overlapping modeled members are counted as their FE properties specify.",
    "Enable and bound the tank in Fuel tank, set density here, and define Fuel status (0–100%) in each load case. The default 800 kg/m³ is an editable assumption. Each bay fills upward to its own horizontal global-Z level. Its CONM2 stores actual mass, CG offset and inertia and connects through a separate six-DOF fuel RBE3. Structure, equipment and unusable fuel are not deducted from capacity.",
    "RBE3 constraints, local reference geometry and the displayed aerodynamic/VLM meshes have no material mass. If optional aero-shell FE cards are exported, their mass appears separately in Exported FE deck. They remain unconnected to the structure. Weight in newtons uses standard gravity 9.80665 m/s²; this is a report, not an applied gravity load.",
  ] },
  "Fuel tank": { title: "Fuel tank volume", paragraphs: [
    "Show fuel tank volume draws the undeformed green envelope. Isolate tank hides surrounding layers; Restore model layers brings them back. The fuel overlay is suspended while FE result colors are active so the contour colors stay accurate.",
    "Enable the tank and select its first and last physical ribs. Rib 1 is the root; last rib 0 follows the current final rib automatically. Display > Axes & labels > Rib and stringer labels identifies the ribs in the viewport. The tank fills the box between front/rear spars and upper/lower skins. Dry / vent bays uses physical bay numbers or ranges such as 2,4-6; bay b is between ribs b and b+1. Dry bays contribute no fuel volume, mass, inertia, attachments or loads, while structural elements remain.",
    "After mesh creation, Summary → General reports gross volume in cubic metres and litres. Summary → Mass properties reports fuel for the selected case, including each rib bay. Cases defines Fuel status and global acceleration in g; the default −Z at 1g applies fuel weight, scaled by the case load multiplier. Set all accelerations to zero for mass and inertia only. Different fuel states use separate analysis decks, including separate normal-mode solutions.",
  ] },
  "Load plots": { title: "Spanwise load distributions", paragraphs: [
    "Choose a load case to see four vertically stacked graphs. Maximize gives them the full workspace width; move over a graph to read its sample values. These plots update when the mesh and applied loads are regenerated, without requiring a structural solve.",
    "The first graph is section lift coefficient times chord, in metres: strip lift divided by dynamic pressure and projected strip width. It includes the load multiplier. Prescribed-lift cases use the selected case's speed and density to report an equivalent coefficient; they are not VLM solutions.",
    "Shear, bending and torque show separate aerodynamic, structural-inertia, fuel-inertia and total contributions. Distributed loads is the default: physical spanwise distributions conserve the deck force/moment totals. Exact FE point loads retains the discrete GRID/RBE3 station jumps for comparison. No spline smoothing is used. Positive directions are global +z, right-hand +x and right-hand +y; the balancing internal cut action has opposite sign. Moments use the RBE3 reference chord line.",
  ] },
  "Material": { title: "Material properties", paragraphs: [
    "Enter Young's modulus in GPa, for example 71 for aluminium with E = 71000000000 Pa. The interface converts it to Pa for calculations, input-file storage and MAT1 export. Density remains kg/m3; Poisson's ratio is dimensionless.",
  ] },
  workflow: { title: "Build, load and solve", paragraphs: [
    "1. Use Geometry and Model to define the wing and mesh. Create FEM is in Mesh, or beside Live mesh when automatic updates are disabled. Model → Properties groups Skins, Stringers, Ribs, Spars and Leading Edge. Materials defines the library; each component selects its material or shell sandwich construction in Properties. Ribs provides web thickness and vertical T stiffeners per physical rib. Spars provides square spar caps and optional web thickness per bay. Summary groups Mass properties and General. Supports defaults to the main-box root perimeter in DOFs 1,2,3; Custom supports select other rib intersections and DOFs.",
    "Planform shows a live drawing beside its definition. The dashed outline is the base trapezoid; the solid outline follows the aerodynamic leading- and trailing-edge perturbation points. Add points in either table, edit their eta and ?x/c, or drag them on the drawing. Eta runs from root 0 to tip 1. ?x/c is an offset from the selected nominal edge: 0 is unchanged, +0.2 moves aft by 20% of the local base chord and -0.2 moves forward by 20%. Straight segments join the points; unedited endpoints stay on the base outline. The normalized coordinates stay fixed when you change the base trapezoid. Edge points change the shared aerodynamic and structural outer surface, including skin/nose geometry, spar heights and fuel volume. Spar reference paths retain their separate base-trapezoid coordinates. Plan View in the top bar opens a separate browser tab with dimensions, spars and physical ribs; move that tab to another monitor to watch live changes. Drag or use the wheel to move or zoom the drawing and background together. Hold Ctrl (Cmd on Mac) to adjust only the background image. Fit view restores the overall view while keeping image alignment. Study and TOML saves retain the embedded image, its alignment and the view placement.",
    "Spars has a separate live drawing and point tables for the front and rear spars. Spar points use eta and ?x/c offsets from their scalar Front spar or Rear spar locations, independently of aerodynamic edges. Zero follows the nominal spar, and positive/negative values shift aft/forward by that fraction of the base chord. Legacy absolute xc records load without moving the geometry. Points at eta 0 or 1 replace the normal endpoint; other unspecified endpoints use the Front spar and Rear spar values. Both spars must stay inside the refined surface over the modeled box, with the front ahead of the rear. Spar kinks change the structural box, caps, runouts and tank boundaries. Spar reference paths use the base trapezoid, while the structural skin, nose and spar heights follow the refined airfoil loft. Extra kink mesh rows do not add physical ribs.",
    "Each rear-spar point has a Stringer angle in degrees, default 0, measured from the rear-spar segment arriving from the previous point (or the root). Stringers follow continuous piecewise paths and may kink at those stations. The final segment to the tip reuses the last angle relative to its own rear-spar segment. With rear points present, these values replace the hidden global stringer angle. Removing every rear point restores the global angle. A point at the root has no incoming segment; its angle is used only when it is the sole rear point.",
    "Structure groups Spars, Ribs and Leading Edge in separate forms. Leading Edge contains Pylon / leading-edge gaps. Enter excluded physical bay numbers or ranges, for example 2,4-6, or check numbered bays. Bay b spans ribs b and b+1. Exclusions outside the selected leading-edge rib range remain saved but are ignored; excluding all selected bays produces no leading-edge mesh. The Mesh lock protects the gap definition.",
    "Lock Planform protects the base wing geometry, aerodynamic edge points and airfoils; Lock Mesh protects spar points, box layout, subdivisions and RBE3/support parameters. Use both locks to keep geometry and meshing inputs fixed while editing material or property tables. Blank property-table cells inherit the defaults. Study and TOML saves retain all panel, rib and spar-bay overrides; Studies also retain the editing locks.",
    "2. Open Cases under Loads. Name each case and choose Prescribed lift, or Aerodynamic (VLM) to compute loads from speed, density and angle of attack. Add or duplicate cases to compare conditions. VLM controls the shared aerodynamic mesh.",
    "3. Open VLM for Mesh, Pressure (Pa) and Cp views and transferred forces/moments. Choose Linear static (101), Buckling (105), or Nonlinear comparison (106 + 101) in Analysis and press Run in JFEM; all included cases are solved. Results, the written Deck and the Log each have their own tab. Normal modes (103) use no applied loads.",
    "Save Study and Load Study in the top header use a portable .wingfem.json file containing parameters, load cases, embedded 3D references, display options and camera/panel settings. Load Study offers recent projects and a Browse action. Open latest disk file reads the current file; Open stored copy restores its last saved or loaded snapshot. Results stay in their analysis folders. Loading regenerates the mesh; run the analysis for fresh results from Analysis → Run in JFEM. New Study starts from the application defaults without writing a file.",
    "Display starts with Axes & labels: show shell x directions, bar axes, node IDs and element IDs there. Beam sections switches between lines and full 3D sections. Left-click the model to center without changing view direction; in Inspect or measurement mode, the click performs that tool's action instead. Middle-click a node to center precisely, drag to orbit, right-drag to pan and wheel to zoom. Top points global +X downwards. Notes opens the modification-intent field; Save Study records changed notes with their save time.",
    "Drag the boundary beside the options pane to change its width. Focus the boundary and use Left/Right arrows for fine adjustment, Shift for larger steps, or Home/End for the limits. The 2D geometry and structure tabs, Deck and Log offer Maximize and Restore. In 2D drawings, drag a handle to edit geometry; drag elsewhere or middle-drag to pan. Wheel to zoom; hold Alt for fine adjustment. Ctrl/Cmd moves or scales only the reference image. Image settings controls its scale and opacity. White background toggles the drawing sheet; Export SVG downloads the visible drawing with its embedded image. Study and TOML retain all 2D drawing images, alignment, grids, snapping and dimensions. Enable Snap to points and/or lines when measuring. After selecting two distance anchors or three angle anchors, move the mouse to place the annotation and click once more to finish; Escape cancels the unfinished dimension.",
    "Save TOML as saves parameters, load cases, linked 3D reference paths and all embedded 2D drawing images, view settings and dimensions. Other display preferences and embedded 3D geometry use Study files; results stay separate. Save Study updates its linked file; the first save and Save Study as open a filename and folder picker where supported. Orange means unsaved changes and green means saved. Otherwise the browser downloads the file using its download settings; enable Ask where to save each file to choose a folder. The header reports filenames because browsers do not disclose full picker paths.",
    "Live mesh automatically rebuilds after geometry, mesh, material, section, support or load edits. Turn it off for manual updates with Create FEM, which moves immediately to its left in the top bar. The header's Server input menu shows the configured server path: Overwrite server input explicitly replaces that file; Reload server input restores its parameters. Study/TOML imports never overwrite it. TOML reference paths resolve relative to this server input folder; use a Study when moving embedded geometry between folders or computers.",
    "Translucent uses per-pixel depth ordering on supported WebGL 2 graphics devices, including imported shell batches. Up to ten transparent depth layers are retained per pixel; deeper interiors may be omitted in dense or grazing views, and coincident faces remain ambiguous. Isolate components or use Solid to inspect them. Unsupported devices use approximate mesh sorting and report the fallback in the Log.",
  ] },
  "Load cases": { title: "Define load cases", paragraphs: [
    "Each named case is a separate loading condition on the same structural model. Select a case to edit it. Add creates a new case using case 1 as a starting point; Duplicate copies the selected case. All values in new cases are independent.",
    "Prescribed lift: enter the total lift on this half wing and choose its spanwise distribution. Aerodynamic (VLM): enter air speed, density and angle of attack; the solver uses the wing camber, sweep, twist and dihedral to compute lift and induced drag.",
    "Added y torque is a total couple about global y, distributed to the RBE3 centers. Positive follows the right-hand rule. Load multiplier defaults to 1.5 to convert limit loads to ultimate loads, provided the prescribed lift or VLM flight condition already represents limit loading. It scales forces and moments together; a negative value reverses them. It does not calculate an aircraft maneuver load factor.",
    "Aerodynamic forces and moments, including added torque, act at the external-load RBE3 centers on rib planes. Fuel and structural inertia forces and moments act at mid-bay mass RBE3 centers. If there are no fuel references, massless bay RBE3s use the same rib-to-skin attachments without adding mass. Transferring a force adds its lever-arm moment so the full force and moment resultant is preserved. Tip overhang loads therefore create a moment at the last rib. Display > Entities > Applied moments shows these moments; inspect either RBE3 family or its reference GRID for signed source contributions. The Log reports transfer checks and the terminal moment breakdown.",
    "To enable follower forces: open Cases, select the case under Case to edit, and check Follower forces (SOL101 / SOL106). Repeat for other cases as needed. In Analysis choose Linear static (101) or Nonlinear comparison (106 + 101), then Run in JFEM. The checkbox and status below it show the selected case's setting; study and TOML files preserve it.",
    "SOL106 rotates each station's FORCE direction with its rotation vector; SOL101 retains the first-order load stiffness about zero rotation. Mass inertia forces and all applied moments remain fixed in global axes. VLM pressures are generated once on the undeformed wing. Turning Follower forces off keeps all loads fixed. Normal modes (103) ignores applied loads, and follower forces are not supported for Buckling (105).",
    "The first case is always included. Extra cases can be excluded without deleting their values. Imported inputs may inherit fields from case 1: these show the effective value and a From case 1 note until edited.",
    "Live mesh applies edits to the loads and their display automatically. Create FEM also updates on demand. Run in JFEM solves all included cases in Linear static, Nonlinear comparison or Buckling analysis. The Display and Results case selectors inspect generated cases; this editor defines their inputs.",
  ] },
  "VLM settings": { title: "What VLM settings control", paragraphs: [
    "Magenta arrows at VLM quad centers show signed panel-normal pressure force: pressure jump times panel area. Tangential and induced-drag components remain in the full resultant transferred to the RBE3s. Arrow length multiplier changes only drawn size, using a common metres-per-newton scale across cases. Load plots provides the spanwise distributions.",
    "The VLM tab defines a shared aerodynamic lattice for every case whose load method is Aerodynamic (VLM). Define the flight conditions in the Cases tab. Prescribed-lift cases do not use this lattice.",
    "Span and chord panels control the aerodynamic resolution, independently of the structural shell mesh. The vortex lattice lies on the wing camber surface. Increase the resolution and compare loads to check convergence.",
    "Once the model updates, use Aerodynamic view below: choose a load case, then Mesh, Pressure (Pa) or Cp. Hide VLM removes the lattice and contour. The force/moment switches show loads transferred to RBE3 centers. The same controls remain available in Display. Fully solid skins can hide the camber sheet; use Translucent or hide a skin to see internal panels.",
    "Pressure and Cp are lower-minus-upper jumps, not separate upper/lower surface pressures. Cp divides the pressure difference by dynamic pressure.",
    "VortexLattice.jl models steady attached flow and induced drag, with a Prandtl?Glauert transformation for subsonic compressibility through Mach 0.5. It does not model shocks, stall, viscous drag or aeroelastic feedback. Forces and moments transfer to rib RBE3 centers preserving total force and moment.",
  ] },
  "Beam sections": { title: "Stringers and spar caps", paragraphs: [
    "The two section cards show proportional cross sections as you edit the dimensions, including dimension arrows, centroid, area, skin contact and local axes. Inputs use metres; the drawing labels use millimetres. Invalid dimensions clear the preview until corrected.",
    "Stringers use T sections. Define the flange width, total height, flange thickness and web thickness in metres. The flange lies against the skin and the web points into the wing box. Spar caps use solid square sections, defined by side length.",
    "These dimensions determine the PBARL properties written to NASTRAN and the 3D shapes. Use Display → Beam sections → Full 3D sections to inspect their orientation. The shapes use the physical dimensions without display enlargement.",
    "The section surface lies at the skin and its profile extends into the box, with the same offsets used in the deck. Runout bars retain their prescribed area of 0.001 m² and are displayed as lines. Skin local x follows the stringers; rib shell x stays horizontal in the rib plane, signed toward global +X, including angled leading-edge ribs. The element connectivity may have a different first-edge direction.",
  ] },
  "Materials": {title:"Materials and component assignments",paragraphs:[
    "Material 1 retains the original material fields. Add or edit further isotropic materials below; E is entered in GPa and stored in Pa. Poisson ratio must satisfy 0 ≤ ν < 0.5; the native MAT1 path does not support negative auxetic values. The example core values are editable starting points, not product data. An isotropic core does not describe orthotropic honeycomb behavior.",
    "Choose materials in each Properties sub-tab. Shells may use a monolithic layer or a symmetric face/core/face sandwich. Face thickness is the thickness of each face. Per-rib or spar-bay overrides specify total laminate thickness and change only the core thickness. Beam sections use the selected isotropic material.",
    "Sandwich decks use explicit PCOMP layers. Recovered face stresses are evaluated at the outer ply midpoints; they are not exact outer-surface stresses or failure indices.",
  ]},
  "Rib properties": {title:"Rib webs and vertical T stiffeners",paragraphs:[
    "The default main-box rib web is 2 mm thick. Override any physical rib by number; blank cells inherit the current defaults. Global inputs use metres and the override table uses mm. Rib layout and orientations remain in Structure → Ribs.",
    "Vertical stiffeners use PBARL T sections and share nodes with the rib web from lower to upper skin at physical stringer columns. Refining the skin mesh does not add stiffeners. Their flange lies in the rib plane, with the web projecting into the outboard bay (inboard at the final rib). Override dimensions or turn stiffeners off for individual ribs. Display → Full 3D sections shows their orientation."
  ]},
  "Spar properties": {title:"Spar webs and caps",paragraphs:[
    "The web default is 3 mm. Optional bay overrides set the front and rear spar independently, in mm. Bay b spans physical ribs b and b+1. Blank cells inherit the default, including after you change that default.",
    "Square spar caps use PBARL BAR dimensions and run along the skin intersections. This tab changes properties; edit spar paths in Structure → Spars. Study and TOML saves retain the per-bay overrides."
  ]},
  "Analysis": { title: "Choose an analysis", paragraphs: [
    "Static (101) computes displacement, stress and element forces for every included load case. Normal modes (103) computes the unloaded natural frequencies and shapes. Buckling (105) uses each case as a separate preload and computes its buckling factors.",
    "Nonlinear comparison (106 + 101) runs a linear SOL101 baseline and an experimental geometric nonlinear SOL106 analysis for each included load case, using identical mesh, supports and load definitions. Materials remain elastic. Forces are fixed unless Follower forces is enabled for the case: SOL106 then rotates forces with each RBE3 station and SOL101 uses their first-order small-rotation linearization. Applied moments retain their global directions. The VLM is not recalculated during deformation; this is not a coupled aeroelastic solution.",
    "In Results choose the physical load case and analysis, then enable Show both solutions to overlay their deformed shapes at the same magnification. Real scale sets static translations and rotations to exactly 1:1. The selected analysis supplies contour colors and inspected results. If full load fails, a red warning identifies the last accepted nonlinear state and its comparison at the same load. Fixed-load SOL101 results scale exactly; follower SOL101 is solved again at that load. A failed attempt is never displayed as a converged state.",
    "Run in JFEM writes the deck and solves it. Write deck opens the NASTRAN file in the Deck tab, where Maximize fills the workspace for reading. Save Study, Load Study and the TOML file actions stay in the top header; explicit server-file actions are in its Server input menu. Use Results to inspect solved conditions and Log to follow progress.",
  ] },
};

function openHelp(topic, title) {
  const content = typeof topic === "string" ? HELP_TOPICS[topic] : topic;
  if (!content) return;
  document.getElementById("help-title").textContent = title || content.title;
  const host = document.getElementById("help-content"); host.innerHTML = "";
  for (const text of content.paragraphs || []) {
    const p = document.createElement("p"); p.textContent = text; host.appendChild(p);
  }
  const dialog = document.getElementById("help-dialog");
  if (dialog.showModal) { if (!dialog.open) dialog.showModal(); }
  else { dialog.hidden = false; dialog.setAttribute("open", ""); }
}

function helpButton(title, topic) {
  const button = document.createElement("button");
  button.type = "button"; button.className = "help-icon"; button.textContent = "?";
  button.title = "Help: " + title; button.setAttribute("aria-label", "Help: " + title);
  button.onclick = (event) => {
    if (event) { event.preventDefault(); event.stopPropagation(); }
    openHelp(topic);
  };
  return button;
}

// The persisted/API material modulus remains SI for existing input files and
// NASTRAN. Only the editable field is expressed in GPa.
function parameterDisplayValue(key, value) {
  return key === "material.E" ? Number(value) / 1e9 : value;
}

function parameterModelValue(key, value) {
  return key === "material.E" ? Number((value * 1e9).toPrecision(15)) : value;
}

const JSON_TABLE_KINDS = new Set(["planformpoints","masterribs","riborientations","airfoilstations","supportsets","ribproperties","sparproperties","panelproperties","materials","shellmaterials","barmaterials"]);
function parameterRow(spec, values) {
  const unitText = spec.key === "material.E" ? "GPa" : spec.unit;
  const helpText = spec.key === "material.E" ? "Young's modulus in GPa: 71 GPa = 71000000000 Pa. Calculations, saved inputs and NASTRAN use Pa." : spec.help;
  const row = document.createElement("div"); row.className = "row"; row.id = "row-" + spec.key;
  const labelWrap = document.createElement("div"); labelWrap.className = "field-label";
  const label = document.createElement("label"); label.htmlFor = "p-" + spec.key; label.textContent = spec.label;
  if (unitText) { const unit = document.createElement("span"); unit.className = "unit"; unit.textContent = unitText; label.appendChild(unit); }
  labelWrap.appendChild(label);
  if (helpText) labelWrap.appendChild(helpButton(spec.label, { title: spec.label, paragraphs: [helpText] }));
  row.appendChild(labelWrap);
  const input = document.createElement(spec.kind === "choice" ? "select" : "input");
  if (JSON_TABLE_KINDS.has(spec.kind)) { input.type = "hidden"; input.value = JSON.stringify(values[spec.key] || []); row.hidden = true; }
  else if (spec.kind === "bool") { input.type = "checkbox"; input.checked = !!values[spec.key]; }
  else if (spec.kind === "choice") {
    for (const c of spec.choices) { const option = document.createElement("option"); option.value = c; option.textContent = CHOICE_LABELS[c] || c; input.appendChild(option); }
    input.value = String(values[spec.key]);
  } else {
    input.type = spec.kind === "string" ? "text" : "number";
    input.step = spec.kind === "int" ? "1" : "any";
    input.value = String(parameterDisplayValue(spec.key, values[spec.key]));
  }
  input.id = "p-" + spec.key; input.title = helpText || spec.label;
  input.addEventListener("input", () => { parameterEdited(spec.key); if (spec.key === "output.solution") updateCaseAnalysisNote(); });
  input.addEventListener("change", () => { parameterEdited(spec.key); if (spec.key === "output.solution") updateCaseAnalysisNote(); });
  row.appendChild(input); return row;
}

const WORKSPACE_TABS = [
  ["Geometry", "planform", "Planform"], ["Geometry", "airfoils", "Airfoils"], ["Geometry", "box", "Spars"], ["Geometry", "ribs", "Ribs"],
  ["Geometry", "leadingedge", "Leading Edge"], ["Geometry", "fuel", "Fuel tank"],
  ["Model", "mesh", "Structural Mesh"], ["Model", "vlmmesh", "VLM"], ["Model", "material", "Materials"], ["Model", "shells", "Skins"],
  ["Model", "sections", "Stringers"], ["Model", "ribproperties", "Ribs"], ["Model", "sparproperties", "Spars"], ["Model", "leproperties", "Leading Edge"], ["Model", "supports", "Supports"],
  ["Summary", "weights", "Mass properties"], ["Summary", "summary", "General"],
  ["Loads", "cases", "Cases"], ["Loads", "vlm", "Aerodynamics"], ["Loads", "loadplots", "Load plots"], ["Loads", "sensitivity", "Sensitivity"],
  ["Solve", "analysis", "Analysis"], ["Solve", "results", "FE Results"], ["Solve", "sensitivityresults", "Sensitivity"], ["Solve", "deck", "Deck"], ["Solve", "log", "Log"],
  ["View", "display", "Entities"], ["View", "displayproperties", "Properties"], ["View", "displayappearance", "Appearance"], ["View", "displaylabels", "Axes & labels"], ["View", "displayenvironment", "Environment"], ["View", "displaymass", "Mass properties"], ["View", "reference", "Reference"], ["View", "inspect", "Inspect"],
];
const WORKSPACE_GROUP_TAB = {
  "Planform": "planform", "Airfoils": "airfoils", "Torsion box": "box", "Ribs": "ribs", "Fuel tank": "fuel", "Mesh": "mesh", "Material": "material",
  "Shell properties": "shells", "Beam sections": "sections", "RBE3 and supports": "supports", "Weights": "weights", "Leading edge": "leadingedge",
  "Rib properties": "ribproperties", "Spar properties": "sparproperties", "Leading-edge properties": "leproperties", "Materials": "material",
  "Load cases": "cases", "VLM settings": "vlmmesh", "Sensitivity":"sensitivity", "Analysis": "analysis", "JFEM solver": "analysis",
};
const WORKSPACE_CARD_TAB = { "hud-left": "display", "model-card": "summary", "results-card": "results",
  "pick-card": "inspect", "log-wrap": "log", "deck-panel": "deck", "reference-panel": "reference" };
const workspaceUI = { activeTab: "planform", previousTab: "planform", maximizedTab: null, preferredWidth: 360 };
const DRAWING_TABS = new Set(["planform", "airfoils", "box", "ribs", "leadingedge", "fuel", "sections", "ribproperties", "sparproperties"]);
const PROPERTY_TABS = new Set(["shells", "sections", "ribproperties", "sparproperties", "leproperties"]);
const SUMMARY_TABS = new Set(["weights", "summary"]);
const WORKSPACE_MENUS = {
  structure:{tabs:new Set(["box","ribs","leadingedge"]),current:"box",label:"Structure"},
  meshing:{tabs:new Set(["mesh","vlmmesh"]),current:"mesh",label:"Mesh"},
  properties:{tabs:PROPERTY_TABS,current:"shells",label:"Properties"},
  overview:{tabs:SUMMARY_TABS,current:"weights",label:"Summary"},
  resultsmenu:{tabs:new Set(["results","sensitivityresults"]),current:"results",label:"Results"},
  displaymenu:{tabs:new Set(["display","displayproperties","displayappearance","displaylabels","displayenvironment","displaymass"]),current:"display",label:"Display"},
};
const WORKSPACE_MAIN_TABS = WORKSPACE_TABS.filter(([,id]) => !["sections","ribproperties","sparproperties","leproperties","summary","ribs","leadingedge","vlmmesh","sensitivityresults","displayproperties","displayappearance","displaylabels","displayenvironment","displaymass"].includes(id)).map(tab => tab[1] === "box" ? ["Geometry","structure","Structure"] : tab[1] === "mesh" ? ["Model","meshing","Mesh"] : tab[1] === "shells" ? ["Model", "properties", "Properties"] : tab[1] === "weights" ? ["Summary","overview","Summary"] : tab[1] === "results" ? ["Solve","resultsmenu","Results"] : tab[1] === "display" ? ["View","displaymenu","Display"] : tab);
const parentTab = id => Object.keys(WORKSPACE_MENUS).find(key=>WORKSPACE_MENUS[key].tabs.has(id));

function closeWorkspaceMenu(id, focus = false) {
  const menu = document.getElementById(id + "-menu"), button = document.getElementById("tab-" + id);
  if (menu) menu.hidden = true;
  button?.setAttribute("aria-expanded", "false");
  if (focus) button?.focus();
}

function openWorkspaceMenu(id) {
  const menu = document.getElementById(id + "-menu"), button = document.getElementById("tab-" + id);
  if (!menu || !button) return;
  if (!menu.hidden) { closeWorkspaceMenu(id, true); return; }
  for (const other of Object.keys(WORKSPACE_MENUS)) if(other!==id)closeWorkspaceMenu(other);
  const rect = button.getBoundingClientRect();
  menu.hidden = false;
  menu.style.left = Math.max(4, Math.min(rect.left, window.innerWidth - menu.offsetWidth - 4)) + "px";
  menu.style.top = rect.bottom + "px";
  button.setAttribute("aria-expanded", "true");
  document.getElementById("tab-" + WORKSPACE_MENUS[id].current)?.focus();
}

function activateWorkspaceTab(id, options = {}) {
  if (id === "planview") id = "planform"; // Legacy Studies: never open a popup on restore.
  if (WORKSPACE_MENUS[id]) id = WORKSPACE_MENUS[id].current;
  if (id === "sensitivityresults" && !sensitivityResultsAvailable()) id = "results";
  if (id === "results" && state.sensitivityMap) clearSensitivityMap();
  if (id === "results" && state.propertyDisplay?.enabled) {state.propertyDisplay.setEnabled(false);applyContour();}
  if (id === "results" && state.data) {
    // Panel/tank inspection can be entered after the baseline was loaded.
    // These temporary isolation modes must not lock the shell switches or
    // keep the physical solution hidden when returning to FE Results.
    if (state.panelView) setPanelDisplay(false);
    restoreFuelIsolation();
    document.getElementById("results-card").hidden = !state.results;
    applyContour(); applyDeformation();
  }
  const tab = WORKSPACE_TABS.find((item) => item[1] === id);
  if (!tab) return false;
  if (workspaceUI.activeTab !== id) workspaceUI.previousTab = workspaceUI.activeTab;
  workspaceUI.activeTab = id;
  const parent = parentTab(id);
  if (parent) WORKSPACE_MENUS[parent].current = id;
  for (const panel of document.querySelectorAll("[data-workspace-panel]")) panel.hidden = panel.dataset.workspacePanel !== id || panel.hasAttribute("data-imported-only") && !state.importedDeck;
  for (const button of document.querySelectorAll("[data-workspace-tab]")) {
    const selected = button.dataset.workspaceTab === id || button.dataset.workspaceTab === parent;
    const submenu = button.getAttribute("role") === "menuitemradio";
    button.setAttribute(submenu ? "aria-checked" : "aria-selected", String(selected)); button.tabIndex = submenu ? -1 : selected ? 0 : -1;
    button.classList.toggle("active", selected);
  }
  for (const key of Object.keys(WORKSPACE_MENUS)) closeWorkspaceMenu(key);
  const title = document.getElementById("workspace-title"); if (title) title.textContent = (parent ? WORKSPACE_MENUS[parent].label + " / " : "") + tab[2];
  const pane = document.getElementById("sidebar");
  if (pane && pane.classList.contains("panel-collapsed")) {
    const toggle = pane.querySelector(".panel-toggle"); if (toggle) toggle.click();
  }
  if (workspaceUI.maximizedTab && id !== workspaceUI.maximizedTab) setWorkspaceMaximized(null);
  syncDrawingMaximizeButton();
  const selected = document.getElementById("tab-" + (parent || id));
  if (selected && selected.scrollIntoView) selected.scrollIntoView({ block: "nearest", inline: "nearest" });
  if (options.focus && selected && selected.focus) selected.focus();
  if (id === "deck") {
    if (state.lastDeck) { document.getElementById("deck-panel").hidden = false; refreshDeckMetadata(); }
    if (!options.skipDeckLoad) loadLastDeck();
  }
  if (id === "log" && liveLog.follow) logEl.scrollTop = logEl.scrollHeight;
  if (id === "sensitivity") state.sensitivity?.refreshContext();
  if (state.data) applyAeroOverlayStyles();
  state.viewportTools?.syncInspection?.();
  if (state.engine) state.engine.resize();
  return true;
}

function installWorkspaceNavigation() {
  const host = document.getElementById("workspace-tablist"); if (!host) return;
  host.innerHTML = "";
  let groupName = "", cluster = null, buttons = null;
  for (const [group, id, label] of WORKSPACE_MAIN_TABS) {
    if (group !== groupName) {
      groupName = group;
      cluster = document.createElement("div"); cluster.className = "tab-cluster"; cluster.setAttribute("role", "presentation");
      const caption = document.createElement("span"); caption.className = "tab-cluster-label"; caption.textContent = group; caption.setAttribute("aria-hidden", "true");
      buttons = document.createElement("div"); buttons.className = "tab-cluster-buttons"; buttons.setAttribute("role", "presentation");
      cluster.append(caption, buttons); host.appendChild(cluster);
    }
    const button = document.createElement("button"); button.id = "tab-" + id; button.className = "workspace-tab"; button.type = "button";
    button.setAttribute("role", "tab"); button.setAttribute("data-workspace-tab", id);
    const parameterGroup = Object.keys(WORKSPACE_GROUP_TAB).find((name) => WORKSPACE_GROUP_TAB[name] === id);
    button.setAttribute("aria-controls", parameterGroup ? "group-" + parameterGroup.toLowerCase().replace(/[^a-z0-9]+/g, "-") : "panel-" + id);
    button.setAttribute("aria-label", group + ": " + label); button.textContent = label;
    if (WORKSPACE_MENUS[id]) { button.setAttribute("aria-haspopup", "menu"); button.setAttribute("aria-expanded", "false"); button.textContent = label + " ▾"; }
    button.onclick = () => WORKSPACE_MENUS[id] ? openWorkspaceMenu(id) : activateWorkspaceTab(id);
    button.onkeydown = (event) => {
      if (WORKSPACE_MENUS[id] && event.key === "ArrowDown") { event.preventDefault(); openWorkspaceMenu(id); return; }
      const index = WORKSPACE_MAIN_TABS.findIndex((item) => item[1] === id);
      const target = event.key === "ArrowRight" ? (index + 1) % WORKSPACE_MAIN_TABS.length : event.key === "ArrowLeft" ? (index + WORKSPACE_MAIN_TABS.length - 1) % WORKSPACE_MAIN_TABS.length : event.key === "Home" ? 0 : event.key === "End" ? WORKSPACE_MAIN_TABS.length - 1 : -1;
      if (target >= 0) { event.preventDefault(); activateWorkspaceTab(WORKSPACE_MAIN_TABS[target][1], { focus: true }); }
    };
    buttons.appendChild(button);
  }
  for (const [menuId, definition] of Object.entries(WORKSPACE_MENUS)) {
  document.getElementById(menuId + "-menu")?.remove();
  const menu = document.createElement("div"); menu.id = menuId + "-menu"; menu.className = "properties-menu"; menu.hidden = true; menu.setAttribute("role", "menu"); menu.setAttribute("aria-label", definition.label);
  document.getElementById("tab-" + menuId).setAttribute("aria-controls",menu.id);
  for (const [,id,label] of WORKSPACE_TABS.filter(([,id]) => definition.tabs.has(id))) {
    const button = document.createElement("button"); button.id = "tab-" + id; button.type = "button"; button.textContent = label; button.dataset.workspaceTab = id;
    button.setAttribute("role", "menuitemradio"); button.onclick = () => activateWorkspaceTab(id, {focus:true});
    button.onkeydown = event => {
      if (event.key === "Escape") { event.preventDefault(); closeWorkspaceMenu(menuId,true); }
      else if (["ArrowUp","ArrowDown","Home","End"].includes(event.key)) { event.preventDefault(); const items = [...menu.children].filter(item=>!item.disabled), at = items.indexOf(button); items[event.key === "Home" ? 0 : event.key === "End" ? items.length - 1 : (at + (event.key === "ArrowDown" ? 1 : items.length - 1)) % items.length]?.focus(); }
      else if (event.key === "Tab") closeWorkspaceMenu(menuId,true);
    };
    menu.appendChild(button);
  }
  document.body.appendChild(menu);
  document.addEventListener("pointerdown", event => { if (!menu.contains(event.target) && !document.getElementById("tab-" + menuId)?.contains(event.target)) closeWorkspaceMenu(menuId); });
  window.addEventListener("resize", () => closeWorkspaceMenu(menuId));
  }
  for (const button of document.querySelectorAll("[data-workspace-target]")) button.onclick = () => activateWorkspaceTab(button.dataset.workspaceTarget);
  activateWorkspaceTab(workspaceUI.activeTab);
  updateAnalysisValidity();
}

function paneWidthBounds() {
  const body = document.getElementById("workspace-body");
  const available = body && body.clientWidth || window.innerWidth || 1024;
  const minimum = Math.min(260, Math.max(160, Math.floor(available * 0.45)));
  const viewportMinimum = Math.min(300, Math.max(160, available * 0.4));
  return { minimum, maximum: Math.max(minimum, Math.min(680, Math.floor(available - viewportMinimum - 7))) };
}

function setPaneWidth(width, remember = true) {
  const { minimum, maximum } = paneWidthBounds();
  const finite = Number.isFinite(width) ? width : 360;
  const clamped = Math.round(Math.max(minimum, Math.min(maximum, finite)));
  if (remember) workspaceUI.preferredWidth = clamped;
  const app = document.getElementById("app");
  if (app.style && app.style.setProperty) app.style.setProperty("--pane-width", clamped + "px");
  const resizer = document.getElementById("pane-resizer");
  if (resizer) {
    resizer.setAttribute("aria-valuemin", String(minimum)); resizer.setAttribute("aria-valuemax", String(maximum));
    resizer.setAttribute("aria-valuenow", String(clamped)); resizer.setAttribute("aria-valuetext", clamped + " pixels");
  }
  if (state.engine) state.engine.resize();
  return clamped;
}

function installPaneResize() {
  const resizer = document.getElementById("pane-resizer");
  if (!resizer || !resizer.getBoundingClientRect) return;
  try { const saved = Number(window.localStorage.getItem("WingFEGen.paneWidth")); if (saved > 0) workspaceUI.preferredWidth = saved; } catch (_) { /* storage can be disabled */ }
  const persist = () => { try { window.localStorage.setItem("WingFEGen.paneWidth", String(workspaceUI.preferredWidth)); } catch (_) {} };
  let pointer = null;
  const stop = (event) => {
    if (pointer === null || event && event.pointerId !== pointer) return;
    pointer = null; document.getElementById("app").classList.remove("pane-resizing"); persist();
  };
  resizer.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || workspaceUI.maximizedTab) return;
    event.preventDefault(); pointer = event.pointerId; resizer.setPointerCapture(pointer); resizer.focus();
    document.getElementById("app").classList.add("pane-resizing");
  });
  resizer.addEventListener("pointermove", (event) => {
    if (event.pointerId !== pointer) return;
    const body = document.getElementById("workspace-body").getBoundingClientRect();
    setPaneWidth(event.clientX - body.left - 3.5);
  });
  resizer.addEventListener("pointerup", stop); resizer.addEventListener("pointercancel", stop);
  resizer.addEventListener("lostpointercapture", stop);
  resizer.addEventListener("dblclick", () => { setPaneWidth(360); persist(); });
  resizer.addEventListener("keydown", (event) => {
    const { minimum, maximum } = paneWidthBounds(); const current = Number(resizer.getAttribute("aria-valuenow"));
    const step = event.shiftKey ? 40 : 10;
    const width = event.key === "ArrowLeft" ? current - step : event.key === "ArrowRight" ? current + step : event.key === "Home" ? minimum : event.key === "End" ? maximum : null;
    if (width === null) return;
    event.preventDefault(); event.stopPropagation(); setPaneWidth(width); persist();
  });
  window.addEventListener("resize", () => setPaneWidth(workspaceUI.preferredWidth, false));
  setPaneWidth(workspaceUI.preferredWidth, false);
}

function buildForm(schema, values) {
  // Drawing state belongs to the Study, not the meshing inputs. Keep it across
  // form reconstruction, including lazy airfoil previews and removed SVG nodes.
  const drawings = typeof WingSVGViewport !== "undefined" ? WingSVGViewport.captureAll() : {};
  if (typeof WingSVGViewport !== "undefined") { WingSVGViewport.destroyAll(); WingSVGViewport.restoreAll(drawings); }
  if (typeof WingPlanformView !== "undefined" && WingPlanformView.migratePointParams) values = WingPlanformView.migratePointParams(values);
  state.airfoilEditor?.destroy?.(); state.airfoilEditor = null;
  state.supportEditor?.destroy?.(); state.supportEditor = null;
  state.materialsEditor?.destroy?.(); state.materialsEditor = null;
  for(const editor of state.componentEditors || [])editor.destroy(); state.componentEditors=[];
  state.planformEditor?.destroy?.();
  const planformMethod = state.planformInputs?.capture();
  state.planformInputs?.destroy?.();
  state.planformInputs = null;
  state.sparEditor?.destroy?.();
  state.leadingEdgeGaps?.destroy?.();
  state.ribEditor?.destroy?.(); state.ribEditor = null;
  state.leadingEdgeRibEditor?.destroy?.(); state.leadingEdgeRibEditor = null;
  state.fuelTankView?.destroy?.();
  state.fuelTankView = null;
  state.planformEditor = null;
  state.sparEditor = null;
  state.leadingEdgeGaps = null;
  state.loadCases = JSON.parse(JSON.stringify(values["loads.cases"] || []));
  if (!state.loadCases.some((item) => Number(item.id) === Number(state.editingCase))) state.editingCase = 1;
  const host = document.getElementById("form"); host.innerHTML = "";
  const baseInputs = document.createElement("div"); baseInputs.hidden = true; baseInputs.id = "base-load-inputs";
  const byGroup = new Map();
  for (const spec of schema) {
    if (spec.key.startsWith("sensitivity.")) continue;
    if (CASE_GLOBAL_KEYS.has(spec.key)) { baseInputs.appendChild(parameterRow(spec, values)); continue; }
    const name = spec.kind === "loadcases" ? "Load cases" : spec.group === "Aerodynamics" ? "VLM settings" : spec.group === "Output" ? "Analysis" : spec.group === "Properties" ? "Shell properties" : spec.group;
    if (!byGroup.has(name)) byGroup.set(name, []);
    byGroup.get(name).push(spec);
  }
  host.appendChild(baseInputs);
  const order = ["Airfoils", "Planform", "Torsion box", "Ribs", "Leading edge", "Fuel tank", "Mesh", "Material", "Materials", "Shell properties", "Beam sections", "Rib properties", "Spar properties", "Leading-edge properties", "RBE3 and supports", "Weights", "Load cases", "VLM settings", "Analysis", "JFEM solver"];
  const groups = [...byGroup.keys()].sort((a, b) => (order.indexOf(a) < 0 ? 100 : order.indexOf(a)) - (order.indexOf(b) < 0 ? 100 : order.indexOf(b)));
  for (const name of groups) {
    const specs = byGroup.get(name), det = document.createElement("section"); det.className = "group parameter-section workspace-panel";
    det.id = "group-" + name.toLowerCase().replace(/[^a-z0-9]+/g, "-");
    const tabId = WORKSPACE_GROUP_TAB[name] || "analysis";
    det.setAttribute("data-workspace-panel", tabId); det.setAttribute("role", "tabpanel"); det.setAttribute("aria-labelledby", "tab-" + tabId);
    const tabButton = document.getElementById("tab-" + tabId);
    if (tabButton && name !== "JFEM solver") tabButton.setAttribute("aria-controls", det.id);
    const sum = document.createElement("div"); sum.className = "parameter-heading"; const text = document.createElement("h2"); text.textContent = ({"Torsion box":"Spars","Shell properties":"Skins","Beam sections":"Stringers","Rib properties":"Rib properties","Spar properties":"Spar properties"})[name] || name;
    sum.append(text, helpButton(name, HELP_TOPICS[name] || { title: name, paragraphs: specs.map((spec) => spec.label + ": " + (spec.help || "Set the " + spec.label.toLowerCase() + (spec.unit ? " in " + spec.unit : "") + ".")) }));
    det.appendChild(sum);
    if (name === "Analysis") {
      const note = document.createElement("p"); note.id = "analysis-solution-note"; note.className = "group-note"; det.appendChild(note);
    }
    if (name === "VLM settings" || name === "Beam sections") {
      const note = document.createElement("p"); note.className = "group-note";
      note.textContent = name === "VLM settings" ? "Shared aerodynamic mesh. Choose Aerodynamic (VLM) and set flight conditions in the Cases tab." : "T-shaped stringers. Dimensions are in metres; inspect them with Display → Beam sections. Spar caps are in Properties → Spars.";
      det.appendChild(note);
    }
    for (const spec of specs) {
      if (spec.kind === "loadcases") { const editor = document.createElement("div"); editor.id = "load-cases-editor"; det.appendChild(editor); }
      else {const row=parameterRow(spec, values);if(spec.key==="fuel.fill_fraction")row.hidden=true;det.appendChild(row);}
    }
    host.appendChild(det);
    if (["Beam sections","Spar properties"].includes(name) && typeof WingSectionEditor !== "undefined") WingSectionEditor.install(det);
    if(name==="Rib properties" && typeof WingSectionEditor!=="undefined") WingSectionEditor.install(det,{definitions:[["T","Default rib T stiffener",["rib_stiffener_flange_width","rib_stiffener_height","rib_stiffener_flange_thickness","rib_stiffener_web_thickness"],"rib-stiffener-editor","rib-stiffener-section",true]]});
    if(["Rib properties","Spar properties"].includes(name) && typeof WingComponentProperties!=="undefined") {
      const editor=WingComponentProperties.install(det,{kind:name==="Rib properties"?"ribs":"spar_bays",onEdit:parameterEdited,readRibs:currentSupportRibs});if(editor)state.componentEditors.push(editor);
    }
    if (name === "Airfoils" && typeof WingAirfoils !== "undefined") state.airfoilEditor = WingAirfoils.install(det, { onEdit: parameterEdited, onHelp: openHelp, isLocked: () => state.parameterLocks?.isLocked("airfoil.root") || false });
    if (name === "RBE3 and supports" && typeof WingSupports !== "undefined") state.supportEditor = WingSupports.install(det, {
      onEdit:parameterEdited,readRibs:currentSupportRibs,isLocked:()=>state.parameterLocks?.isLocked("supports.items") || false,
    });
    if (name === "Fuel tank" && typeof WingFuelTankView !== "undefined") state.fuelTankView = WingFuelTankView.install(det, {
      readValues: () => readSurfacePreviewParams(WingFuelTankView),
    });
    if (name === "Planform" && typeof WingPlanformView !== "undefined") state.planformEditor = WingPlanformView.install(det, {
      readValues: readPlanformParams, onEdit: parameterEdited,
      openDimensionedView: typeof WingPlanViewWindow !== "undefined" ? () => state.planView?.open() : undefined,
      isLocked: () => state.parameterLocks?.isLocked("planform.area") || false,
    });
    if (name === "Planform" && typeof WingPlanformInputs !== "undefined") {
      state.planformInputs = WingPlanformInputs.install(det, {readValues:readPlanformParams,onEdit:parameterEdited,isLocked:()=>state.parameterLocks?.isLocked("planform.area") || false});
      if (planformMethod) state.planformInputs?.restore(planformMethod);
      const drawing = det.querySelector(".planform-editor-sticky");
      if (drawing && state.planformInputs) {
        const base = document.createElement("div"); base.className = "planform-base-inputs";
        base.appendChild(det.querySelector(".planform-input-method"));
        for (const spec of specs.filter(spec => spec.kind !== "planformpoints")) {
          const row = document.getElementById("row-" + spec.key); if (row) base.appendChild(row);
        }
        drawing.after(base);
        const hint = det.querySelector(".planform-editor-help");
        if (hint) hint.innerHTML = hint.innerHTML.replace("Define the trapezoid below, then refine either edge with points.", "Refine either edge of the base trapezoid with points.");
      }
    }
    if (name === "Torsion box" && typeof WingSparView !== "undefined") state.sparEditor = WingSparView.install(det, {
      readValues: () => readPointEditorParams(WingSparView), onEdit: parameterEdited,
      isLocked: () => state.parameterLocks?.isLocked("box.front_spar_xc") || false,
    });
    if (name === "Leading edge" && typeof WingLeadingEdgeGaps !== "undefined") state.leadingEdgeGaps = WingLeadingEdgeGaps.install(det, {
      readValues: () => readEditorParams(WingLeadingEdgeGaps.PARAM_KEYS), onEdit: parameterEdited,
      isLocked: () => state.parameterLocks?.isLocked("leading_edge.disabled_bays") || false,
    });
    if (name === "Ribs" && typeof WingRibLayout !== "undefined") state.ribEditor = WingRibLayout.install(det, {
      readValues:()=>readEditorParams(WingRibLayout.PARAM_KEYS),onEdit:parameterEdited,
      readGenerated:()=>state.modelDirty ? null : state.data?.rib_layout,
      isLocked:()=>state.parameterLocks?.isLocked("ribs.masters") || false,
    });
    if(name === "Ribs" && state.ribEditor) { const row=document.getElementById("row-box.rib_pitch");if(row)row.hidden=true; }
    if (name === "Leading edge" && typeof WingRibLayout !== "undefined") state.leadingEdgeRibEditor = WingRibLayout.installLeadingEdge(det, {
      readValues:()=>readEditorParams(WingRibLayout.PARAM_KEYS),onEdit:parameterEdited,
      readGenerated:()=>state.modelDirty ? null : state.data?.rib_layout,
      isLocked:()=>state.parameterLocks?.isLocked("leading_edge.rib_orientations") || false,
    });
    if(name === "Leading edge") {
      const note=document.createElement("p");note.id="leading-edge-fallback-note";note.className="rib-fallback-warning";note.hidden=true;note.setAttribute("role","status");det.appendChild(note);
    }
    state.parameterLocks?.install(det, name);
  }
  if (typeof WingMaterialsEditor !== "undefined") state.materialsEditor = WingMaterialsEditor.install({document,onEdit:parameterEdited});
  buildLoadCaseEditor();
  installSensitivity();
  installPropertyDisplay();
  state.sensitivity?.restore(values["sensitivity.settings"] || "");
  updateCaseAnalysisNote();
  // A schema can omit a whole tool group (for example a focused fixture).
  // Keep the tab accessible and explain its empty state instead of leaving a
  // blank pane or an aria-controls link to an element that does not exist.
  for (const [, id, label] of WORKSPACE_TABS) {
    let panels = Array.from(document.querySelectorAll("[data-workspace-panel]")).filter((panel) => panel.dataset.workspacePanel === id);
    if (!panels.length && Object.values(WORKSPACE_GROUP_TAB).includes(id)) {
      const panel = document.createElement("section"); panel.id = "panel-" + id; panel.className = "workspace-panel workspace-empty";
      panel.setAttribute("data-workspace-panel", id); panel.setAttribute("role", "tabpanel"); panel.setAttribute("aria-labelledby", "tab-" + id);
      const heading = document.createElement("h2"); heading.textContent = label;
      const note = document.createElement("p"); note.textContent = "No parameters are available for this tool in the current input schema.";
      panel.append(heading, note); host.appendChild(panel); panels = [panel];
    }
    const button = document.getElementById("tab-" + id); if (button && panels.length) button.setAttribute("aria-controls", panels.map((panel) => panel.id).join(" "));
  }
  state.parameterLocks?.formBuilt();
  syncLeadingEdgeOrientation();
  refreshSurfaceEditors();
  installDimensionedPlanView();
  installPanelTables();
  installDrawingWorkbenches();
  for (const [id, menu] of Object.entries(WORKSPACE_MENUS)) {
    const button = document.getElementById("tab-" + id);
    if (button) button.setAttribute("aria-controls", [...document.querySelectorAll("[data-workspace-panel]")].filter(panel => menu.tabs.has(panel.dataset.workspacePanel)).map(panel => panel.id).join(" "));
  }
  activateWorkspaceTab(workspaceUI.activeTab);
}

function installDrawingWorkbenches() {
  // Keep the same live controls and listeners. CSS places the drawing beside
  // independently scrolling parameters when the user maximizes the pane.
  for (const [id,selector] of [["group-planform",".planform-editor-sticky"],["group-torsion-box",".planform-editor-sticky"],["group-fuel-tank",".fuel-tank-view"]]) {
    const group=document.getElementById(id), drawing=group?.querySelector(selector);
    if (!drawing || group.querySelector(".drawing-workbench")) continue;
    const bench=document.createElement("div"),stage=document.createElement("div"),parameters=document.createElement("div");
    bench.className="drawing-workbench";stage.className="drawing-stage";parameters.className="drawing-parameters";
    stage.append(drawing);
    for (const child of Array.from(group.children)) if (!child.classList.contains("parameter-heading")) parameters.append(child);
    bench.append(stage,parameters);group.append(bench);
  }
}

function baseCaseValue(key) {
  const spec = state.schema.find((item) => item.key === key);
  const input = document.getElementById("p-" + key);
  if (spec && spec.kind === "bool") return input ? input.checked : !!state.values[key];
  const raw = spec && input ? input.value : state.values[key];
  if (spec && (spec.kind === "float" || spec.kind === "int")) return raw === "" ? "" : Number(raw);
  return raw;
}

function effectiveCase(c) {
  const fields = Object.fromEntries(CASE_FIELDS.map(([field, , key]) => [field, c && c[field] !== undefined ? c[field] : baseCaseValue(key)]));
  return { ...fields, id: c ? Number(c.id) : 1, label: c ? c.label : baseCaseValue("loads.label") || "Load case 1", enabled: !c || c.enabled !== false };
}

function updateCaseAnalysisNote() {
  const solution = document.getElementById("p-output.solution")?.value || "101";
  const note = document.getElementById("case-analysis-note");
  if (note) note.textContent = solution === "103"
    ? "Normal modes (103) includes structural and fuel mass, but no applied forces. Different fuel percentages receive separate modal solutions, selectable in Results."
    : solution === "106"
      ? "Run in JFEM solves each included case twice: Linear SOL101 and Nonlinear SOL106. In Results, choose an analysis or show both shapes together."
      : "Live mesh applies case edits automatically. Run in JFEM solves all included cases; choose Results to inspect them.";
  for (const spec of state.schema || []) {
    const row = document.getElementById("row-" + spec.key); if (!row) continue;
    if (spec.key.startsWith("nonlinear.")) row.hidden = solution !== "106";
    else if (spec.key === "output.n_modes") row.hidden = !["103", "105"].includes(solution);
    else if (spec.key === "output.buckling_max_factor") row.hidden = solution !== "105";
  }
  const explanation = document.getElementById("analysis-solution-note");
  if (explanation) {
    explanation.hidden = solution !== "106";
    explanation.textContent = "Runs SOL101 and SOL106 for every included case. Experimental geometric nonlinear with elastic material. Forces are fixed unless Follower forces is enabled in Cases. Both shapes use a common deformation scale and load level.";
  }
  updateFollowerGuidance();
}

function updateFollowerGuidance() {
  const input = document.getElementById("case-follower_forces");
  const note = document.getElementById("case-follower-status");
  if (!input || !note) return;
  const supported = (state.schema || []).some((spec) => spec.key === "loads.follower_forces" && spec.kind === "bool");
  input.disabled = !supported;
  const solution = document.getElementById("p-output.solution")?.value || "101";
  const enabled = input.checked;
  note.classList.toggle("case-setting-warning", !supported || (enabled && ["103", "105"].includes(solution)));
  note.textContent = !supported
    ? "Follower forces unavailable from this server. Restart the generator and refresh this page to enable the option."
    : (enabled ? "ON for this case. " : "OFF for this case. Check the box above to enable. ") +
      (solution === "103" ? "Normal modes (103) ignores loads; choose Linear static (101) or Nonlinear comparison (106 + 101) in Analysis."
        : solution === "105" ? (enabled ? "Buckling (105) does not support follower forces. Choose Linear static (101) or Nonlinear comparison (106 + 101) in Analysis, or turn this option off." : "Buckling (105) uses fixed loads. Choose Linear static (101) or Nonlinear comparison (106 + 101) before enabling follower forces.")
          : enabled ? (solution === "106" ? "Run in JFEM will rotate forces in SOL106 and use first-order follower forces in its SOL101 comparison." : "Run in JFEM will use first-order follower forces in SOL101.")
            : "Forces retain their global directions during deformation.");
}

function buildLoadCaseEditor() {
  const host = document.getElementById("load-cases-editor"); if (!host) return;
  host.innerHTML = "";
  const c = state.loadCases.find((item) => Number(item.id) === Number(state.editingCase)) || null;
  state.editingCase = c ? Number(c.id) : 1;
  const current = effectiveCase(c);
  const changed = (key) => parameterEdited(c ? "loads.cases" : key || "loads.label");
  const pickerLabel = document.createElement("label"); pickerLabel.className = "case-picker-label"; pickerLabel.htmlFor = "case-edit-select"; pickerLabel.textContent = "Case to edit";
  const picker = document.createElement("select"); picker.id = "case-edit-select"; picker.setAttribute("aria-label", "Case to edit");
  for (const item of [null, ...state.loadCases]) {
    const info = effectiveCase(item), option = document.createElement("option"); option.value = String(info.id);
    option.textContent = info.id + " · " + info.label + (info.enabled ? "" : " (excluded)"); picker.appendChild(option);
  }
  picker.value = String(current.id); picker.onchange = () => { state.editingCase = Number(picker.value); buildLoadCaseEditor(); };
  host.append(pickerLabel, picker);
  const toolbar = document.createElement("div"); toolbar.className = "case-actions";
  const nextId = () => Math.max(1, ...state.loadCases.map((item) => Number(item.id) || 1)) + 1;
  const newCase = (source, label) => {
    const id = nextId(); state.loadCases.push({ ...effectiveCase(source), id, label: label || "Load case " + id, enabled: true });
    state.editingCase = id; parameterEdited("loads.cases"); buildLoadCaseEditor();
  };
  const add = document.createElement("button"); add.id = "btn-add-load-case"; add.className = "mini"; add.textContent = "+ Add"; add.title = "Add a case using case 1 as a starting point";
  add.disabled = state.loadCases.length >= 64; add.onclick = () => newCase(null);
  const duplicate = document.createElement("button"); duplicate.id = "btn-duplicate-load-case"; duplicate.className = "mini"; duplicate.textContent = "Duplicate";
  duplicate.disabled = add.disabled; duplicate.onclick = () => newCase(c, effectiveCase(c).label + " copy");
  const remove = document.createElement("button"); remove.id = "btn-delete-load-case"; remove.className = "mini danger"; remove.textContent = "Delete"; remove.disabled = !c;
  remove.title = c ? "Delete this case" : "Case 1 is always kept";
  remove.onclick = () => { if (!c) return; state.loadCases = state.loadCases.filter((item) => item !== c); state.editingCase = 1; parameterEdited("loads.cases"); buildLoadCaseEditor(); };
  toolbar.append(add, duplicate, remove); host.appendChild(toolbar);
  const nameLabel = document.createElement("label"); nameLabel.className = "case-name"; nameLabel.textContent = "Case name";
  const name = document.createElement("input"); name.id = "case-name"; name.type = "text"; name.value = current.label; name.setAttribute("aria-label", "Load case name");
  name.oninput = () => {
    if (c) c.label = name.value; else { const base = document.getElementById("p-loads.label"); if (base) base.value = name.value; }
    const selected = Array.from(picker.children).find((option) => Number(option.value) === current.id);
    if (selected) selected.textContent = current.id + " · " + name.value + (c && c.enabled === false ? " (excluded)" : "");
    changed("loads.label");
  };
  nameLabel.appendChild(name); host.appendChild(nameLabel);
  if (c) {
    const row = document.createElement("label"); row.className = "layer case-enabled";
    const enabled = document.createElement("input"); enabled.id = "case-enabled"; enabled.type = "checkbox"; enabled.checked = current.enabled;
    enabled.onchange = () => { c.enabled = enabled.checked; changed(); buildLoadCaseEditor(); };
    const label = document.createElement("span"); label.textContent = "Include in analysis"; row.append(enabled, label); host.appendChild(row);
  } else { const note = document.createElement("p"); note.className = "case-caption"; note.textContent = "Case 1 · always included in analysis"; host.appendChild(note); }
  for (const [key, label, globalKey, method] of CASE_FIELDS) {
    if (method && method !== (current.method || "analytic")) continue;
    const spec = state.schema.find((item) => item.key === globalKey);
    const row = document.createElement("div"); row.className = "case-field"; row.id = "case-row-" + key;
    const caption = document.createElement("div"); caption.className = "field-label";
    const text = document.createElement("label"); text.textContent = label; text.htmlFor = "case-" + key; caption.appendChild(text);
    if (spec && spec.help) caption.appendChild(helpButton(label, { title: label, paragraphs: [spec.help] }));
    if (c && c[key] === undefined) { const inherited = document.createElement("small"); inherited.className = "case-inherited"; inherited.textContent = "From case 1"; caption.appendChild(inherited); }
    const choices = key === "method" ? ["analytic", "vortex_lattice"] : key === "distribution" ? (spec && spec.choices || ["elliptical", "chord", "uniform"]) : null;
    const boolean = key === "follower_forces" || key === "structure_inertia";
    const input = document.createElement(choices ? "select" : "input"); input.id = "case-" + key; input.setAttribute("aria-label", label);
    if (choices) for (const value of choices) { const option = document.createElement("option"); option.value = value; option.textContent = CHOICE_LABELS[value] || value; input.appendChild(option); }
    else if (boolean) { input.type = "checkbox"; input.checked = !!current[key]; }
    else { input.type = "number"; input.step = "any"; if (["speed","density","fuel_percent"].includes(key)) input.min = "0"; if(key==="fuel_percent")input.max="100"; }
    if (!boolean) input.value = current[key] === undefined ? (key === "method" ? "analytic" : "") : String(current[key]);
    const update = () => {
      const value = boolean ? input.checked : choices || input.value === "" ? input.value : Number(input.value);
      if (c) c[key] = value; else { const base = document.getElementById("p-" + globalKey); if (base) { if (boolean) base.checked = value; else base.value = String(value); } }
      const inherited = caption.querySelector(".case-inherited"); if (inherited) inherited.hidden = true;
      row.classList.remove("invalid"); changed(globalKey);
    };
    if (choices || boolean) input.onchange = () => { update(); if (key === "method") buildLoadCaseEditor(); if (key === "follower_forces") updateFollowerGuidance(); };
    else input.oninput = update;
    row.append(caption, input); host.appendChild(row);
    if (key === "load_factor") {
      const hint = document.createElement("p"); hint.className = "case-method-note"; hint.id = "case-load-multiplier-note";
      hint.textContent = "Default 1.5 converts limit loads to ultimate loads when the prescribed lift or VLM flight condition already represents limit loading. Scales forces and moments; does not derive the aircraft maneuver load factor.";
      input.setAttribute("aria-describedby", hint.id); host.appendChild(hint);
    }
    if(key==="structure_inertia") {
      const hint=document.createElement("p");hint.className="case-method-note";hint.textContent="Apply the same signed acceleration to structural shell/bar mass and fuel. New definitions enable this; older files keep their previous fuel-only loads until you check this option. Structural mass is not multiplied by fuel fill percentage.";host.append(hint);
    }
    if(key==="fuel_percent") {
      const hint=document.createElement("p");hint.className="case-method-note";hint.textContent="Enable the tank in Fuel tank. Each bay fills upward by this percentage and receives a CONM2 mass with its own CG and inertia, supported by a six-DOF RBE3. Different fuel states use separate solver decks.";host.append(hint);
    }
    if(key==="fuel_accel_z") {
      const hint=document.createElement("p");hint.className="case-method-note";hint.textContent="Fuel weight: default (0, 0, −1) g acts downward. The case load multiplier also scales this acceleration (−1.5g with the default multiplier). Set all accelerations to zero for mass and inertia only. Fuel forces remain fixed in global axes, independently of aerodynamic follower forces.";host.append(hint);
    }
    if (key === "follower_forces") {
      row.classList.add("case-follower-field");
      const status = document.createElement("p"); status.id = "case-follower-status"; status.className = "case-setting-status"; status.setAttribute("role", "status"); host.appendChild(status);
      const hint = document.createElement("p"); hint.className = "case-method-note";
      hint.id = "case-follower-help"; input.setAttribute("aria-describedby", "case-follower-status case-follower-help");
      hint.textContent = "SOL106 rotates forces with the RBE3 station. SOL101 uses their first-order small-rotation linearization. Applied moments keep their global directions; VLM is not recalculated during deformation. Used by the native JFEM solver.";
      host.appendChild(hint);
    }
    if (key === "method") {
      const note = document.createElement("p"); note.className = "case-method-note";
      note.textContent = current.method === "vortex_lattice" ? "Computes loads from these flight conditions using the wing camber surface. Set the shared resolution in the VLM tab." : "Distributes the prescribed half-wing lift to the RBE3 centers; no aerodynamic solve is needed.";
      host.appendChild(note);
    }
  }
  const note = document.createElement("p"); note.id = "case-analysis-note"; note.className = "case-workflow"; host.appendChild(note); updateCaseAnalysisNote();
}

// Output naming and solver location do not alter the FE model or its loads.
function affectsModel(key) {
  return !key.startsWith("sensitivity.") && !["output.title", "output.nastran_file", "jfem.repo", "jfem.output_dir",
           "jfem.output_formats", "jfem.timeout_minutes"].includes(key);
}

function readPlanformParams() {
  return readPointEditorParams(WingPlanformView);
}

function readPointEditorParams(editorModule) {
  return readEditorParams(editorModule.PARAM_KEYS);
}

function readEditorParams(keys) {
  const params = {...state.values};
  for (const key of keys) {
    const el = document.getElementById("p-" + key);
    if (!el) continue;
    const spec = state.schema.find(item => item.key === key);
    params[key] = JSON_TABLE_KINDS.has(spec?.kind) ? JSON.parse(el.value || "[]") : spec?.kind === "bool" ? el.checked : spec?.kind === "string" || spec?.kind === "choice" ? el.value : el.value.trim() === "" ? NaN : Number(el.value);
  }
  return params;
}

function refreshSurfaceEditors() {
  if (!state.sparEditor) return;
  state.sparEditor.refresh();
  const data = state.sparEditor.validate();
  state.planformEditor?.setContextError?.(!data.valid && data.error.includes("modeled box") ? data.error : "");
}

function planformPointSignature(value, key = "", params) {
  try {
    const points = typeof value === "string" ? JSON.parse(value) : value || [];
    if (!Array.isArray(points)) return JSON.stringify(points);
    const rows = typeof WingPlanformView !== "undefined" && WingPlanformView.normalizePointRows ?
      WingPlanformView.normalizePointRows(points, key, params || readEditorParams(["box.front_spar_xc", "box.rear_spar_xc"])) : points;
    return JSON.stringify(rows.map(point => key === "box.rear_spar_points" ?
      [point.eta, point.dxc ?? point.xc, point.stringer_angle === undefined ? 0 : point.stringer_angle] :
      [point.eta, point.dxc ?? point.xc]).sort((a, b) => a[0] - b[0]));
  } catch (_) { return typeof value === "string" ? value : JSON.stringify(value); }
}

function currentSupportRibs() {
  if(!state.data?.annotations?.ribs)return [];
  if(state.modelDirty && typeof WingRibLayout!=="undefined") {
    try { const current=readEditorParams(WingRibLayout.PARAM_KEYS),previous=state.data.model_params;
      const ordered=value=>Array.isArray(value)?value.map(ordered):value&&typeof value==="object"?Object.fromEntries(Object.keys(value).sort().map(key=>[key,ordered(value[key])])):value;
      if(WingRibLayout.PARAM_KEYS.some(key=>JSON.stringify(ordered(current[key]))!==JSON.stringify(ordered(previous[key]))))return [];
    } catch(_) { return []; }
  }
  return state.data.annotations.ribs;
}

function formSignature(params) {
  if(state.importedDeck)return WingImportedAnalysis.signature(state.importedDeck);
  return JSON.stringify(state.schema.filter((s) => affectsModel(s.key)).map((s) => {
    if (["materials","shellmaterials","barmaterials"].includes(s.kind)) {
      const rows=params ? params[s.key]||[] : state.materialsEditor?.readDrafts()?.[s.key] ?? JSON.parse(document.getElementById("p-"+s.key).value||"[]");
      const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==="object"?Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])):value;
      return [s.key,canonical([...rows].sort((a,b)=>String(a.component??a.id).localeCompare(String(b.component??b.id))))];
    }
    if(s.kind==="panelproperties"){
      const value=params?params[s.key]||[]:JSON.parse(document.getElementById("p-"+s.key).value||"[]");
      const rows=typeof value==="string"?JSON.parse(value):value;
      const canonical=v=>Array.isArray(v)?v.map(canonical):v&&typeof v==="object"?Object.fromEntries(Object.keys(v).sort().map(key=>[key,canonical(v[key])])):v;
      return[s.key,canonical([...rows].sort((a,b)=>a.key.localeCompare(b.key)))];
    }
    if(["ribproperties","sparproperties"].includes(s.kind)) {
      const draft=Object.assign({},...(state.componentEditors||[]).map(editor=>editor.readDrafts()));
      const rows=params ? params[s.key]||[] : draft[s.key]??JSON.parse(document.getElementById("p-"+s.key).value||"[]");
      const order=s.kind==="ribproperties"?"rib":"bay";
      return[s.key,[...rows].sort((a,b)=>a[order]-b[order]).map(row=>Object.keys(row).sort().map(key=>[key,row[key]]))];
    }
    if(s.kind === "supportsets") {
      const rows=params ? params[s.key] || [] : state.supportEditor?.readDrafts?.()?.[s.key] ?? JSON.parse(document.getElementById("p-"+s.key).value || "[]");
      return[s.key,rows.map(row=>[row.rib,row.target,String(row.dofs)])];
    }
    if(s.kind === "airfoilstations") {
      const rows=params ? params[s.key] || [] : state.airfoilEditor?.readDrafts?.()?.[s.key] ?? JSON.parse(document.getElementById("p-"+s.key).value || "[]");
      const canonical=value=>Array.isArray(value)?value.map(canonical):value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])) : value;
      return[s.key,canonical([...rows].sort((a,b)=>a.eta-b.eta))];
    }
    if (s.kind === "planformpoints") {
      const editor=s.key.startsWith("box.") ? state.sparEditor : state.planformEditor;
      const value=params ? params[s.key] : editor?.readDrafts?.()?.[s.key] ?? document.getElementById("p-"+s.key).value;
      return[s.key,planformPointSignature(value,s.key,params)];
    }
    if (["masterribs","riborientations"].includes(s.kind)) {
      const editor=s.kind==="masterribs" ? state.ribEditor : state.leadingEdgeRibEditor;
      const drafts=!params && editor?.readDrafts?.();
      const value=params ? params[s.key] || [] : drafts?.[s.key] ?? JSON.parse(document.getElementById("p-"+s.key).value || "[]");
      const order=s.kind==="masterribs" ? "eta" : "rib";
      return [s.key,Array.isArray(value) ? [...value].sort((a,b)=>a[order]-b[order]).map(row=>Object.keys(row).sort().map(key=>[key,row[key]])) : value];
    }
    if (s.kind === "loadcases") {
      const cases = params ? params[s.key] || [] : state.loadCases;
      return [s.key, cases.map((raw, index) => {
        const id = Number(raw.id === undefined ? index + 2 : raw.id);
        const row = { ...raw, id, label: String(raw.label === undefined ? "Load case " + id : raw.label).trim(), enabled: raw.enabled === undefined ? true : raw.enabled };
        for (const key of ["lift_total", "load_factor", "torque_y", "speed", "density", "alpha", "fuel_percent", "fuel_accel_x", "fuel_accel_y", "fuel_accel_z"])
          if (row[key] !== undefined) row[key] = Number(row[key]);
        return Object.keys(row).sort().map((key) => [key, row[key]]);
      })];
    }
    if (params) return [s.key, String(s.key === "material.E" ? parameterModelValue(s.key, parameterDisplayValue(s.key, params[s.key])) : params[s.key])];
    const el = document.getElementById("p-" + s.key);
    const value = s.kind === "bool" ? el.checked : el.value.trim();
    const number = (s.kind === "float" || s.kind === "int") && value !== "" ? Number(value) : NaN;
    return [s.key, String(Number.isFinite(number) ? parameterModelValue(s.key, number) : value)];
  }));
}

function syncLeadingEdgeOrientation() {
  const method = document.getElementById("p-leading_edge.rib_orientation");
  const row = document.getElementById("row-leading_edge.rib_angle");
  if (row) row.hidden = !method || method.value !== "front_spar_angle";
  if (!method || !row) return;
  let note = document.getElementById("leading-edge-orientation-note");
  if (!note) { note=document.createElement("p"); note.id="leading-edge-orientation-note"; note.className="pick-note"; row.after(note); }
  note.textContent = method.value === "front_spar_angle" ?
    "Angle in plan view, measured from the root front-spar segment's outboard direction toward the nose. 90° is perpendicular. Rib and bay numbers follow Structure > Ribs. Individual overrides take precedence. A direction that misses the aerodynamic surface falls back to flight direction and is marked red." :
    "Line of flight extends forward from each main rib?s front-spar section. Individual rib overrides take precedence.";
  method.setAttribute("aria-describedby",note.id);
}

// This status describes the entire requested analysis, not just the selected
// case. A partial SOL106 checkpoint remains viewable but never reports green.
function analysisValidity() {
  const invalid = reason => ({current:false,reason});
  if (state.polling || state.solverStarting) return invalid("Analysis is running; waiting for matching completed results.");
  if (state.modelDirty || resultsHavePendingDrafts() || !state.importedDeck&&document.querySelector?.(".planform-input-method.invalid")) return invalid("The model definition has changed or is incomplete. Run JFEM for matching results.");
  if (!state.resultCases?.size) return invalid("No analysis results are available. Run JFEM for this model.");
  if (!state.modelSignature || state.jobSignature !== state.modelSignature) return invalid("Existing results do not match the current model definition. Run JFEM again.");
  const solution = state.importedDeck ? WingImportedAnalysis.solution(state.importedDeck) : document.getElementById("p-output.solution")?.value || state.values["output.solution"] || "101";
  const cases = state.importedDeck ? WingImportedAnalysis.cases(state.importedDeck) :
    String(solution) === "103" && state.resultCases.size<=1 ? [{id:1}] : (state.data?.load_cases?.length ? state.data.load_cases.filter(c => c.enabled !== false) : [{id:1}]);
  for (const c of cases) {
    const record = state.resultCases.get(Number(c.id));
    const variants = String(solution) === "106" && !state.importedDeck ? [record?.variants?.get("sol101"),record?.variants?.get("sol106")] : [record];
    if (variants.some(r => !r || r.available === false || !r.matches || r.signature&&r.signature!==state.modelSignature || (!r.static && !r.modes?.length)))
      return invalid("Matching results are missing for one or more load cases or analyses. Run JFEM again.");
    if (variants.some(r => r.historical))
      return invalid("Historical results retain an earlier aerodynamic model or load application convention. Run JFEM again for the current formulation.");
    if (variants.some(r => /failed|cancelled|canceled|timeout|stopped/i.test(r.status || "") || r.convergence &&
      (r.convergence.partial || r.convergence.converged !== true || r.convergence.full_load !== true)))
      return invalid("An analysis is incomplete or did not converge at full load. Available converged states can still be inspected.");
  }
  return {current:true,reason:"Completed results match the current model and all requested load cases."};
}

function sensitivityResultsAvailable() {
  return Number(state.sensitivityResult?.case_id ?? state.sensitivityResult?.request?.case_id ?? 1)===Number(state.activeCase)&&
    !!state.sensitivityResult?.rows?.some(row=>Number.isFinite(row.derivative)&&!['failed','unavailable','error'].includes(String(row.status||'').toLowerCase()));
}

function physicalResultsAvailable() {
  const usable=result=>!!result&&result.available!==false&&!!(result.static||result.modes?.length||result.contours?.length);
  if(usable(state.results))return true;
  const result=state.resultCases?.get(Number(state.activeCase));
  if(usable(result))return true;
  for(const variant of result?.variants?.values()||[])if(usable(variant))return true;
  return false;
}

function resultsHavePendingDrafts(){return !!state.panelTables?.hasDrafts?.();}

function sensitivityResultValidity() {
  const result=state.sensitivityResult;
  const current=sensitivityResultsAvailable()&&!state.sensitivityBusy&&!state.modelDirty&&!resultsHavePendingDrafts()&&
    (state.importedDeck||!document.querySelector?.(".planform-input-method.invalid"))&&
    state.sensitivityMeta?.signature===state.modelSignature&&state.sensitivityMeta?.compatibility?.is_current===true&&
    (state.sensitivityMeta?.meshIdentity===undefined||state.sensitivityMeta.meshIdentity===state.meshIdentity)&&
    state.sensitivity?.isSetupCurrent?.()!==false&&
    result.status!=="partial"&&result.status!=="baseline_only"&&
    !["failed","cancelled","canceled"].includes(state.sensitivityMeta?.terminalState||result.status)&&
    (!Array.isArray(result.request?.variables)||result.rows.length===result.request.variables.length)&&
    result.rows.every(row=>row.status!=="failed"&&Number.isFinite(row.derivative));
  return {current,reason:current?"Completed sensitivity results match this model."+(result.baseline_analysis?.available?" The original solved baseline is available in FE Results.":""):
    state.sensitivity?.isSetupCurrent?.()===false?"Sensitivity setup changed. Retained values describe the recorded response and properties; the physical FE baseline is still available.":
    sensitivityResultsAvailable()?"Retained sensitivity results belong to an earlier or incomplete analysis. Their table remains available; stale values cannot be mapped onto the current model.":"Run a sensitivity analysis under Loads to enable Sensitivity results."};
}

function refreshSensitivityDisplayButtons() {
  const kind=state.sensitivityMap?.contour?.kind;
  for(const [id,active] of [["sensitivity-field",kind==="sensitivity_field"],["sensitivity-visualize",!!kind&&kind!=="sensitivity_field"],
    ["sensitivity-map-show",!!kind&&(document.getElementById("sensitivity-map-mode")?.value==="field"?kind==="sensitivity_field":kind!=="sensitivity_field")]]) {
    const button=document.getElementById(id);if(!button)continue;
    button.dataset.sensitivityDisplay=active?"active":"ready";
    button.setAttribute("aria-pressed",String(active));
  }
}

function updateAnalysisValidity() {
  if(resultsHavePendingDrafts()&&state.sensitivityMap)clearSensitivityMap();
  const status = analysisValidity(),sensitivity=sensitivityResultValidity();
  const feAvailable=physicalResultsAvailable(),sensitivityAvailable=sensitivityResultsAvailable();
  const anyCurrent=status.current||sensitivity.current;
  const combined={current:anyCurrent,reason:!feAvailable&&!sensitivityAvailable?"No FE or sensitivity results are available for case "+state.activeCase+". Select a solved case or run an analysis.":status.current?status.reason:sensitivity.current?sensitivity.reason:status.reason};
  const selected=state.results;
  const feCurrent=!!selected&&!state.modelDirty&&!resultsHavePendingDrafts()&&selected.matches&&selected.available!==false&&!selected.historical&&
    !/failed|cancelled|canceled|timeout|stopped/i.test(selected.status||"")&&
    (!selected.convergence||selected.convergence.converged===true&&selected.convergence.full_load===true&&!selected.convergence.partial)&&
    (!selected.signature||selected.signature===state.modelSignature)&&!!(selected.static||selected.modes?.length);
  const feStatus={current:status.current||feCurrent,reason:feCurrent?"The selected physical solution matches this model. "+(status.current?status.reason:"Other cases or the requested analysis may still need Run in JFEM."):status.reason};
  for (const id of ["tab-resultsmenu","tab-results","tab-sensitivityresults","btn-jfem"]) {
    const el = document.getElementById(id); if (!el) continue;
    const shown=id==="btn-jfem"?status:id==="tab-sensitivityresults"?sensitivity:id==="tab-results"?feStatus:combined;
    const available=id==="tab-sensitivityresults"?sensitivityAvailable:id==="tab-resultsmenu"?feAvailable||sensitivityAvailable:feAvailable;
    el.setAttribute("data-analysis-current",String(available&&shown.current));
    el.setAttribute("data-analysis-state",!available?"empty":shown.current?"current":"stale");
    el.title = (id === "btn-jfem" ? "Run the selected analysis for every enabled load case. " : "") + (!available?"No "+(id==="tab-sensitivityresults"?"sensitivity ":id==="tab-results"?"FE ":"")+"results are available for case "+state.activeCase+".":shown.reason);
    el.setAttribute("aria-label",(id === "btn-jfem" ? "Run in JFEM" : id==="tab-results"?"FE Results":id==="tab-sensitivityresults"?"Sensitivity results":"Results") + (!available?" — no results available":shown.current ? " — results current" : " — analysis required"));
  }
  const sensitivityTab=document.getElementById("tab-sensitivityresults");
  if(sensitivityTab){sensitivityTab.disabled=!sensitivityResultsAvailable();sensitivityTab.setAttribute("aria-disabled",String(sensitivityTab.disabled));}
  const note = document.getElementById("analysis-validity");
  if (note) { note.textContent = status.reason; note.setAttribute("data-analysis-current",String(status.current));note.setAttribute("data-analysis-state",!feAvailable?"empty":status.current?"current":"stale"); }
  const warning=document.getElementById("fe-results-validity");
  if(warning){
    const stale=!!selected&&(state.modelDirty||resultsHavePendingDrafts()||selected.signature&&selected.signature!==state.modelSignature||!selected.matches||selected.historical);
    warning.hidden=!stale;
    warning.textContent=stale?(selected.historical?"Historical baseline: the saved load convention differs from the current model. ":"The model has changed since this analysis. ")+
      (selected.matches?"Showing the retained solution on its matching mesh; these values are not results for the edited definition.":"Mesh coordinates or connectivity differ. Retained summaries and reports remain available; deformation and contours are disabled."):"";
  }
  const viewportWarning=document.getElementById("stale-results-viewport-warning");
  if(viewportWarning){viewportWarning.hidden=!warning||warning.hidden||!selected?.matches||!!state.sensitivityMap;viewportWarning.textContent=viewportWarning.hidden?"":"Previous analysis — model definition has changed. Results are retained for comparison.";}
  const empty=document.querySelector?.("#panel-results .results-empty");if(empty)empty.hidden=!!selected;
  refreshSensitivityDisplayButtons();
  state.propertyDisplay?.refresh();
  if(state.propertyDisplay?.enabled)updateViewportLegends();
  return status;
}

function setModelDirty(dirty) {
  state.modelDirty = dirty;
  if (dirty && state.sensitivityMap) clearSensitivityMap();
  refreshSensitivityMapCard();
  state.ribEditor?.refresh();
  state.leadingEdgeRibEditor?.refresh();
  state.planView?.refresh();
  state.fuelTankView?.refresh();
  syncLeadingEdgeFallbackNotice();
  updateAnalysisValidity();
  if (typeof refreshWeights === "function") refreshWeights();
  refreshFuelMassProperties();
  refreshLoadPlots();
  state.sensitivity?.refreshContext();
  const btn = document.getElementById("btn-create");
  btn.classList.toggle("stale", dirty);
  btn.title = dirty ? "Parameters changed. Create FEM to rebuild the model." : "Create the finite element model";
  btn.setAttribute("aria-label", dirty ? "Create FEM — parameters changed" : "Create FEM");
}

function syncLeadingEdgeFallbackNotice() {
  const note=document.getElementById("leading-edge-fallback-note");if(!note)return;
  const ribs=(state.data?.leading_edge?.ribs || []).filter(r=>r.fallback);
  note.hidden=!ribs.length;
  note.textContent=ribs.length ? "Displayed FEM: leading-edge rib"+(ribs.length>1?"s ":" ")+ribs.map(r=>r.rib).join(", ")+" use flight direction because the requested direction missed the aerodynamic surface. Marked red in geometry and outlined red in results."+(state.modelDirty?" Recreate FEM to check the edited definition.":"") : "";
  note.title=ribs.map(r=>"Rib "+r.rib+": "+r.reason).join("\n");
}

function parameterEdited(key) {
  if(state.importedDeck && key!=="sensitivity.settings")return;
  if (state.parameterLocks?.guard(key)) return;
  if(key.startsWith("airfoil."))state.airfoilEditor?.refresh?.();
  markStudyModified();
  if (!affectsModel(key)) return;
  const signature = formSignature(), wasDirty = state.modelDirty;
  // Never show paths from the previous generated mesh as the current preview.
  state.modelDirty = !state.data || signature !== state.modelSignature;
  state.panelTables?.refresh();
  if (key === "leading_edge.rib_orientation") syncLeadingEdgeOrientation();
  if (/^(planform|box|ribs|leading_edge)\./.test(key)) {state.ribEditor?.refresh();state.leadingEdgeRibEditor?.refresh();}
  if (key.startsWith("planform.")) state.planformInputs?.refresh();
  if (/^(planform|box)\./.test(key)) refreshSurfaceEditors();
  if (/^(planform|box|ribs|leading_edge)\./.test(key)) state.leadingEdgeGaps?.refresh();
  if (/^(planform|box|ribs|leading_edge)\./.test(key)) state.planView?.refresh();
  if (/^(planform|box|ribs|fuel|leading_edge)\./.test(key)) state.fuelTankView?.refresh();
  if (state.data && signature === state.modelSignature) {
    state.lastEditedSignature = signature;
    state.autoMeshPending = false;
    cancelAutoMeshTimer();
    setModelDirty(false);
    meshStatus(state.polling ? "JFEM is running" : "Model is up to date", state.polling ? "running" : "current");
    return;
  }
  // Number fields emit input while typing and change again on blur. The
  // second event must neither repeat a completed mesh nor reset its debounce.
  if (wasDirty && signature === state.lastEditedSignature) return;
  state.lastEditedSignature = signature;
  setModelDirty(true);
  if (state.results) log("Parameters changed; the previous results are retained and marked out of date.", "warn");
  const airfoilSelection = typeof WingAirfoils !== "undefined" ? WingAirfoils.selectionMessage?.(document) : "";
  if (airfoilSelection) {
    state.autoMeshPending = false; cancelAutoMeshTimer();
    meshStatus(airfoilSelection, "pending");
    const errorPanel = document.getElementById("model-error"); if (errorPanel) errorPanel.hidden = true;
    return;
  }
  requestAutoMesh();
}

const AUTO_MESH_DELAY_MS = 500;

function meshStatus(message, kind = "") {
  const el = document.getElementById("mesh-status");
  if (!el) return;
  el.textContent = message;
  el.title = message;
  el.setAttribute("data-state", kind);
  const errorPanel = document.getElementById("model-error"), errorText = document.getElementById("model-error-text");
  if (errorPanel && errorText) {
    if (["error", "invalid"].includes(kind)) {
      document.getElementById("model-error-title").textContent="Model update failed";errorPanel.dataset.kind="model";
      errorText.textContent = message; errorPanel.hidden = false;
      el.textContent = "Cannot update model · see full error below";
    } else if (["current", "building", "running"].includes(kind)) errorPanel.hidden = true;
  }
}

function showOperationError(title,message) {
  const panel=document.getElementById("model-error");panel.dataset.kind="operation";document.getElementById("model-error-title").textContent=title;
  document.getElementById("model-error-text").textContent=message;panel.hidden=false;
}

function readSurfacePreviewParams(module) {
  const values = readPointEditorParams(module);
  // Keep embedded images and unrelated model state out of live geometry messages.
  const params = Object.fromEntries(module.PARAM_KEYS.map(key => [key, values[key]]));
  for (const [editor, api] of [[state.planformEditor, typeof WingPlanformView !== "undefined" && WingPlanformView], [state.sparEditor, typeof WingSparView !== "undefined" && WingSparView]]) {
    const drafts = editor?.readDrafts();
    if (drafts) for (const key of api.POINT_KEYS) params[key] = drafts[key];
  }
  for (const [editor,key] of [[state.ribEditor,"ribs.masters"],[state.leadingEdgeRibEditor,"leading_edge.rib_orientations"]]) {
    const drafts=editor?.readDrafts(); if(drafts && module.PARAM_KEYS.includes(key)) params[key]=drafts[key];
  }
  params._rib_geometry=state.modelDirty ? null : state.data?.rib_layout || null;
  return params;
}

function installDimensionedPlanView() {
  if (typeof WingPlanViewWindow === "undefined") return;
  if (!state.planView) state.planView = WingPlanViewWindow.connect({
    readValues: () => state.importedDeck ? {_unavailable:"The current Study is an imported Nastran deck. Its original GRID coordinates are shown in the 3D viewport; a generated-wing planform does not apply."} : readSurfacePreviewParams(WingDimensionedPlanView),
    onChange() { state.values["view.plan_view"] = JSON.stringify(state.planView.capture()); markStudyViewModified(); },
    onError(message) { meshStatus(message, "error"); },
  });
  state.planView.refresh();
}

function installPropertyDisplay(){
  if(state.propertyDisplay||typeof WingPropertyDisplay==="undefined")return;
  state.propertyDisplay=WingPropertyDisplay.create(document.getElementById("property-display-controls"),{
    data:()=>state.data,stale:()=>state.modelDirty||resultsHavePendingDrafts(),
    onChange:settings=>{
      if(settings.enabled){if(state.panelView)setPanelDisplay(false,false);clearSensitivityMap();activateWorkspaceTab("displayproperties");}
      applyContour();updateAnalysisValidity();markStudyViewModified();
    }
  });
}

function installPanelTables(){
  if(typeof WingPanelTables==='undefined')return;
  if(!state.panelTables)state.panelTables=WingPanelTables.connect({
    readSnapshot:()=>({parameters:collectParams(),panels:state.data?.stiffened_panels?.panels||[],
      layout_token:state.data?.stiffened_panels?.layout_token,modelDirty:state.modelDirty,
      busy:state.workspaceBusy||state.loadingInput,updating:state.meshRequestInFlight}),
    onEdit:(key,rows)=>{const input=document.getElementById('p-'+key);if(!input)throw Error('Restart WingFEGen and refresh to load the panel-property schema.');input.value=JSON.stringify(rows);parameterEdited(key);},
    onDraftChange:pending=>{
      if(pending){markStudyModified();cancelAutoMeshTimer();}
      else if(state.autoMeshPending){state.autoMeshDueAt=performance.now()+AUTO_MESH_DELAY_MS;scheduleAutoMesh();}
      updateAnalysisValidity();state.sensitivity?.refreshContext();updateFileStatus();
    },
    onError:message=>log('Panel table: '+message,'warn'),
  });
  state.panelTables.installButtons(document);
}

function restorePlanViewMetadata(value) {
  const saved = typeof value === "string" ? (value.trim() ? JSON.parse(value) : undefined) : value;
  state.planView?.restore(saved);
}

function restoreDrawingsMetadata(value){
  if(typeof WingSVGViewport!=="undefined")WingSVGViewport.restoreAll(typeof value==="string"?(value.trim()?JSON.parse(value):{}):value||{});
}

function cancelAutoMeshTimer() {
  if (state.autoMeshTimer !== null) clearTimeout(state.autoMeshTimer);
  state.autoMeshTimer = null;
}

function requestAutoMesh(delay = AUTO_MESH_DELAY_MS) {
  state.autoMeshPending = true;
  state.autoMeshDueAt = performance.now() + delay;
  scheduleAutoMesh();
}

// One request owns the model at a time. Changes during a request remain
// pending; unlocking schedules only the latest form state after its debounce.
function scheduleAutoMesh() {
  if(state.importedDeck)return;
  cancelAutoMeshTimer();
  if (!state.autoMeshPending || !state.autoMeshReady) return;
  if (!state.autoMeshEnabled) {
    meshStatus("Model changed · press Create FEM", "stale");
    return;
  }
  if (state.panelTables?.hasDrafts()) {
    meshStatus("Finish the panel table edits to update the mesh", "pending");
    return;
  }
  if (state.polling || state.solverStarting || state.sensitivityBusy) {
    meshStatus("Model update queued until JFEM finishes", "pending");
    return;
  }
  if (state.busy || state.exportBusy || state.loadingInput || state.meshRequestInFlight) {
    meshStatus("Model update queued", "pending");
    return;
  }
  meshStatus("Model update scheduled…", "pending");
  const delay = Math.max(0, state.autoMeshDueAt - performance.now());
  state.autoMeshTimer = setTimeout(() => {
    state.autoMeshTimer = null;
    if (!state.autoMeshPending || !state.autoMeshEnabled) return;
    if (state.busy || state.exportBusy || state.loadingInput || state.meshRequestInFlight || state.polling || state.solverStarting || state.sensitivityBusy || state.panelTables?.hasDrafts()) {
      scheduleAutoMesh();
      return;
    }
    createFEM({ automatic: true });
  }, delay);
}

function autoMeshChanged() {
  state.autoMeshEnabled = document.getElementById("auto-mesh").checked;
  syncManualMeshAction();
  cancelAutoMeshTimer();
  if (state.autoMeshEnabled && (state.modelDirty || !state.data)) requestAutoMesh(0);
  else if (!state.autoMeshEnabled && state.modelDirty) meshStatus("Model changed · press Create FEM", "stale");
  else meshStatus(state.data ? "Model is up to date" : "Press Create FEM", "current");
}

function syncManualMeshAction() {
  const enabled=document.getElementById("auto-mesh")?.checked !== false;
  const button=document.getElementById("btn-create"),slot=document.getElementById("manual-mesh-action"),home=document.getElementById("mesh-create-slot");
  const destination=enabled?home:slot;
  if(slot)slot.hidden=enabled;
  if(button && destination?.appendChild && button.parentElement!==destination)destination.appendChild(button);
}

function collectParams({includeView = false} = {}) {
  if(state.importedDeck)return {model_kind:'nastran',imported_deck:{token:state.importedDeck.token,signature:state.importedDeck.signature,analysis:WingImportedAnalysis.options(state.importedDeck.source?.analysis)}};
  if(state.data?.imported_deck)throw Error('Imported deck identity is unavailable. Read the deck or reopen its Study; a generated wing will not be substituted.');
  state.panelTables?.assertValidDraft?.();
  state.parameterLocks?.enforce();
  state.planformInputs?.assertValidDraft();
  state.airfoilEditor?.assertValidDraft?.();
  state.supportEditor?.assertValidDraft?.();
  state.materialsEditor?.assertValidDraft?.();
  for(const editor of state.componentEditors||[])editor.assertValidDraft();
  const airfoilSelection = typeof WingAirfoils !== "undefined" ? WingAirfoils.selectionMessage?.(document) : "";
  if (airfoilSelection) throw new Error(airfoilSelection);
  state.planformEditor?.assertValidDraft?.();
  state.sparEditor?.assertValidDraft?.();
  state.leadingEdgeGaps?.assertValidDraft?.();
  state.ribEditor?.assertValidDraft?.();
  state.leadingEdgeRibEditor?.assertValidDraft?.();
  const out = {};
  const bad = [];
  for (const spec of state.schema) {
    if (spec.key === "sensitivity.settings") {out[spec.key]=state.sensitivity?.serialize() || state.values[spec.key] || "";continue;}
    if (spec.kind === "loadcases") {
      for (const c of state.loadCases) {
        if (!String(c.label === undefined ? "Load case " + c.id : c.label).trim()) bad.push("case " + c.id + " name");
        for (const [field, label] of CASE_FIELDS) {
          if (field === "method" || field === "distribution" || c[field] === undefined) continue;
          if (["follower_forces","structure_inertia"].includes(field) ? typeof c[field] !== "boolean" : c[field] === "" || !Number.isFinite(Number(c[field]))) {
            bad.push("case " + c.id + " " + label);
            if (Number(state.editingCase) === Number(c.id)) {
              const row = document.getElementById("case-row-" + field); if (row) row.classList.add("invalid");
            }
          }
        }
      }
      out[spec.key] = JSON.parse(JSON.stringify(state.loadCases)); continue;
    }
    const el = document.getElementById("p-" + spec.key);
    const row = document.getElementById("row-" + spec.key);
    if (!el) continue;
    row.classList.remove("invalid");
    let v;
    if (JSON_TABLE_KINDS.has(spec.kind)) {
      try { v = JSON.parse(el.value || "[]"); if (!Array.isArray(v)) throw new Error(); }
      catch (_) { throw new Error(spec.label + ": expected a table of parameter rows."); }
    } else if (spec.kind === "bool") {
      v = el.checked;
    } else if (spec.kind === "int" || spec.kind === "float") {
      const text = el.value.trim();
      v = Number(text);
      if (text === "" || !Number.isFinite(v) || (spec.kind === "int" && !Number.isInteger(v))) {
        row.classList.add("invalid");
        if (Number(state.editingCase) === 1) {
          const field = CASE_FIELDS.find((item) => item[2] === spec.key);
          if (field) { const visibleRow = document.getElementById("case-row-" + field[0]); if (visibleRow) visibleRow.classList.add("invalid"); }
        }
        bad.push(spec.label);
        continue;
      }
    } else {
      v = el.value.trim();
      const airfoilField = /^airfoil\.(root|tip)(_profile)?$/.exec(spec.key);
      const airfoilSource = airfoilField && document.getElementById("p-airfoil." + airfoilField[1] + "_source")?.value;
      const inactiveAirfoilField = airfoilField && (airfoilField[2] ? airfoilSource === "naca" : airfoilSource === "uiuc");
      if (v === "" && !["jfem.repo", "leading_edge.disabled_bays", "fuel.disabled_bays"].includes(spec.key) && !inactiveAirfoilField) {
        row.classList.add("invalid");
        bad.push(spec.label);
        continue;
      }
    }
    out[spec.key] = (spec.kind === "float" || spec.kind === "int") ? parameterModelValue(spec.key, v) : v;
  }
  if (bad.length) {
    throw new Error("these fields need a value: " + bad.join(", "));
  }
  if (typeof WingPlanformView !== "undefined" && state.schema.some(spec => WingPlanformView.POINT_KEYS?.includes(spec.key))) {
    const planform = WingPlanformView.derive(out);
    if (!planform.valid) throw new Error("Planform: " + planform.error);
  }
  if (typeof WingSparView !== "undefined" && state.schema.some(spec => WingSparView.POINT_KEYS.includes(spec.key))) {
    const spars = WingSparView.derive(out);
    if (!spars.valid) throw new Error("Spars: " + spars.error);
  }
  out["references.items"] = state.reference ? state.reference.serialize() : state.values["references.items"] || [];
  if(includeView)out["view.drawings"]=typeof WingSVGViewport!=="undefined"?JSON.stringify(WingSVGViewport.captureAll()):state.values["view.drawings"]||"";
  if (includeView) out["view.plan_view"] = state.planView ? JSON.stringify(state.planView.capture()) : state.values["view.plan_view"] || "";
  return out;
}

/* --- server calls -------------------------------------------------------- */

const activity = () => globalThis.WingActivity;
const paintActivity = () => activity()?.yieldFrame() || Promise.resolve();
async function decodePayload(buffer) {
  await paintActivity();
  const expand=data=>data?.imported_buffers&&typeof WingImportedRender!=="undefined"?WingImportedRender.expand(data):data;
  if (typeof Worker === "undefined" || buffer.byteLength < 1024 * 1024)
    return expand(MessagePack.decode(new Uint8Array(buffer)));
  const worker = new Worker("decode-worker.js");
  try {
    return await new Promise((resolve, reject) => {
      worker.onmessage = ({data}) => {try{data.error ? reject(new Error(data.error)) : resolve(expand(data.data));}catch(error){reject(error);}};
      worker.onerror = event => reject(new Error(event.message || "Payload decoder failed"));
      worker.postMessage(buffer, [buffer]);
    });
  } finally { worker.terminate(); }
}

async function buildModelResponsive(data, options = {}, token) {
  if (!activity()) return buildModel(data, options);
  const started=performance.now();let painted=started,lastLogged="",groupCount=0;
  const body = document.getElementById("workspace-body"), wasInert = body?.inert;
  const wasBuilding=state.buildingScene;
  if (body) body.inert = true;
  state.buildingScene = true;
  try {
    for (const detail of buildModelSteps(data, options)) {
      const group=detail.startsWith("Drawing ")&&!detail.includes("fuel tank"),elapsed=performance.now()-painted;
      if(group)groupCount++;
      // Buffer/property batches are prepared off screen. Updating and painting
      // the progress DOM for every small property group needlessly slows large
      // imported decks; only publish progress at the responsive frame boundary.
      if(!group||elapsed>=12)activity().update(token, {detail:group?"Preparing geometry batch "+groupCount+" · "+data.groups.length+" property groups retained. The complete model will appear together.":detail});
      const concise=detail.replace(/ p\d+/g,"");
      if(!detail.startsWith("Drawing ")&&concise!==lastLogged){log("Viewport +"+((performance.now()-started)/1000).toFixed(2)+" s: "+concise);lastLogged=concise;}
      if(elapsed>=12){await paintActivity();painted=performance.now();}
    }
  } finally { state.buildingScene = wasBuilding; if (body) body.inert = wasInert; }
  state.lastViewportBuild={milliseconds:performance.now()-started,groups:data.groups.length,nodes:data.nodes.count,atomic:true};
  log("Viewport ready in "+((performance.now()-started)/1000).toFixed(2)+" s.","good");
  logModelDetails(data);
}

function logModelDetails(data){
  const groups=data.groups||[],count=kind=>groups.filter(g=>kind.includes(g.kind)).reduce((n,g)=>n+g.count,0);
  if(data.imported_deck){
    log("Imported FEM: "+count(["quad","tria"])+" displayed shells, "+count(["bar"])+" displayed bars, "+(data.rbe3?.count||0)+" source RBE3s. Original deck cards and case control remain authoritative.");
    for(const item of data.load_cases||[]){
      const spc=item.spc,loads=item.loads;
      log("Native subcase "+item.id+" · "+item.label+"; SPC "+(spc?.selected_spc_id??item.case_control?.SPC??"none")+
        ": "+(spc?.count??"unknown")+" GRID nodes / "+(spc?.constrained_dofs??"unknown")+" constrained DOFs; "+
        (loads?.force_stations?.length||0)+" force and "+(loads?.moment_stations?.length||0)+" moment application nodes.");
      for(const warning of [...(item.warnings||[]),...(spc?.warnings||[])])log("Subcase "+item.id+": "+warning,"warn");
    }
    for(const card of data.imported_deck.unprocessed_cards||[])log("Source card "+card.name+" ("+card.count+"): "+(card.message||card.status)+". The original card is retained in the deck.","warn");
    return;
  }
  log("FEM: "+count(["quad","tria"])+" shells, "+count(["bar"])+" bars; "+(data.rbe3?.count||0)+" rib-plane aerodynamic RBE3s and "+(data.fuel_rbe3?.count||0)+" mid-bay mass RBE3s.");
  const panels=data.stiffened_panels;
  if(panels)log("Stiffened panels: "+(panels.panels?.length||0)+"; each owns shell and normal-stringer properties. Runout bars retain their fixed properties.");
  for(const item of data.load_cases||[]){
    log("Load case "+item.id+" · "+item.label+": "+(item.loads?.method||"defined loads")+"; fuel "+eng(item.fuel?.mass_kg??0,4)+" kg.");
    for(const line of item.loads?.routing_diagnostics?.log_lines||[])log("Case "+item.id+": "+line);
  }
  for(const check of data.checks||[])if(check.ok===false||check[2]===false)log("Mesh check: "+JSON.stringify(check),"warn");
}

async function loadInput(options={}) {
  if (state.workspaceBusy || state.exportBusy || state.loadingInput || state.meshRequestInFlight || state.polling || state.solverStarting || state.sensitivityBusy) return false;
  state.loadingInput = true;
  const token = activity()?.begin("Reading model definition", {detail:"The first request may compile Julia code. Please wait…"});
  cancelAutoMeshTimer();
  setBusy(state.busy);
  try {
  const res = await fetch("/api/input", { cache: "no-store" });
  const data = await res.json();
  if (!data.ok) throw new Error(data.error || "could not read the input file");
  state.schema = data.schema;
  state.defaults = data.defaults || state.defaults;
  state.values = data.values;
  state.inputFile = data.input_file;
  state.studyFile = null; state.studyFileHandle = null; state.tomlFile = fileBasename(data.input_file); updateFileStatus();
  document.getElementById("input-file").textContent =
    data.input_file + "   [" + data.units + "]";
  buildForm(data.schema, data.values);
  restorePlanViewMetadata(data.values["view.plan_view"]);
  restoreDrawingsMetadata(data.values["view.drawings"]);
  if (!options.deferReferences && state.reference && state.reference.restore) await state.reference.restore(data.values["references.items"] || []);
  for (const note of data.values.section_migration_notes || []) log(note, "warn");
  state.autoMeshReady = !options.deferModel;
  state.autoMeshPending = false;
  if (!state.data || formSignature() !== state.modelSignature) {
    parameterEdited("reload");
    if(!options.deferModel)requestAutoMesh(0);
  } else {
    setModelDirty(false);
    meshStatus("Model is up to date", "current");
  }
  log("input file loaded, " + data.schema.length + " parameters", "good");
  return true;
  } finally {
    state.loadingInput = false;
    activity()?.end(token);
    setBusy(state.busy);
  }
}

async function postParams(url, params, token) {
  const id = token ? Date.now().toString(36) + "-" + Math.random().toString(36).slice(2) : null;
  let timer, stopped = false, controller,lastSequence=0;
  const operation=url.split("/").at(-1).replaceAll("_"," ");
  function reportActivity(data){
    if(data.stage)activity()?.update(token,{detail:data.stage});
    for(const event of data.events||[])if(event.sequence>lastSequence){
      log(operation+" +"+Number(event.elapsed_seconds).toFixed(2)+" s: "+event.stage);lastSequence=event.sequence;
    }
  }
  async function poll() {
    if (stopped) return;
    controller = new AbortController();
    try {
      const response = await fetch("/api/activity?id=" + id, {cache:"no-store", signal:controller.signal});
      if (response.ok) {
        const data = await response.json();
        if (!stopped)reportActivity(data);
      }
    } catch (_) { /* elapsed clock still works with an older/busy server */ }
    finally { if (!stopped) timer = setTimeout(poll, 500); }
  }
  if (id) timer = setTimeout(poll, 500);
  try {
    const response=await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...(id ? {"X-Wing-Activity":id} : {}) },
      body: JSON.stringify(params),
    });
    stopped=true;clearTimeout(timer);controller?.abort();
    // A CPU-heavy stage may finish between polls. Fetch its bounded history so
    // the Log still documents every stage, including quick operations.
    if(id)try{const final=await fetch("/api/activity?id="+id,{cache:"no-store",signal:AbortSignal.timeout(2500)});if(final.ok)reportActivity(await final.json());}catch{}
    return response;
  } finally { stopped = true; clearTimeout(timer); controller?.abort(); }
}

async function readError(res) {
  try {
    const j = await res.json();
    return j.error || ("HTTP " + res.status);
  } catch (e) {
    return "HTTP " + res.status;
  }
}

function setBusy(on) {
  state.busy = on;
  updateAnalysisValidity();
  const disabled = on || state.sensitivityBusy || state.workspaceBusy || state.exportBusy || state.polling || state.solverStarting || state.loadingInput || state.meshRequestInFlight;
  for (const id of ["btn-create", "btn-nastran", "btn-save", "btn-reload",
                    "btn-jfem", "btn-save-model", "btn-save-model-as", "btn-load-model", "btn-save-toml", "btn-load-toml", "btn-view-toml", "btn-new-study", "btn-read-nastran"]) {
    const button = document.getElementById(id); if (button) button.disabled = disabled;
  }
  syncManualMeshAction();
  state.sensitivity?.refreshContext();
  state.panelTables?.refresh();
  syncImportedModelMode(disabled);
  if (!disabled) scheduleAutoMesh();
}

async function createFEM(options = {}) {
  if(state.importedDeck)return !!state.data;
  const automatic = options.automatic === true;
  if (state.workspaceBusy || state.exportBusy || state.busy || state.loadingInput || state.meshRequestInFlight || state.polling || state.sensitivityBusy ||
      (state.solverStarting && !options.forSolver)) return false;
  cancelAutoMeshTimer();
  state.autoMeshPending = false;
  let params;
  try {
    params = collectParams();
  } catch (e) {
    meshStatus("Waiting for valid input: " + e.message, "invalid");
    if (!automatic) log(e.message, "err");
    return false;
  }
  state.meshRequestInFlight = true;
  setBusy(true);
  const signature = formSignature(params);
  log("generating the mesh…");
  meshStatus(automatic ? "Updating model…" : "Creating FEM…", "building");
  const t0 = performance.now();
  const token = activity()?.begin("Creating FEM", {detail:"Building mesh, fuel report and load cases…"});
  try {
    const res = await postParams("/api/generate", params, token);
    if (!res.ok) {
      const error = await readError(res);
      if (formSignature() === signature) {
        meshStatus("Cannot update model: " + error, "invalid");
        log("generation failed: " + error, "err");
      }
      return false;
    }
    const buf = await res.arrayBuffer();
    const byteLength = buf.byteLength;
    activity()?.update(token, {detail:"Decoding mesh data…"});
    const data = await decodePayload(buf);
    const dt = (performance.now() - t0) / 1000;
    if (formSignature() !== signature) {
      const stale = formSignature() !== state.modelSignature;
      setModelDirty(stale);
      if (stale && !state.autoMeshPending) requestAutoMesh(0);
      if (!stale) meshStatus("Model is up to date", "current");
      if (!automatic) log("Newer parameter edits are queued; the previous mesh is still displayed.", "warn");
      return false;
    }
    state.values = params;
    state.data = data;
    await buildModelResponsive(data, { preserveView: automatic || options.preserveView === true }, token);
    state.modelSignature = signature;
    // A pending profile/reference callback can edit inputs while the scene yields,
    // even though the form is inert. Never erase the queued newer definition.
    if (formSignature() !== signature) {
      setModelDirty(true);
      requestAutoMesh(0);
      meshStatus("Newer parameter edits queued; displayed mesh needs updating", "stale");
      return false;
    }
    setModelDirty(false);
    state.autoMeshPending = false;
    meshStatus("Model is up to date", "current");
    showStats(data, byteLength, (performance.now() - t0) / 1000);
    log("mesh received: " + data.nodes.count + " nodes, " +
        totalElements(data) + " elements, " +
        (byteLength / 1024).toFixed(1) + " kB of MsgPack in " +
        dt.toFixed(2) + " s", "good");
    if (data.checks_pass) {
      log("all congruency checks passed", "good");
    } else {
      log("CONGRUENCY CHECKS FAILED, see the model panel", "err");
    }
    for(const rib of data.leading_edge?.ribs || []) if(rib.fallback) log("Leading-edge rib "+rib.rib+": "+rib.reason,"warn");
    return true;
  } catch (e) {
    if (formSignature() === signature) {
      meshStatus("Cannot update model: " + e.message, "invalid");
      log("generation failed: " + e.message, "err");
      console.error(e);
    }
    return false;
  } finally {
    activity()?.end(token);
    state.meshRequestInFlight = false;
    setBusy(false);
  }
}

async function writeNastran() {
  if (state.busy) return;
  let params;
  try {
    params = collectParams();
  } catch (e) {
    log(e.message, "err");
    return;
  }
  setBusy(true);
  const token = activity()?.begin("Writing NASTRAN deck");
  log("writing the NASTRAN deck…");
  try {
    const res = await postParams("/api/nastran", params, token);
    if (!res.ok) {
      log("write failed: " + (await readError(res)), "err");
      return;
    }
    const j = await res.json();
    showDeck(j.deck_text, j.path, j.deck_metadata);
    if(j.note)log(j.note,"warn");
    for(const file of j.files||[])log("Case "+file.case_id+" · "+file.label+" · fuel "+eng(file.fuel_percent)+"%: "+file.path,"good");
    log("wrote " + j.path, "good");
    log("  " + j.solution + ", " + j.lines + " lines, " +
        (j.bytes / 1024).toFixed(1) + " kB");
    if (!j.checks_pass) log("  note: congruency checks did not pass", "warn");
  } catch (e) {
    log("write failed: " + e.message, "err");
  } finally {
    activity()?.end(token);
    setBusy(false);
  }
}

async function saveInput() {
  if (!workspaceOperationAvailable()) return;
  let params;
  try {
    params = collectParams({includeView:true});
  } catch (e) {
    log(e.message, "err");
    return;
  }
  setBusy(true);
  const token = activity()?.begin("Saving input definition");
  try {
    const res = await postParams("/api/save_input", params);
    if (!res.ok) {
      log("save failed: " + (await readError(res)), "err");
      return;
    }
    const j = await res.json();
    if (state.reference && state.reference.markSaved) state.reference.markSaved(params["references.items"]);
    state.tomlFile=fileBasename(j.path);state.lastFileSave={method:"server",name:j.path};updateFileStatus();
    log("input file saved to " + j.path, "good");
  } catch (e) {
    log("save failed: " + e.message, "err");
  } finally {
    activity()?.end(token);
    setBusy(false);
  }
}

async function reloadInput() {
  return loadModelDefinition({name:fileBasename(state.inputFile)},{serverInput:true});
}

/* Geometry exports snapshot the created model, independent of current edits. */
function exportFECoordinates(view) {
  if (!view) return null;
  const out = new Float32Array(view.length);
  for (let i = 0; i < view.length; i += 3) { out[i] = view[i + 2]; out[i + 1] = view[i]; out[i + 2] = view[i + 1]; }
  return out;
}

async function saveViewportSVG(){
  if(!state.data)throw Error("Create the model before saving its view.");
  return workspaceOperation(async token=>{
    state.svgExportSnapshot=true;
    try{
      const collapsed=WingLegends.capture().collapsed;
      const legends=WingLegends.entries(document.getElementById("viewport-legends")).filter(entry=>!collapsed["viewport-legends:"+entry.kind]).map(entry=>{
        const scope=entry.paletteKey||entry.kind,stops=selectedColorScale(scope).map(([offset,color])=>({offset,color:"#"+color.map(v=>Math.round(255*v).toString(16).padStart(2,"0")).join("")}));
        const constantColor="#"+cmap(.5,scope).map(value=>Math.round(255*value).toString(16).padStart(2,"0")).join("");
        return{title:entry.title,units:entry.unit,min:entry.min,max:entry.max,stops:entry.max>entry.min?stops:[{offset:0,color:constantColor},{offset:1,color:constantColor}],subtitle:entry.caseLabel,
          ...(entry.categories?{categories:entry.categories}: {})};
      });
      const result=await WingViewportSVG.exportScene(state.scene,state.camera,state.engine,{title:state.data.title||"WingFEGen viewport",legends,
        onProgress:(fraction,message)=>activity()?.update(token,{detail:Math.round(100*fraction)+"% · "+message})});
      const name=WingWorkspace.filename(state.values["output.title"]).replace(/\.wingfem\.json$/,"-view.svg");
      WingWorkspace.downloadText(result.text,name,"image/svg+xml",document);
      log("Saved viewport projection: "+name+". Flat-color vectors; metallic reflections and textures are simplified.","good");
      for(const warning of result.warnings||[])log("SVG: "+warning,"warn");
      return result;
    }finally{state.svgExportSnapshot=false;}
  },"Saving viewport SVG");
}

async function exportGeometry(format) {
  if (state.exportBusy) return false;
  const status = document.getElementById("export-status");
  if (!state.data || typeof WingGeometryExport === "undefined") {
    if (status) status.textContent = "Create a model before exporting geometry.";
    return false;
  }
  const displayed = document.getElementById("export-state").value === "displayed";
  const radiusText = document.getElementById("export-line-radius").value.trim(), radius = radiusText ? Number(radiusText) : state.diag * .0003;
  if (!(radius > 0 && Number.isFinite(radius))) { status.textContent = "Line radius must be a positive number in metres."; return false; }
  state.exportBusy = true;
  setBusy(state.busy);
  const buttons = ["export-stl", "export-glb"].map(id => document.getElementById(id)); buttons.forEach(button => button.disabled = true);
  const token = window.WingActivity?.begin("Export " + format.toUpperCase(), { detail: "Preparing geometry", blocking: false });
  const progress = (fraction, text) => {
    const detail = Math.round(100 * fraction) + "% · " + text;
    status.textContent = detail;
    if (token) window.WingActivity?.update(token, { detail });
  };
  try {
    const data = state.data, shape = activeShape(), options = {
      scope: document.getElementById("export-scope").value, displayed,
      references: document.getElementById("export-references").checked, lineRadius: radius,
    };
    const snapshot = {
      data, diag: state.diag, nodeRadius: nodeRadius(), markerRadius: markerRadius(), activeCase: state.activeCase,
      visibility: Object.fromEntries(Array.from(state.layers, ([name, layer]) => [name, layer.visible && layer.meshes.some(mesh => mesh.isEnabled())])),
      colors: Object.fromEntries((data.groups||[]).map(g => [g.name,(GROUP_STYLE[g.base_group||g.name]||{color:"#9aa6b2"}).color])),
      positions: displayed ? exportFECoordinates(currentPositions()) : null,
      rotations: displayed && shape?.rotation ? exportFECoordinates(shape.rotation) : null,
      rotationScale: displayed ? amplitude() * (animating() ? Math.sin(state.phase) : 1) : 0,
      aeroPositions: displayed ? exportFECoordinates(state.deformable.find(item => item.aero)?.buf) : null,
      analysis: resultAnalysisLabel(state.results),
      appliedLoadStations: displayed ? appliedResultLoads()?.stations : null,
      vlmForceMultiplier: Number(document.getElementById("vlm-force-scale").value) || 1,
      supportForceMultiplier: Number(document.getElementById("support-force-scale").value) || 1,
      reactions: state.activeMode < 0 && state.results?.matches && state.results.available !== false && state.results.reactions ? {
        nodes: state.results.reactions.nodes.slice(), forces: state.results.reactions.forces.slice(), moments:state.results.reactions.moments?.slice(),
      } : null,
      deformation: displayed ? { analysis: resultAnalysisLabel(state.results), case_id: state.activeCase, load_scale: state.results?.loadScale ?? 1, mode: state.activeMode >= 0 ? state.activeMode + 1 : null, scale: amplitude(), phase: animating() ? Math.sin(state.phase) : 1, active_shape: !!shape } : null,
    };
    const stale = state.modelDirty;
    if (window.WingActivity?.yieldFrame) await window.WingActivity.yieldFrame();
    snapshot.references = options.references ? await WingGeometryExport.referenceSnapshot(state.reference?.entries, options.scope === "visible", progress) : [];
    const geometry = await WingGeometryExport.collect(snapshot, options, progress);
    const blob = await WingGeometryExport[format](geometry, progress);
    const name = String(data.title || "wing-model").replace(/[^A-Za-z0-9_.-]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 100) || "wing-model";
    const filename = name + (displayed ? "_displayed" : "") + "." + format;
    const url = URL.createObjectURL(blob), link = document.createElement("a"); link.href = url; link.download = filename;
    document.body.appendChild(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 30000);
    const triangles = geometry.parts.reduce((n, part) => n + part.positions.length / 9, 0);
    status.textContent = "Downloaded " + filename + " · " + triangles.toLocaleString() + " triangles · " + (blob.size / 1048576).toFixed(2) + " MB." +
      (stale ? " Exported the last created model; current parameter edits are not included." : "");
    log(status.textContent, "good");
    if (token) window.WingActivity?.end(token, { message: "Geometry export complete" });
    return { geometry, blob, filename };
  } catch (error) {
    status.textContent = "Export failed: " + error.message; log(status.textContent, "err");
    if (token) window.WingActivity?.end(token, { error: true, message: status.textContent });
    return false;
  } finally { state.exportBusy = false; buttons.forEach(button => button.disabled = false); setBusy(state.busy); }
}

function geometryExportHelp() {
  openHelp({ title: "Geometry export", paragraphs: [
    "All model entities exports every generated shell, full beam section, structural GRID, support marker, RBE3 spider and reference node, aerodynamic loft, fuel envelope and each load case's VLM panels, panel-force arrows and applied force/moment glyphs. Available support reactions for the selected static solution are included. Hidden layers are included. Imported reference geometry is included unless you clear its checkbox.",
    "Visible layers exports the enabled model layers and the selected load case. Beams always use their physical section dimensions and orientation, even when the viewport uses lines. Undeformed is the default; Displayed deformation captures the selected solution, magnification and current animation phase. Fuel and VLM remain at their original geometry, as in the viewer.",
    "STL stores triangulated surfaces in FE global XYZ and metres. Shell thickness is not extruded. Spiders and force/moment glyphs become small tubes using Line radius; nodes and supports use the display marker sizes, with Line radius as their minimum. STL has no colors or IDs and the combined model is not a watertight manufacturing solid.",
    "GLB keeps component colors, separate groups, properties and triangle-to-element/GRID IDs in glTF extras. FE XYZ mesh coordinates are stored in metres; a proper root rotation supplies standard glTF Y-up placement without mirroring. Reference transforms are included. Labels, local-axis helpers, duplicate wireframes, selection halos and comparison ghosts are excluded. Result colors are not exported.",
    "Exports use the last created model. If parameters are waiting for a rebuild, the download status says so. Geometry export does not modify inputs or run the solver."
  ] });
}

/* Study/TOML files are separate from the explicitly overwritten server input. */
function fileBasename(path) { return String(path || "").split(/[\\/]/).pop(); }
function markStudyModified() {
  if (state.loadingInput || state.studyRestoring) return;
  state.studyRevision++;
  if (state.studyDirty) return;
  state.studyDirty = true; updateFileStatus();
}
// View preferences are included when a Study is explicitly saved, but only
// definition edits (geometry, properties, loads, notes, etc.) dirty its indicator.
function markStudyViewModified() {
  if (state.loadingInput || state.studyRestoring) return;
  state.studyViewRevision++;
}
function markStudySaved(revision = state.studyRevision) {
  state.studyDirty = revision !== state.studyRevision || !!state.panelTables?.hasDrafts?.(); updateFileStatus();
}
function updateFileStatus() {
  const status=document.getElementById("study-file-status"),saved=document.getElementById("file-save-status"),server=document.getElementById("server-input-path");
  const saveButton=document.getElementById("btn-save-model");
  if (saveButton) {
    const dirty=state.studyDirty || !!state.panelTables?.hasDrafts?.();
    saveButton.dataset.saved=String(!dirty);
    saveButton.title=(dirty ? "Unsaved definition changes. " : "Study definition saved. ")+(state.studyFileHandle ? "Save to "+state.studyFile+". Use Save Study as… to choose another file." : "Choose a filename and folder for this Study. Without file-picker support, the browser downloads it.")+" Camera and display changes do not change this indicator; saving still includes their current settings.";
    saveButton.setAttribute("aria-description",dirty ? "Unsaved changes" : "Study saved");
  }
  if (status) {
    status.textContent="Study: "+(state.studyFile || "unsaved")+" · TOML: "+(state.tomlFile || "none selected")+(state.studyDirty ? " · Unsaved changes" : " · Saved");
    status.setAttribute("data-saved",String(!state.studyDirty));
    status.title = state.studyDirty ? "The Study definition has unsaved changes. Saving TOML does not save the complete Study." : "The Study definition was loaded or saved successfully. Camera and display changes do not affect this status; Save Study includes their current settings.";
  }
  if (server) server.textContent=state.inputFile || "Reading server input path…";
  if (saved && state.lastFileSave) {
    const file=state.lastFileSave;
    saved.textContent=file.method==="picker" ? "Last save: selected file "+file.name : file.method==="server" ?
      "Last save: server input "+file.name : "Last save: download requested for "+file.name;
    saved.title=file.method==="picker" ? "The browser reports the filename, not the full folder path." :
      file.method==="server" ? file.name : "Your browser download settings choose the folder. Enable ‘Ask where to save each file’ to select a location.";
  }
}
function recordFileSave(destination,kind,revision = state.studyRevision) {
  state.lastFileSave={method:destination.method,name:destination.name};
  if (kind==="study") state.studyFile=destination.name; else state.tomlFile=destination.name;
  if (kind==="study") markStudySaved(revision);
  updateFileStatus();
  if (destination.method==="download") log((destination.guidance || "Download requested.")+" Browser download settings choose the folder; enable ‘Ask where to save each file’ to choose a location.","warn");
}
function workspaceOperationAvailable() {
  return !state.workspaceBusy && !state.exportBusy && !state.busy && !state.loadingInput && !state.meshRequestInFlight &&
    !state.polling && !state.solverStarting && !state.sensitivityBusy && !state.reference?.loading && !state.reference?.saving &&
    !state.reference?.isInteracting();
}

function sensitivityOperationContext() {
  const pendingDrafts=resultsHavePendingDrafts();
  let invalidDefinition=false,definitionChanged=false;
  try{definitionChanged=!!state.data&&formSignature()!==state.modelSignature;}catch(_){invalidDefinition=true;}
  const dirty=!!state.modelDirty||pendingDrafts||definitionChanged||invalidDefinition;
  const blockedReason=state.sensitivityBusy?'A sensitivity analysis is running. Wait for it to finish, or use Stop sensitivity.':
    state.polling||state.solverStarting?'JFEM is running or starting. Wait for the analysis to finish before starting sensitivity.':
    state.meshRequestInFlight?'Creating FEM. Sensitivity properties will refresh when the mesh is ready.':
    state.loadingInput||state.workspaceBusy?'A Study or model file operation is in progress. Wait for it to finish.':
    state.exportBusy?'A model export is in progress. Wait for the export to finish.':
    state.reference?.loading||state.reference?.saving?'Reference geometry is loading or saving. Wait for it to finish.':
    state.reference?.isInteracting()?'Finish moving the reference geometry before starting sensitivity.':
    state.busy?'A model operation is in progress. Wait for it to finish.':'';
  return{ready:!!state.data,dirty,pendingDrafts,signature:state.modelSignature,meshIdentity:state.meshIdentity,catalogVisible:workspaceUI.activeTab==='sensitivity',
    blocked:!!blockedReason,blockedReason,working:!!(state.sensitivityBusy||state.polling||state.solverStarting||state.meshRequestInFlight||state.loadingInput||state.workspaceBusy||state.exportBusy||state.reference?.loading||state.reference?.saving||state.busy),
    dirtyReason:pendingDrafts?'Property-table edits are not applied yet. Finish or discard the highlighted drafts, then create the FEM.':
      invalidDefinition?'Some model fields are incomplete or invalid. Correct them before creating the FEM.':''};
}

function installSensitivity() {
  if(state.sensitivity || typeof WingSensitivity==="undefined")return;
  state.sensitivity=WingSensitivity.create(document.getElementById("sensitivity-editor"),{
    context:sensitivityOperationContext,
    cases:()=>modelCases(),
    onEdit:text=>{state.values["sensitivity.settings"]=text;markStudyModified();refreshSensitivityMapCard();updateAnalysisValidity();},
    inspected:target=>target==="node_id"&&state.selectedNode!==null ? Number(state.nodeIds[state.selectedNode]) : target==="element_id" ? state.selectedElement : null,
    catalog:async()=>{
      const context=sensitivityOperationContext();
      if(context.blocked||context.dirty||!context.ready)throw Error(context.blockedReason||context.dirtyReason||"Create the current FEM before reading sensitivity properties.");
      const parameters=collectParams(),signature=state.modelSignature,meshIdentity=state.meshIdentity,token=activity()?.begin("Reading sensitivity properties");setBusy(true);
      try{const response=await postParams("/api/sensitivity/catalog",{parameters},token);if(!response.ok)throw Error(await readError(response));return{...await response.json(),imported:!!state.importedDeck,model_signature:signature,mesh_identity:meshIdentity};}
      finally{activity()?.end(token);setBusy(false);}
    },
    rebuild:()=>createFEM({preserveView:true}),
    listRuns:()=>savedSensitivityRequest("list",{}),
    loadRun:async id=>{
      const signature=state.modelSignature;
      const data=await savedSensitivityRequest("load",{run_id:id});
      acceptSensitivityResult(data.result,signature,{...data,run_id:id});
      await autoLoadSensitivityBaseline(data.result,{...data,run_id:id});
      return {...data,signature,matches:!!data.compatibility?.is_current,historical:!data.compatibility?.is_current};
    },
    onVisualize:showSensitivityMap,
    onResultChanged:()=>{refreshSensitivityMapCard();updateAnalysisValidity();},
    onShowBaseline:showSensitivityBaseline,
    onDownloadBaseline:downloadSensitivityBaseline,
    onClearVisualization:clearSensitivityMap,
    run:startSensitivity,
    cancel:async()=>{if(!state.sensitivityJob)return;const response=await fetch("/api/sensitivity/stop?job="+encodeURIComponent(state.sensitivityJob),{method:"POST"});if(!response.ok)throw Error(await readError(response));await pollSensitivity();},
    download:text=>WingWorkspace.downloadText(text,"sensitivity-results.csv","text/csv;charset=utf-8",document),
  });
  if(typeof WingSensitivityTables!=="undefined"){
    state.sensitivityTables=WingSensitivityTables.connect({readSnapshot:()=>{
      const current=!!state.data&&!state.modelDirty&&!resultsHavePendingDrafts()&&state.sensitivityMeta?.signature===state.modelSignature;
      return{result:state.sensitivityResult,scope:state.sensitivityMeta?.scope,sourcePath:state.sensitivityMeta?.source_path,
        compatibility:{...state.sensitivityMeta?.compatibility,...(!current?{is_current:false,topology_match:false,map_allowed:false}:{})},
        panels:current?state.data?.stiffened_panels?.panels||[]:[]};
    },onError:message=>log(message,"error")});
    state.sensitivityTables.installButton(document.getElementById("sensitivity-csv").parentElement);
    const button=document.createElement("button");button.id="sensitivity-open-data-table";button.type="button";button.className="mini";button.textContent="Open data table ↗";
    button.onclick=()=>state.sensitivityTables.open();document.getElementById("sensitivity-map-actions").append(button);
  }
  document.getElementById("sensitivity-map-show").onclick=()=>showSensitivityMapSelection();
  for(const id of ["sensitivity-map-property","sensitivity-map-change","sensitivity-map-metric","sensitivity-map-mode","sensitivity-field-family","sensitivity-field-quantity","sensitivity-visible-range"]){
    document.getElementById(id).onchange=()=>{refreshSensitivityMapCard();if(state.sensitivityMap)showSensitivityMapSelection();};
  }
  document.getElementById("btn-max-sensitivity").onclick=()=>setWorkspaceMaximized(workspaceUI.maximizedTab==="sensitivity"?null:"sensitivity");
  document.getElementById("btn-help-sensitivity").onclick=()=>openHelp({title:"Sensitivity analysis",paragraphs:[
    "Create the FEM, choose Sensitivity under Loads, and read its properties. Wildcard examples (replace these words with your own): P* or P_ matches names starting with P; *skin* matches names containing skin; *bar*lower* matches bar followed by lower. Text is a literal filter; Regex accepts a case-insensitive regular expression, for example upper.*thickness|spar. Add matches retains selections from earlier filters; Remove matches removes only matching selected variables. Clear filter leaves selections unchanged. Invalid expressions are shown beside the filter. Select an enabled case, a scalar objective and active property variables. Use Inspect to find node or element IDs. Shell components follow displayed local axes; z1/z2 recover toward negative/positive local z (outer ply midpoints for sandwich shells).",
    "When Run sensitivity is unavailable, its inline message explains the reason and provides a recovery action where possible. Finish property-table drafts before updating the FEM. A previously read property list refreshes automatically when you return to Sensitivity after a mesh rebuild; selected variables are kept. This refresh never starts an analysis. A changed model response arriving late is discarded. Missing properties require explicit removal from the selection. An unavailable idle action uses a blocked cursor; a progress cursor means an operation is actually running.",
    "The default is an analytic discrete adjoint. One baseline analysis supplies the state; one shared transpose adjoint supplies static-response derivatives for all selected variables. Modal eigenvalues use the baseline mode directly; buckling includes an adjoint for the static preload. No perturbed forward solutions are used.",
    "Analytic mode differentiates the actual native element formulas using exact chain rules and automatic differentiation, including stiffness, mass, inertia loads, T-section offsets and explicit stress recovery. It uses no property perturbations or finite-difference step. Each property still needs its affected element derivatives and contractions. Unsupported formulations fail explicitly. The separate legacy operator-difference option retains property steps and an optional half-step comparison for checking earlier calculations.",
    "Displacement and stress use SOL101, modal eigenvalues use SOL103 with the selected fuel state, and buckling uses SOL105 with fixed-direction preload. Repeated eigenvalues and nondifferentiable response branches are reported explicitly. Connectivity and property IDs remain fixed; inactive property defaults are excluded from the catalog.",
    "Completed results include a ranked chart and first-order response estimates for a proposed percentage change in each property. Open saved runs to inspect earlier analyses without rerunning them. Show sensitivity field opens a Results contour of df/dp or normalized p/f times df/dp for a property family. Elements governed by the same property share its derivative; overlapping variables and unavailable derivatives remain gray. The separate property-effect preview shows the first-order response change for one property. These are derivatives of the selected scalar response, not newly solved element stresses. Skins and Stringers open separate panel tables with stringers as rows, rib bays as columns and matching P numbers. Blank cells inherit defaults. Select Panel skins or Panel stringers variables to compute independent panel derivatives, including inherited values; these take precedence over shared-default derivatives in the field. Show baseline case displays the retained original solution as an ordinary Results analysis variant; downloads include its deck and physical result fields, never operator samples. Historical results remain readable, but mapping requires matching geometry and property definitions. Setup is saved in Study and TOML. Save results CSV exports the derivative table. Existing ordinary analysis results remain available."
  ]});
}

async function savedSensitivityRequest(action,extra) {
  if(!workspaceOperationAvailable())throw Error("Finish the active operation before opening saved sensitivity results.");
  const model=state.data,signature=state.modelSignature,parameters=collectParams(),token=activity()?.begin(action==="list"?"Finding saved sensitivity runs":"Opening sensitivity results");
  try{
    const response=await postParams("/api/sensitivity/saved/"+action,{parameters,...extra},token);if(!response.ok)throw Error(await readError(response));
    const data=await response.json();
    // These lightweight requests do not lock the Study. Never install an old
    // model's saved results while a replacement deck is loading or afterwards.
    if(state.data!==model||state.modelSignature!==signature||state.workspaceBusy)throw Error("The model changed while saved sensitivity data were being read. The obsolete response was discarded.");
    return data;
  }
  finally{activity()?.end(token);}
}

function acceptSensitivityResult(result,signature,metadata={}) {
  clearSensitivityMap();
  const same=!!state.data&&!state.modelDirty&&signature===state.modelSignature;
  const caseId=Number(result.case_id??result.request?.case_id),currentVersion=state.data?.load_cases?.find(c=>Number(c.id)===caseId)?.loads?.load_application_version||state.data?.loads?.load_application_version;
  const versionMatch=typeof result.load_application_version==="string"&&!!result.load_application_version&&result.load_application_version===currentVersion;
  state.sensitivityResult=result;
  state.sensitivityMeta={...metadata,signature,meshIdentity:signature===state.modelSignature?state.meshIdentity:null,scope:metadata.scope||result.scope,compatibility:metadata.compatibility||result.compatibility||
    {map_allowed:same,model_match:same,topology_match:same,load_application_match:versionMatch,is_current:same&&versionMatch,reasons:versionMatch?[]:["This run uses an earlier load application convention; rerun sensitivity for the current loading."]}};
  const select=document.getElementById("sensitivity-map-property");select.replaceChildren();
  for(const item of WingSensitivityResults.rankEffects(result,1)){
    const option=document.createElement("option");option.value=item.row.id;option.textContent=item.label;select.append(option);
  }
  document.getElementById("sensitivity-map-change").value="1";
  document.getElementById("sensitivity-map-mode").value="field";
  const families=document.getElementById("sensitivity-field-family");families.replaceChildren();
  for(const field of WingSensitivityMap.fields(result,state.sensitivityMeta.scope)){
    const option=document.createElement("option");option.value=field.key;option.textContent=field.label;families.append(option);
  }
  refreshSensitivityMapCard();
  updateAnalysisValidity();
}

function sensitivityMappingAllowed(){return !!state.sensitivityResult&&!!state.data&&!state.modelDirty&&!resultsHavePendingDrafts()&&
  state.sensitivityMeta?.signature===state.modelSignature&&(state.sensitivityMeta?.meshIdentity===undefined||state.sensitivityMeta.meshIdentity===state.meshIdentity)&&!!state.sensitivityMeta?.compatibility?.map_allowed;}

function refreshSensitivityMapCard(){
  state.sensitivityTables?.refresh();
  const result=state.sensitivityResult,controls=document.getElementById("sensitivity-map-controls");if(!controls)return;
  controls.hidden=!result;
  const status=document.getElementById("sensitivity-map-status");if(!result){status.textContent="";return;}
  const base=WingSensitivityResults.baseline(result),row=result.rows?.find(r=>r.id===document.getElementById("sensitivity-map-property").value);
  const change=Number(document.getElementById("sensitivity-map-change").value),effect=WingSensitivityResults.rowEffect(result,row,change);
  const historical=!state.sensitivityMeta?.compatibility?.is_current||state.modelDirty||resultsHavePendingDrafts()||state.sensitivityMeta?.signature!==state.modelSignature;
  const fieldMode=document.getElementById("sensitivity-map-mode").value==="field";
  for(const id of ["sensitivity-property-row","sensitivity-change-row","sensitivity-metric-row"])document.getElementById(id).hidden=fieldMode;
  for(const id of ["sensitivity-field-row","sensitivity-field-quantity-row","sensitivity-visible-row"])document.getElementById(id).hidden=!fieldMode;
  document.getElementById("sensitivity-map-summary").textContent=(historical?"Historical run · ":"")+(result.case_label||"Case "+(result.case_id||result.request?.case_id||""))+" · "+WingSensitivityResults.objectiveLabel(result)+" · baseline "+eng(base.value,6)+" "+(base.unit||"");
  const estimate=document.getElementById("sensitivity-map-estimate");
  estimate.textContent=effect.valid?"Predicted response change: "+eng(effect.deltaResponse,6)+" "+effect.responseUnit+(effect.percentOfBaseline!==null?" ("+eng(effect.percentOfBaseline,4)+"%)":"")+" · predicted response: "+eng(effect.predictedResponse,6)+" "+effect.responseUnit+" · first-order estimate.":effect.reason;
  let fieldError="";
  if(fieldMode){try{const c=selectedSensitivityField();estimate.textContent=c.field.rows.length+" property derivatives mapped onto "+c.byId.size+" elements. "+c.note;}catch(error){fieldError=error.message;estimate.textContent=fieldError;}}
  const show=document.getElementById("sensitivity-map-show");show.textContent=fieldMode?"Show sensitivity field":"Show property effect on model";
  show.disabled=!sensitivityMappingAllowed()||(fieldMode?!!fieldError:!effect.valid||!state.sensitivityMeta?.scope?.variables?.[row?.id]?.eids?.length);
  const reasons=state.sensitivityMeta?.compatibility?.reasons||[];
  const setupChanged=state.sensitivity?.isSetupCurrent?.()===false;
  status.textContent=(!sensitivityMappingAllowed()?"Mapping unavailable: open the matching Study, create its FEM, and reopen the saved run. ":"")+
    (historical&&!reasons.length?"Historical result; review the recorded model and load convention. ":"")+reasons.join(" ")+
    (setupChanged?" Sensitivity setup changed. These values and colors describe the recorded response above, not the newly selected objective or variables. The physical FE baseline remains valid.":"");
  status.classList.toggle("sensitivity-error",historical||!sensitivityMappingAllowed());
  status.classList.toggle("model-warning",setupChanged);
  refreshSensitivityDisplayButtons();
}

function showSensitivityMapSelection(){
  if(document.getElementById("sensitivity-map-mode").value==="field")return showSensitivityField();
  const row=state.sensitivityResult?.rows?.find(r=>r.id===document.getElementById("sensitivity-map-property").value);
  return showSensitivityMap(state.sensitivityResult,row,{changePercent:Number(document.getElementById("sensitivity-map-change").value),metric:document.getElementById("sensitivity-map-metric").value});
}

function selectedSensitivityField(){return WingSensitivityMap.buildField(state.sensitivityResult,state.sensitivityMeta?.scope,
  document.getElementById("sensitivity-field-family").value,document.getElementById("sensitivity-field-quantity").value);}

function updateSensitivityVisibleRange(contour){
  if(contour?.kind!=="sensitivity_field")return;
  const visibleOnly=document.getElementById("sensitivity-visible-range")?.checked;
  const values=[];
  for(const [eid,value]of contour.byId){
    const element=state.elements.get(eid);
    if(visibleOnly&&(!element||!state.layers.get(element.group.name)?.visible))continue;
    values.push(value);
  }
  const {min,max,count}=WingSensitivityMap.valueRange(values);
  contour.min=min;contour.max=max;contour.visibleCount=count;
  contour.baseNote??=contour.note;
  contour.note=contour.baseNote+(visibleOnly?" Color range uses "+count+" visible elements.":"");
}

function showSensitivityField(){
  if(!sensitivityMappingAllowed())throw Error("Create the matching FEM and reopen the sensitivity run before displaying a field.");
  const contour=selectedSensitivityField();displaySensitivityContour(contour);
}

function showSensitivityMap(result,row,options={}){
  if(result!==state.sensitivityResult||!row||!sensitivityMappingAllowed())throw Error("Open the matching Study and create its FEM, then reopen the saved run before mapping property effects.");
  if(options.mode==="field"){
    document.getElementById("sensitivity-map-mode").value="field";
    const field=WingSensitivityMap.fields(result,state.sensitivityMeta.scope).find(field=>field.rows.some(r=>r.id===row.id));
    if(field)document.getElementById("sensitivity-field-family").value=field.key;
    return showSensitivityField();
  }
  document.getElementById("sensitivity-map-mode").value="preview";
  const change=options.changePercent??1,metric=options.metric||document.getElementById("sensitivity-map-metric").value;
  const contour=WingSensitivityMap.build(result,row,state.sensitivityMeta.scope,change,metric);
  document.getElementById("sensitivity-map-property").value=row.id;document.getElementById("sensitivity-map-change").value=change;
  document.getElementById("sensitivity-map-metric").value=metric;
  displaySensitivityContour(contour);
}

function displaySensitivityContour(contour){
  state.propertyDisplay?.setEnabled(false);
  if(state.panelView)setPanelDisplay(false);
  restoreFuelIsolation();
  if(!state.sensitivityMeta.compatibility.is_current&&!contour.caseLabel?.startsWith("Historical · "))contour.caseLabel="Historical · "+contour.caseLabel;
  const previous=state.sensitivityMap?.previous||{animate:document.getElementById("animate").checked,
    resultsHidden:document.getElementById("results-card").hidden,overlays:new Map()};
  state.sensitivityMap={contour,previous};
  restoreHistoricalBaselineOverlays();
  refreshAppliedLoadLayers();
  document.getElementById("animate").checked=false;document.getElementById("results-card").hidden=true;
  const entering=workspaceUI.activeTab!=="sensitivityresults";
  restoreBaseline();applyContour();syncResultOverlays();suppressSensitivityOverlays();refreshSensitivityMapCard();activateWorkspaceTab("sensitivityresults");
  if(entering)document.getElementById("sensitivity-map-card").scrollIntoView({block:"start"});
}

function suppressSensitivityOverlays(){
  const map=state.sensitivityMap;if(!map)return;
  // Reactions belong to an ordinary solution. VLM contours and applied loads
  // describe the explicitly selected undeformed load case and remain usable.
  let changed=false;
  for(const name of ["SUPPORT_FORCES","FUEL_INERTIA"]){
    const layer=state.layers.get(name);if(!layer)continue;
    if(!map.previous.overlays.has(name))map.previous.overlays.set(name,{visible:layer.visible,meshes:new Map(layer.meshes.map(mesh=>[mesh,mesh.isEnabled()]))});
    changed=changed||layer.visible;layer.visible=false;
    for(const mesh of layer.meshes)if(mesh.isEnabled())mesh.setEnabled(false);
    const checkbox=document.getElementById("layer-"+name);if(checkbox)checkbox.checked=false;
  }
  if(changed)updateViewportLegends();
}

function clearSensitivityMap(){
  const map=state.sensitivityMap;if(!map)return;
  state.sensitivityMap=null;
  document.getElementById("animate").checked=map.previous.animate;
  document.getElementById("results-card").hidden=map.previous.resultsHidden;
  for(const [name,previous]of map.previous.overlays){
    const layer=state.layers.get(name);if(!layer)continue;layer.visible=previous.visible;
    for(const mesh of layer.meshes)mesh.setEnabled(previous.meshes.get(mesh)??previous.visible);
    const checkbox=document.getElementById("layer-"+name);if(checkbox)checkbox.checked=previous.visible;
  }
  if(state.data){refreshAppliedLoadLayers();applyContour();applyVlmContour();applyDeformation();syncResultOverlays();syncLayerGroupControls();}
  refreshSensitivityMapCard();
}

function sensitivityRunHandle(result,context={}){
  const metadata=result===state.sensitivityResult?{...state.sensitivityMeta,...context}:context;
  if(metadata.run_id)return{run_id:metadata.run_id};
  if(metadata.job)return{job:metadata.job};
  const path=metadata.source_path||metadata.sourcePath||result?.source_path;
  const id=path?.replaceAll("\\","/").split("/").at(-2);
  if(id&&/^sensitivity_[A-Za-z0-9_]+$/.test(id))return{run_id:id};
  throw Error("Reopen the saved sensitivity run to locate its baseline files.");
}

async function showSensitivityBaseline(result,context,options={}){
  if(!workspaceOperationAvailable()||state.modelDirty||resultsHavePendingDrafts()||!state.data)throw Error("Create the matching FEM and finish the current operation first.");
  const signature=state.modelSignature,parameters=collectParams(),handle=sensitivityRunHandle(result,context);
  const token=activity()?.begin("Loading sensitivity baseline",{detail:"Reading the original solved load case, without another solve"});setBusy(true);
  try{
    const response=await postParams("/api/sensitivity/baseline",{parameters,...handle},token);if(!response.ok)throw Error(await readError(response));
    const payload=await decodePayload(await response.arrayBuffer());
    if(state.modelDirty||state.modelSignature!==signature||payload.node_count!==state.data.nodes.count||payload.compatibility?.map_allowed!==true)throw Error("The sensitivity baseline does not match the displayed FEM.");
    clearSensitivityMap();if(state.panelView)setPanelDisplay(false);restoreFuelIsolation();
    state.resultCases??=new Map();let selected;
    for(const c of payload.load_cases||[]){
      const baseline=decodeResultCase(c,payload,signature);if(!baseline.matches)throw Error("Baseline parameters no longer match the Study.");
      const id=Number(c.physical_case_id??c.id),old=state.resultCases.get(id);
      const variants=new Map(old?.variants||[]);
      if(old&&!old.variants){const key=old.variantId||String(old.analysis).match(/SOL\d+/i)?.[0]?.toLowerCase()||"ordinary";variants.set(key,{...old,variantId:key});}
      variants.set(baseline.variantId,baseline);
      state.resultCases.set(id,{...(old||baseline),variants,defaultVariant:old?.defaultVariant||variants.keys().next().value});
      selected={id,variant:baseline.variantId};
    }
    if(!selected)throw Error("The sensitivity run contains no solved baseline cases.");
    state.resultVariantPreference=selected.variant;selectLoadCase(selected.id);if(options.activate!==false)activateWorkspaceTab("results");
    log((payload.historical?"Historical ":"")+"Sensitivity baseline loaded as an analysis variant for load case "+selected.id+". Ordinary analyses remain available.",payload.historical?"warn":"good");
  }finally{activity()?.end(token);setBusy(false);}
}

async function autoLoadSensitivityBaseline(result,context){
  if(!result?.baseline_analysis?.available||!state.sensitivityMeta?.compatibility?.is_current||!sensitivityMappingAllowed())return false;
  try{await showSensitivityBaseline(result,context,{activate:false});return true;}
  catch(error){log("Sensitivity results are ready, but their baseline could not be opened automatically: "+error.message+". Use Show baseline case to retry.","warn");return false;}
}

async function downloadSensitivityBaseline(kind,result,context){
  if(!workspaceOperationAvailable())throw Error("Finish the current operation first.");
  const handle=sensitivityRunHandle(result,context),token=activity()?.begin("Exporting sensitivity baseline");
  try{
    const response=await postParams("/api/sensitivity/baseline/download",{parameters:collectParams(),...handle,file:kind},token);
    if(!response.ok)throw Error(await readError(response));
    const blob=await response.blob(),url=URL.createObjectURL(blob),link=document.createElement("a");
    const ext=kind==="deck"?"bdf":kind==="native"?"json":"msgpack";
    link.href=url;link.download=(handle.run_id||handle.job)+"_baseline."+ext;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),10000);
    log("Sensitivity baseline "+kind+" download requested; operator perturbations are excluded.","good");
  }finally{activity()?.end(token);}
}

async function startSensitivity(settings) {
  const context=sensitivityOperationContext();
  if(context.blocked||context.dirty||!context.ready)throw Error(context.blockedReason||context.dirtyReason||"Create the current FEM before starting sensitivity.");
  const parameters=collectParams();state.sensitivitySignature=state.modelSignature;state.sensitivityBusy=true;state.sensitivity?.setBusy(true);cancelAutoMeshTimer();setBusy(false);
  const token=activity()?.begin("Preparing sensitivity analysis",{detail:"Validating the case, objective and property perturbations…"});
  try{
    const response=await postParams("/api/sensitivity/run",{parameters,settings},token);if(!response.ok)throw Error(await readError(response));const data=await response.json();
    state.sensitivityJob=data.job;state.sensitivityLogTail="";solverActivity(true);state.sensitivity?.progress({message:"JFEM sensitivity is starting; first use may compile the solver"});
    log("Sensitivity "+data.job+" started. Output: "+data.outdir);pollSensitivity();
  }catch(error){state.sensitivityBusy=false;state.sensitivity?.setBusy(false);setBusy(false);throw error;}
  finally{activity()?.end(token);}
}

function acceptSensitivityBaselineOnly(status,signature,job){
  const meta=status.baseline_analysis;if(!meta?.available)return;
  const result={status:"baseline_only",case_id:meta.case_id,case_label:meta.case_label,solution:meta.solution,
    objective:status.request?.objective||{},baseline:{value:null,unit:""},rows:[],baseline_analysis:meta,
    load_application_version:meta.load_application_version,method:"discrete_adjoint",
    warnings:["The physical baseline was solved and retained. The derivative calculation did not complete; no sensitivity values are available."]};
  acceptSensitivityResult(result,signature,{job});state.sensitivity?.complete(result,signature,state.sensitivityMeta);
}

async function pollSensitivity() {
  clearTimeout(state.sensitivityTimer);state.sensitivityTimer=null;const id=state.sensitivityJob;if(!id||!state.sensitivityBusy)return;
  try{
    const response=await fetch("/api/sensitivity/status?job="+encodeURIComponent(id),{cache:"no-store",signal:AbortSignal.timeout(15000)});if(!response.ok)throw Error(await readError(response));const status=await response.json();if(state.sensitivityJob!==id||!state.sensitivityBusy)return;
    state.sensitivity?.error("");state.sensitivity?.progress(status);
    const detail=status.progress?.detail||status.message;activity()?.update(state.solverActivityToken,{label:"JFEM sensitivity is running",detail});
    const indicator=document.getElementById("jfem-running");if(indicator)indicator.textContent="JFEM sensitivity is running";
    const nativeStatus=document.getElementById("solver-progress");if(nativeStatus){nativeStatus.hidden=false;nativeStatus.textContent=detail;}
    if(status.log&&status.log!==state.sensitivityLogTail){const previous=state.sensitivityLogTail||"",overlap=previous?status.log.indexOf(previous):0;
      const fresh=previous&&overlap>=0?status.log.slice(overlap+previous.length):status.log;for(const line of fresh.split(/\r?\n/).filter(Boolean).slice(-150))log(line);state.sensitivityLogTail=status.log;}
    if(["done","partial","failed","cancelled"].includes(status.state)){
      state.sensitivityBusy=false;state.sensitivity?.setBusy(false);state.sensitivity?.progress(status);solverActivity(false);
      if(status.result){acceptSensitivityResult(status.result,state.sensitivitySignature,{job:id,terminalState:status.state});state.sensitivity?.complete(status.result,state.sensitivitySignature,state.sensitivityMeta);}
      else acceptSensitivityBaselineOnly(status,state.sensitivitySignature,id);
      if(status.state==="failed")state.sensitivity?.error(typeof status.error==="string"?status.error:status.error?.message||status.message||"Sensitivity failed. See Log.");
      log("Sensitivity "+status.state+": "+status.message+". Files: "+status.outdir,status.state==="done"?"good":status.state==="cancelled"?"warn":"err");setBusy(false);
      await autoLoadSensitivityBaseline(state.sensitivityResult,{job:id});return;
    }
  }catch(error){if(state.sensitivityJob===id)state.sensitivity?.error("Cannot read sensitivity progress: "+error.message+". Retrying; the worker may still be running.");}
  if(state.sensitivityBusy&&state.sensitivityJob===id)state.sensitivityTimer=setTimeout(pollSensitivity,1000);
}

async function workspaceOperation(action, label = "Preparing Study file") {
  if (!workspaceOperationAvailable()) { log("Wait for the active mesh, solver or reference operation before using Study/TOML files.", "warn"); return false; }
  state.workspaceBusy = true;
  cancelAutoMeshTimer(); setBusy(true);
  const app = document.getElementById("app"), canvas = document.getElementById("render");
  app.inert = true; state.camera.detachControl();
  const token = activity()?.begin(label);
  try { const panel=document.getElementById("model-error");if(panel.dataset.kind==="operation")panel.hidden=true;await paintActivity(); return await action(token); }
  catch (error) { log(label + ": " + error.message, "err"); showOperationError(label === "Saving viewport SVG" ? "SVG export failed" : label + " failed",error.message); return false; }
  finally {
    activity()?.end(token);
    app.inert = false; state.camera.attachControl(canvas, true);
    state.workspaceBusy = false; setBusy(false);
  }
}

async function saveModelDefinition({saveAs=false} = {}) {
  if (!workspaceOperationAvailable()) return false;
  try { state.panelTables?.assertValidDraft?.(); }
  catch(error) { showOperationError("Study not saved",error.message);log(error.message,"warn");return false; }
  const title=state.importedDeck ? fileBasename(state.importedDeck.source.name).replace(/\.(bdf|dat|nas)$/i,"") : state.values["output.title"];
  const name=state.studyFile || WingWorkspace.filename(title);
  const requested=WingWorkspace.requestStudyDestination(name,{handle:state.studyFileHandle,saveAs},window);
  return workspaceOperation(async token => {
    const destination=await requested;
    if (destination.cancelled) return false;
    if (destination.error) throw destination.error;
    activity()?.update(token, {label:"Saving Study", detail:"Embedding references and display settings…"});
    meshStatus("Saving Study…", "building");
    const params = state.importedDeck ? {...state.values,"sensitivity.settings":state.sensitivity?.serialize()||""} : collectParams(); params["references.items"] = [];
    let validated={parameters:params};
    // Imported GRID/cards are authoritative. Dormant wing-form metadata must
    // not require a valid generated wing just to save the original source.
    // snapshot still validates the source, view and portable reference data;
    // serialize above validates the current sensitivity setup independently.
    if(!state.importedDeck){
      const response = await postParams("/api/validate_workspace", params);
      if (response.status === 404) throw new Error("Portable model files need the updated server. Restart WingFEGen and refresh.");
      if (!response.ok) throw new Error(await readError(response));
      validated = await response.json();
    }
    const view = WingWorkspace.captureView(document, state, workspaceUI);
    const savedRevision = state.studyRevision;
    const savedAt=new Date().toISOString(),notes=WingWorkspace.notesForSave(state.studyNotes,document.getElementById("study-note")?.value || "",savedAt);
    const data = await WingWorkspace.snapshot(validated.parameters, state.reference, view,{notes,savedAt,createdAt:state.studyCreatedAt,modelSource:state.importedDeck?.source});
    const text = JSON.stringify(data,null,2);
    await WingWorkspace.writeDestination(destination,text,"application/json",document);
    state.studyFileHandle=destination.handle || null;
    state.studyNotes=data.notes;state.studyCreatedAt=data.created_at;state.studySavedAt=data.saved_at;syncStudyNotes();
    recordFileSave(destination,"study",savedRevision);
    await rememberStudy({name:destination.name,text,handle:destination.handle,id:saveAs ? null : state.studyRecentId,source:"saved"});
    const action=destination.method==="picker" ? "Saved " : "Download requested: ";
    meshStatus(action + destination.name, state.modelDirty ? "stale" : "current");
    log(action + "Study " + destination.name + " with " + data.references.length + " embedded references. Parameters, load cases and display settings are included; results are separate.", "good");
    return data;
  });
}

function restoreWorkspaceView(view) {
  state.layerGroupCollapsed=new Map(Object.entries(view.layerGroups||{}));
  if(state.panelView)setPanelDisplay(false,false);
  state.propertyDisplay?.restore(view.propertyDisplay);
  if(typeof WingLegends!=="undefined")WingLegends.restore(view.legends,{legacyPalette:view.controls["result-palette"]});
  state.sceneLighting?.restore(view.lighting);
  state.panelExplosion?.restore(view.panelExplosion);syncPanelExplosionControls();
  if (typeof WingSVGViewport !== "undefined") WingSVGViewport.restoreAll(view.drawings || {});
  state.viewportTools?.restore(view.viewportTools);
  state.planformInputs?.restore(view.planformInputs);
  restorePlanViewMetadata(view.planView);
  state.parameterLocks?.restore(view.parameterLocks || {});
  state.realScale = view.realScale === true;
  document.getElementById("show-rib-datums").checked = view.controls["show-rib-datums"] === true;
  document.getElementById("rib-datum-size").value = view.controls["rib-datum-size"] ?? "1";
  for (const id of ["show-ground-plane", "show-symmetry-plane"]) {
    const control = document.getElementById(id); if (control) control.checked = view.controls[id] === true;
  }
  for (const [id, fallback] of [["ground-plane-z", "0"], ["ground-grid-spacing", "5"]]) {
    const control = document.getElementById(id); if (control) control.value = view.controls[id] ?? fallback;
  }
  WingWorkspace.applyControls(document, view.controls);
  document.getElementById("result-palette").value=WingLegends.getPalette("fe");
  refreshFuelMassProperties();
  state.resultVariantPreference = view.resultVariant || "";
  state.contourPreference = view.contourPreference || null;
  state.autoMeshEnabled = document.getElementById("auto-mesh").checked;
  selectLoadCase(view.activeCase);
  state.loadPlots?.restore(view.loadPlots);
  syncManualMeshAction();
  // Case changes rebuild load layers; restore their visibility afterwards.
  state.loadLayerVisibility = new Map(Object.entries(view.loadLayers || {}));
  batchLayerVisibility(()=>{
    for (const [name, visible] of state.loadLayerVisibility) setLayerVisible(name, visible);
    for (const [name, visible] of Object.entries(view.layers)) setLayerVisible(name, visible);
    for (const name of state.layers.keys()) if(name.endsWith("_KINKS") && view.layers[name]===undefined && typeof view.layers[name.slice(0,-6)]==="boolean") setLayerVisible(name,view.layers[name.slice(0,-6)]);
  });
  WingWorkspace.applyControls(document, view.controls);
  document.getElementById("result-palette").value=WingLegends.getPalette("fe");
  applySurfaceMode(); applyBeamStyle(); updateMarkerRadii(); applyVlmContour(); syncResultOverlays(); updateScaleText();
  rebuildSupportForces(); applyContour(); applyDeformation();refreshPanelExplosion();
  setPanelDisplay(document.getElementById("show-panels").checked);
  if (typeof rebuildVlmForceArrows === "function") rebuildVlmForceArrows();
  if (typeof applyBackgroundColor === "function") applyBackgroundColor(view.controls["background-color"], false);
  if (typeof inspectFilterChanged === "function") inspectFilterChanged();
  if (typeof syncVlmControls === "function") syncVlmControls();
  if (typeof syncAeroOverlayControl === "function") syncAeroOverlayControl();
  syncViewPlanes();
  syncRibDatums();
  state.editingCase = view.editingCase || 1; buildLoadCaseEditor();
  setWorkspaceMaximized(null); setPaneWidth(view.workspace.width);
  activateWorkspaceTab(WORKSPACE_TABS.some((tab) => tab[1] === view.workspace.activeTab) ? view.workspace.activeTab : "planform");
  if (view.workspace.maximizedTab && WORKSPACE_TABS.some((tab) => tab[1] === view.workspace.maximizedTab)) setWorkspaceMaximized(view.workspace.maximizedTab);
  const pane = document.getElementById("sidebar");
  if (pane.classList.contains("panel-collapsed") !== view.workspace.collapsed) pane.querySelector(".panel-toggle")?.click();
  for (const [id, collapsed] of Object.entries(view.workspace.panels || {})) {
    if (id === "sidebar") continue;
    const panel = document.getElementById(id);
    if (panel && panel.classList.contains("panel-collapsed") !== collapsed) panel.querySelector(".panel-toggle")?.click();
  }
  const camera = state.camera, saved = view.camera;
  for (const key of ["mode","fov","minZ","maxZ","orthoLeft","orthoRight","orthoTop","orthoBottom","lowerRadiusLimit","upperRadiusLimit"])
    if (saved[key] !== undefined) camera[key] = saved[key];
  camera.setTarget(BABYLON.Vector3.FromArray(saved.target));
  camera.alpha = saved.alpha; camera.beta = saved.beta; camera.radius = saved.radius;
  for (const key of ["inertialAlphaOffset","inertialBetaOffset","inertialRadiusOffset","inertialPanningX","inertialPanningY"]) camera[key] = 0;
  camera.getViewMatrix(true); state.annotations?.invalidate();
  state.viewportTools?.refresh(true);
  state.geometryTools?.refreshSelection();
}

async function linkedReferenceItems(records) {
  const items=[];
  for (const metadata of records || []) {
    const response=await fetch("/api/reference_asset?asset="+encodeURIComponent(metadata.asset_path),{cache:"no-store"});
    if (!response.ok) throw new Error("TOML reference is unavailable: "+metadata.source_name+". Reference paths use the server input folder. Load a Study to restore embedded geometry.");
    items.push({file:new File([await response.arrayBuffer()],metadata.source_name),metadata});
  }
  return items;
}

function showTomlPreview(){
  if(!state.tomlPreview)state.tomlPreview=WingTomlPreview.create({
    readCurrent:async()=>{
      const params=collectParams({includeView:true}),unlinked=(state.reference?.entries||[]).filter(entry=>!entry.assetPath).length;
      params["references.items"]=state.reference?.serialize()||[];
      const response=await postParams("/api/export_toml",params);if(!response.ok)throw Error(await readError(response));
      const result=await response.json();return{text:result.text,name:"Current definition · "+(state.tomlFile||"not saved as TOML"),
        note:"Read-only snapshot including current edits; the disk file is unchanged."+(unlinked?" "+unlinked+" uncached references are omitted from this preview; Save TOML caches and includes them, or Save Study embeds them.":"")};
    },
    readServer:async()=>{const response=await fetch("/api/input_text");if(!response.ok)throw Error(await readError(response));const result=await response.json();return{text:result.text,name:result.path,note:"Exact server input file from disk, including comments. Current unsaved Study edits are not included. No reload or write performed."};},
  });state.tomlPreview.open();
}

async function saveTomlAs() {
  if (!workspaceOperationAvailable()) return false;
  const name=state.tomlFile || WingWorkspace.filename(state.values["output.title"]).replace(/\.wingfem\.json$/,".toml");
  const requested=WingWorkspace.requestSaveDestination("toml",name,window);
  return workspaceOperation(async token=>{
    const destination=await requested;
    if (destination.cancelled) return false;
    if (destination.error) throw destination.error;
    activity()?.update(token,{detail:"Validating current parameters and load cases…"});
    const params=collectParams({includeView:true});
    const references=await state.reference.prepareTomlRecords();
    params["references.items"]=references.records;
    const response=await postParams("/api/export_toml",params);
    if (!response.ok) throw new Error(await readError(response));
    const result=await response.json();
    await WingWorkspace.writeDestination(destination,result.text,"application/toml",document);
    references.commit();
    recordFileSave(destination,"toml");
    const action=destination.method==="picker" ? "Saved " : "Download requested: ";
    meshStatus(action+destination.name,state.modelDirty ? "stale" : "current");
    log(action+destination.name+". TOML contains all model parameters, cases, "+references.records.length+" linked references and all 2D view images, snap settings and dimensions. Reference assets use this server's cache; use Save Study for embedded portable geometry, all display settings and notes. The server input is unchanged.","good");
    return result;
  },"Saving TOML as");
}

async function loadModelDefinition(file, options = {}) {
  if (!file) return false;
  return workspaceOperation(async token => {
    state.studyRestoring = true;
    try {
    const parametersOnly=options.toml || options.newStudy || options.serverInput;
    activity()?.update(token, {label:options.importDeck ? "Reading Nastran" : options.newStudy ? "Creating new Study" : parametersOnly ? "Loading TOML" : "Loading Study", detail:options.importDeck ? "Reading the main deck and resolving INCLUDE files automatically…" : "Validating parameters and reference geometry…"});
    meshStatus("Preparing "+file.name+"…", "building");
    let definition,items,input,studyText;
    if (parametersOnly) {
      let parameters;
      if (options.newStudy) {
        if (!state.defaults) throw new Error("New Study requires the updated server. Restart WingFEGen and refresh.");
        parameters=JSON.parse(JSON.stringify(state.defaults));
      } else if (options.serverInput) {
        const response=await fetch("/api/input",{cache:"no-store"});
        if (!response.ok) throw new Error(await readError(response));
        input=await response.json();
        if (!input.ok) throw new Error(input.error || "Could not read server input");
        parameters=input.values;
      } else {
        if (file.size>128*1024*1024) throw new Error("TOML input exceeds the 128 MiB limit");
        const response=await postParams("/api/import_toml",{text:await file.text()});
        if (!response.ok) throw new Error(await readError(response));
        parameters=(await response.json()).parameters;
      }
      const view=WingWorkspace.captureView(document,state,workspaceUI);
      view.planView=parameters["view.plan_view"] ? JSON.parse(parameters["view.plan_view"]) : undefined;
      view.drawings=parameters["view.drawings"] ? JSON.parse(parameters["view.drawings"]) : {};
      view.parameterLocks={planform:false,mesh:false};
      view.activeCase=1;view.editingCase=1;view.reference={selectedIndex:-1,mode:"off"};
      view.contourPreference=null;
      if (options.newStudy) view.workspace.activeTab="planform";
      definition={parameters,view};items=await linkedReferenceItems(parameters["references.items"]);
    } else if(options.importDeck) {
      // Do not export/reimport the previous Study just to open another deck.
      // Besides retaining its filters, that used to validate unrelated old
      // display state and copy all embedded references before reading a BDF.
      const parameters=JSON.parse(JSON.stringify(state.defaults||state.values));
      parameters["references.items"]=[];parameters["sensitivity.settings"]="";
      definition={parameters,view:WingWorkspace.newModelView(document),notes:{text:"",history:[]}};
      items=[];
    } else { studyText=await file.text(); ({data:definition,items}=WingWorkspace.parse(studyText));definition.view=WingWorkspace.completeView(definition.view,document); }
    let staged = null, previous = null, commitStarted = false;
    const wasBuilding=state.buildingScene;
    try {
      staged = await state.reference.stagePortable(items, definition.view.reference, {linked:parametersOnly});
      const importRequest=options.importRequest || definition.model_source;
      const response = await postParams(importRequest ? "/api/import_nastran" : "/api/prepare_workspace", importRequest || definition.parameters, token);
      if (response.status === 404) throw new Error("Portable model files need the updated server. Restart WingFEGen and refresh.");
      if (!response.ok) throw new Error(await readError(response));
      const transferStarted=performance.now();
      if(importRequest)activity()?.update(token,{detail:"Receiving the complete deck geometry. The previous model stays visible until the new model is ready."});
      const buffer = await response.arrayBuffer(), byteLength = buffer.byteLength, decodeStarted=performance.now();
      if(importRequest)activity()?.update(token,{detail:"Decoding "+(byteLength/1048576).toFixed(1)+" MiB of model data before preparing the complete view…"});
      const data = await decodePayload(buffer);
      if(importRequest&&response.headers.get("X-Wing-Import-Timings"))data.import_timings=JSON.parse(response.headers.get("X-Wing-Import-Timings"));
      if(importRequest)log("Imported model transfer: "+((decodeStarted-transferStarted)/1000).toFixed(2)+" s; browser decoding: "+((performance.now()-decodeStarted)/1000).toFixed(2)+" s; "+(byteLength/1048576).toFixed(1)+" MiB. Preparing the complete viewport next.");
      if (!data.ok || !data.nodes || !data.groups) throw new Error("The prepared model is incomplete.");
      if(options.importDeck){
        definition.model_source=WingNastranImport.source(data.model_source || options.importRequest);
        definition.view.activeCase=definition.view.editingCase=Number(data.load_cases?.[0]?.id)||1;
      }
      // Keep one authoritative reference to the portable source; it is not
      // geometry data and need not travel through renderer/export snapshots.
      delete data.model_source;
      previous = { importedDeck:state.importedDeck, data:state.data, values:state.values, signature:state.modelSignature, lastEditedSignature:state.lastEditedSignature, dirty:state.modelDirty,
        pending:state.autoMeshPending, resultCases:state.resultCases, results:state.results,
        activeMode:state.activeMode, contourIdx:state.contourIdx, transfer:state.lastTransfer,
        selectedElement:state.selectedElement, selectedNode:state.selectedNode, fuelIsolation:state.fuelIsolation,
        loadCases:JSON.parse(JSON.stringify(state.loadCases)), view:WingWorkspace.captureView(document,state,workspaceUI),
        fields:state.schema.filter((spec)=>spec.kind!=="loadcases").map((spec)=>{
          const element=document.getElementById("p-"+spec.key); return [spec.key, element?.value, element?.checked];
        }) };
      commitStarted = true;
      // Retain the previous complete canvas until geometry, visibility, cases
      // and camera have all been committed. Never publish an intermediate
      // mesh, including during recovery from a failed import.
      state.buildingScene=true;
      state.importedDeck=definition.model_source ? {...data.imported_deck,source:definition.model_source} : null;
      if(state.importedDeck && (!state.importedDeck.token||!state.importedDeck.signature))throw Error("The imported deck response is missing its session identity.");
      state.values = state.importedDeck ? definition.parameters : data.model_params;
      buildForm(state.schema, state.values);
      WingWorkspace.applyControls(document, definition.view.controls);
      state.data = data;
      await buildModelResponsive(data, {preserveView:false, resetIsolation:true}, token);
      state.modelSignature = formSignature(state.values); state.lastEditedSignature = state.modelSignature;
      state.autoMeshPending = false; setModelDirty(false);
      showStats(data, byteLength, 0);
      restoreWorkspaceView(definition.view);
      staged.commit();
      if (parametersOnly) {
        state.values["references.items"]=state.reference.serialize();
        state.modelSignature=formSignature(state.values);state.lastEditedSignature=state.modelSignature;
        state.autoMeshPending=false;setModelDirty(false);fitView();
      }
      staged.finalize();
      state.panelTables?.resetDrafts?.();
      state.studyNotes=parametersOnly ? {text:"",history:[]} : definition.notes;
      state.studyCreatedAt=parametersOnly ? null : definition.created_at || null;
      state.studySavedAt=parametersOnly ? null : definition.saved_at || definition.created_at || null;
      syncStudyNotes();
      if (input) {state.inputFile=input.input_file;state.defaults=input.defaults || state.defaults;}
      state.studyFile=parametersOnly || options.importDeck ? null : file.name;
      state.studyFileHandle=parametersOnly ? null : options.handle || null;
      state.tomlFile=parametersOnly && !options.newStudy ? file.name : null;
      state.studyDirty = !!parametersOnly || !!options.importDeck;
      state.studyRecentId = parametersOnly ? null : options.recentId || null;
      updateFileStatus();
      meshStatus("Loaded " + file.name, "current");
      log((options.newStudy ? "Created new Study" : "Loaded "+file.name)+": " + data.nodes.count + " nodes, " + items.length + (parametersOnly ? " linked references." : " embedded references.")+" Run analysis for fresh results. The server input file is unchanged.", "good");
      if(options.importDeck){
        resetImportedModelMenus();
        state.studyNotes={text:"",history:[]};state.studySavedAt=null;state.studyCreatedAt=null;syncStudyNotes();
        selectLoadCase(data.load_cases?.[0]?.id||1);fitView();activateWorkspaceTab("analysis");
        workspaceUI.previousTab="analysis";
        log("New deck view reset: fitted isometric camera, default entity visibility, expanded menus and fresh analysis/sensitivity selections. Previous references and results are not attached to this model.","good");
      }
      if (!parametersOnly && !options.importDeck && !options.recent) await rememberStudy({name:file.name,text:studyText,source:"loaded"});
      return true;
    } catch (error) {
      staged?.rollback();
      if (commitStarted && previous) {
        state.importedDeck=previous.importedDeck;
        state.values = previous.values; state.data = previous.data;
        buildForm(state.schema, previous.values); state.loadCases = previous.loadCases;
        for (const [key,value,checked] of previous.fields) { const el=document.getElementById("p-"+key); if (el) { el.value=value; el.checked=checked; } }
        WingWorkspace.applyControls(document,previous.view.controls);
        if (previous.data) buildModel(previous.data,{preserveView:true}); else disposeModel();
        state.resultCases = previous.resultCases; state.results = previous.results;
        state.modelSignature = previous.signature; state.lastEditedSignature = previous.lastEditedSignature; state.autoMeshPending = previous.pending;
        state.lastTransfer = previous.transfer; restoreWorkspaceView(previous.view);
        state.fuelIsolation = previous.fuelIsolation; syncFuelControls();
        if (state.results) { state.contourIdx=previous.contourIdx; selectMode(previous.activeMode); applyContour(); }
        if (previous.selectedElement !== null) showElement(previous.selectedElement);
        if (previous.selectedNode !== null) showNode(previous.selectedNode);
        setModelDirty(previous.dirty);
      }
      throw error;
    } finally { state.buildingScene=wasBuilding; }
    } finally { state.studyRestoring = false; }
  },options.importDeck ? "Reading Nastran" : "Preparing Study file");
}

function newStudy() { return loadModelDefinition({name:"New Study"},{newStudy:true}); }
function loadTomlDefinition(file) { return loadModelDefinition(file,{toml:true}); }

function resetImportedModelMenus() {
  // This runs only after successful import/commit. Ordinary remeshing and
  // loading a saved Study keep their deliberate view and historical results.
  state.jobId=null;state.jobSignature=null;state.resultsLoadCaseIndependent=false;
  state.sensitivityResult=null;state.sensitivityMeta=null;state.sensitivitySignature=null;state.sensitivityJob=null;
  state.sensitivity?.resetModel(state.activeCase);
  state.sensitivityTables?.refresh();
  for(const [id,menu]of Object.entries(WORKSPACE_MENUS)){menu.current=menu.tabs.values().next().value;closeWorkspaceMenu(id);}
  refreshSensitivityMapCard();updateAnalysisValidity();
}

async function loadNastranSource(raw) {
  if(!workspaceOperationAvailable())throw Error("Finish the active mesh, solver or Study operation before reading another deck.");
  const request=typeof raw?.path==='string' ? {path:raw.path} : WingNastranImport.source(raw);
  const loaded=await loadModelDefinition({name:fileBasename(request.path || request.name)},{importDeck:true,importRequest:request});
  if(!loaded)throw Error(document.getElementById("model-error-text")?.textContent || "The deck could not be read. See Log for details.");
  return true;
}

function syncImportedModelMode(disabled=false) {
  const imported=state.importedDeck,info=document.getElementById("imported-deck-info");
  info.hidden=!imported;document.getElementById("form").hidden=!!imported;
  for(const panel of document.querySelectorAll('[data-imported-only]'))panel.hidden=!imported||panel.dataset.workspacePanel!==workspaceUI.activeTab;
  if(!state.importedCases&&typeof WingImportedCases!=='undefined')state.importedCases=WingImportedCases.create({
    casesHost:document.getElementById('imported-cases'),supportsHost:document.getElementById('imported-supports'),
    read:()=>({deck:state.importedDeck,data:state.data,caseId:state.activeCase}),selectCase:selectLoadCase,
    inspectNode:grid=>{const index=state.nodeIds?.indexOf(Number(grid));if(index>=0){activateWorkspaceTab('inspect');document.getElementById('inspect-entity').value='nodes';inspectFilterChanged();showNode(index);}},
    showSupports:()=>{setLayerVisible('SPC',true);buildLayerPanel();},
    showLoads:()=>{setLayerVisible('AERO_LOADS',true);setLayerVisible('AERO_MOMENTS',true);buildLayerPanel();},
  });
  state.importedCases?.refresh();
  if(!state.importedAnalysis)state.importedAnalysis=WingImportedAnalysis.create({host:document.getElementById('imported-analysis'),read:()=>state.importedDeck,onChange:analysis=>{
    state.importedDeck.source.analysis=analysis;state.modelSignature=formSignature();state.modelDirty=false;
    state.sensitivity?.refreshContext?.();markStudyModified();updateAnalysisValidity();
    log('Imported analysis changed to SOL'+WingImportedAnalysis.solution(state.importedDeck)+'. Run JFEM explicitly to calculate new results.');
  }});
  state.importedAnalysis.refresh(disabled);
  document.getElementById("auto-mesh").disabled=!!imported||disabled;
  for(const id of ["btn-create","btn-save","btn-save-toml","btn-view-toml","btn-open-plan-view"]){
    const button=document.getElementById(id);if(!button)continue;
    if(!button.dataset.generatedTitle)button.dataset.generatedTitle=button.title||"";
    button.disabled=!!imported||disabled;button.title=imported?"This action applies to generated wings. The imported deck is authoritative; use Write deck or Save Study to export it.":button.dataset.generatedTitle;
  }
  const analysisNote=document.querySelector('#panel-analysis-actions > .pick-note');
  if(analysisNote){analysisNote.dataset.generatedNote??=analysisNote.textContent;analysisNote.textContent=imported?'Choose the imported-deck solution below. Source geometry, properties, loads and supports are retained. Solver progress is shown in Log.':analysisNote.dataset.generatedNote;}
  if(imported){
    document.getElementById("imported-deck-title").textContent=imported.name+" · SOL"+imported.solution+" · "+(imported.cases?.length||1)+" cases · imported Nastran";
    const warnings=document.getElementById("imported-deck-warnings");warnings.replaceChildren();
    for(const warning of imported.warnings||[]){const item=document.createElement("li");item.textContent=warning;warnings.append(item);}
  }
}

function syncStudyNotes() {
  const input=document.getElementById("study-note"),history=document.getElementById("study-note-history"),status=document.getElementById("study-notes-saved");
  if(input)input.value=state.studyNotes?.text || "";
  if(status)status.textContent=(state.studySavedAt ? "Study saved "+new Date(state.studySavedAt).toLocaleString()+". " : "")+"Save Study records changed notes with their save time. Notes and history belong to the Study file; TOML stores model parameters.";
  if(history){history.replaceChildren();for(const entry of [...(state.studyNotes?.history || [])].reverse()){const item=document.createElement("li"),time=document.createElement("time");time.dateTime=entry.saved_at;time.textContent=new Date(entry.saved_at).toLocaleString();item.append(time,document.createTextNode(entry.text));history.append(item);}}
}

async function rememberStudy(record) {
  try {
    const info = await state.recentStudies?.record(record);
    if (info?.id) state.studyRecentId = info.id;
  } catch (error) { log("Study saved/loaded, but its recent entry could not be stored: " + error.message, "warn"); }
}

/* --- running JFEM -------------------------------------------------------- */

async function probeJfem() {
  try {
    const res = await fetch("/api/jfem_probe", { cache: "no-store" });
    const j = await res.json();
    if (j.found) {
      log("JFEM solver found at " + j.repo, "good");
    } else {
      log("JFEM solver not found; set the JFEM repository parameter to use " +
          "Run in JFEM", "warn");
    }
    return j.found;
  } catch (e) {
    return false;
  }
}

async function runJfem() {
  if (state.busy || state.exportBusy || state.polling || state.solverStarting || state.sensitivityBusy || state.loadingInput || state.meshRequestInFlight) return;
  cancelAutoMeshTimer();
  state.autoMeshPending = false;
  state.solverStarting = true;
  const token = activity()?.begin("Preparing JFEM analysis", {detail:state.importedDeck?'Using the imported Nastran model and writing its analysis deck…':"Building the model and writing solver inputs…"});
  let launched = false;
  try {
  // The results are indexed onto the current mesh, so regenerate first and
  // make sure what is on screen is what gets solved.
  if(state.data?.imported_deck&&!state.importedDeck)throw Error('Imported source identity is missing. Reopen the saved Study or read the deck again; wing generation has been prevented.');
  const built = state.importedDeck ? !!state.data : await createFEM({ forSolver: true, preserveView: true });
  if(state.importedDeck)log('Imported deck route: '+state.importedDeck.name+' · SOL'+WingImportedAnalysis.solution(state.importedDeck)+' · original geometry is reused; no wing meshing or aerodynamic calculation.');
  if (!built) return;
  if (state.modelDirty) {
    log("The parameters changed during generation; update the model before running JFEM.", "warn");
    return;
  }

  let params;
  try {
    params = collectParams();
  } catch (e) {
    log(e.message, "err");
    return;
  }

  setBusy(true);
  clearSensitivityMap();
  state.jobSignature = state.modelSignature;
  log("starting the JFEM run…");
  try {
    const res = await postParams("/api/run_jfem", params, token);
    if (!res.ok) {
      log("could not start the run: " + (await readError(res)), "err");
      setBusy(false);
      return;
    }
    const j = await res.json();
    if (j.deck_text !== undefined) showDeck(j.deck_text, j.deck, j.deck_metadata);
    state.jobId = j.job;
    const logDownload = document.getElementById("log-download");
    if (logDownload) { logDownload.href = "/api/jfem_log?job=" + encodeURIComponent(j.job); logDownload.hidden = false; }
    state.logCursor = 0;
    log("deck written: " + j.deck + " (" + j.deck_lines + " lines, " +
        j.solution + ")");
    log("solver: " + j.repo);
    log("running " + j.command);
    log("Log reports native deck parsing, assembly, constraints and solver progress. First-use package compilation can add time; solve time depends on model size and analysis.");
    document.getElementById("btn-stop-jfem").hidden = false;
    state.polling = true;
    solverActivity(true);
    state.solverStarting = false;
    launched = true;
    meshStatus(state.autoMeshPending ? "Model update queued until JFEM finishes" : "JFEM is running", "running");
    pollJfem();
  } catch (e) {
    log("could not start the run: " + e.message, "err");
    setBusy(false);
  }
  } finally {
    activity()?.end(token);
    state.solverStarting = false;
    if (!launched) { solverActivity(false); setBusy(false); }
  }
}

async function pollJfem() {
  if (!state.jobId || !state.polling) return;
  const jobId = state.jobId;
  let terminal = false;
  state.pollTimer = null;
  try {
    const res = await fetch("/api/jfem_status?job=" + encodeURIComponent(jobId) +
                            "&from=" + state.logCursor, { cache: "no-store" });
    if (state.jobId !== jobId || !state.polling) return;
    if (!res.ok) {
      throw new Error(await readError(res));
    }
    const j = await res.json();
    if (state.jobId !== jobId || !state.polling) return;
    state.logCursor = Number.isFinite(j.next_line) ? j.next_line : j.total_lines;
    if (j.omitted_lines > 0) log(j.omitted_lines.toLocaleString() + " older solver lines skipped in the live view; full output remains in " + j.log_path, "warn");
    logBatch((j.lines || []).map(ln => ln.trim()).filter(Boolean).map(t => ({ text: "  " + t,
      kind: /error|failed/i.test(t) ? "err" : /applied load|load target/i.test(t) ? "good" : "info" })));
    badge((j.state === "running" ? "JFEM is running" : "JFEM " + j.state) + "  " + j.seconds.toFixed(0) + " s",
          j.state === "running" ? "run" : (j.state === "done" ? "" : "bad"));
    solverActivity(j.state === "running", j.progress);

    if (j.state === "running" || j.has_more) {
      // Drain bounded batches without freezing a frame or racing the result
      // request. The terminal batch must be shown before loading results.
      state.pollTimer = setTimeout(pollJfem, j.has_more ? 150 : 700);
      return;
    }
    terminal = true;
    if (j.state !== "done") {
      log("JFEM " + j.state + ": " + (j.message || "see the log above"), j.state === "failed" ? "err" : "warn");
      log("full log: " + j.log_path);
      for (const run of j.runs || []) {
        log(run.case_label + " · SOL" + run.solution + ": " + run.state + (run.message ? " — " + run.message : ""), run.state === "done" ? "good" : "warn");
      }
      if (!j.results_available) { finishRun(false, j.state); return; }
    }
    log("JFEM finished in " + j.seconds.toFixed(1) + " s; reading available results…", "good");
    const loaded = await loadJfemResults();
    if (loaded !== false && typeof activateWorkspaceTab === "function") activateWorkspaceTab("results");
    finishRun(loaded !== false, j.state);
  } catch (e) {
    if (state.jobId !== jobId || !state.polling) return;
    if (terminal) {
      log("The solver finished, but its results could not be read: " + e.message, "err");
      finishRun(false);
      return;
    }
    // A disconnected status request does not prove the solver has stopped.
    // Keep model updates queued until the server confirms a terminal state.
    log("Waiting to reconnect to JFEM: " + e.message, "warn");
    meshStatus("Waiting for JFEM status; model updates remain queued", "pending");
    state.pollTimer = setTimeout(pollJfem, 2000);
  }
}

function finishRun(ok, outcome = "") {
  if (state.pollTimer !== null) clearTimeout(state.pollTimer);
  state.pollTimer = null;
  state.polling = false;
  solverActivity(false);
  meshStatus(state.modelDirty ? "Model changes are waiting" : "Model is up to date", state.modelDirty ? "stale" : "current");
  setBusy(false);
  document.getElementById("btn-stop-jfem").hidden = true;
  if (outcome && outcome !== "done") badge("JFEM " + outcome + (ok ? " · available results shown" : ""), "bad");
  else if (!ok) badge("JFEM failed", "bad");
}

async function stopJfem() {
  if (!state.jobId) return;
  try {
    await fetch("/api/jfem_stop?job=" + encodeURIComponent(state.jobId),
                { method: "POST" });
    log("asked the solver to stop", "warn");
  } catch (e) {
    log("could not stop the run: " + e.message, "err");
  }
}

async function loadJfemResults() {
  const token = activity()?.begin("Loading analysis results", {detail:"Reading solver output and building contours…"});
  try {
  const res = await fetch("/api/jfem_results?job=" + encodeURIComponent(state.jobId),
                          { cache: "no-store" });
  if (!res.ok) {
    log("could not read the results: " + (await readError(res)), "err");
    return false;
  }
  const buf = await res.arrayBuffer();
  const byteLength = buf.byteLength;
  const r = await decodePayload(buf);
  await paintActivity();

  const n = state.data ? state.data.nodes.count : 0;
  if (r.node_count !== n) {
    log("the results hold " + r.node_count + " nodes but the displayed mesh " +
        "has " + n + "; showing the numbers only", "warn");
  }

  state.resultsLoadCaseIndependent = r.load_case_independent===true;
  state.resultCases = new Map((r.load_cases && r.load_cases.length ? r.load_cases : [{ ...r, id: 1 }])
    .map((c) => {
      const record = decodeResultCase(c,r,state.jobSignature);
      if (c.variants?.length) {
        record.variants = new Map(c.variants.map(v => [v.id, decodeResultCase(v,r,state.jobSignature)]));
        record.defaultVariant = c.default_variant || (record.variants.has("sol106") ? "sol106" : "sol101");
        if (record.variants.get("sol106")?.convergence?.partial && record.variants.get("sol106")?.available)
          document.getElementById("compare-results").checked = true;
      }
      return [Number(c.id), record];
    }));
  // A SOL105 source may open on its static preload subcase; only its STATSUB
  // eigen subcases have completed result records in the native response.
  selectLoadCase(state.importedDeck&&!state.resultCases.has(state.activeCase) ? state.resultCases.keys().next().value : state.activeCase);
  const results = state.results || state.resultCases.values().next().value;

  log("results read: " + results.analysis +
      (results.modes.length ? ", " + results.modes.length + " modes" : "") +
      ", " + (byteLength / 1024).toFixed(0) + " kB", "good");
  log("solver output folder: " + results.outDir);
  return Array.from(state.resultCases.values()).some(record =>
    Array.from(record.variants?.values() || [record]).some(result => result.available !== false && result.matches && (result.static || result.modes.length)));
  } finally { activity()?.end(token); }
}

function decodeResultCase(payload,r,signature) {
  const n=state.data?.nodes.count||0;
  const resultNodes=payload.node_count??r.node_count;
  const vector=(bytes,label)=>{
    const values=asF32(bytes);
    if(values.length!==3*resultNodes||!values.every(Number.isFinite))
      throw Error("Invalid "+label+" in analysis results: expected "+(3*resultNodes)+" finite components, received "+values.length+". The result was not applied to the model.");
    return values;
  };
  // Both the response envelope and case must belong to this source. Checking
  // only one lets mixed/imported cases inherit the current generated signature.
  const importedSignatures=[r.imported_signature,payload.imported_signature].filter(value=>value!==undefined);
  const importedAnalyses=[r.imported_analysis,payload.imported_analysis].filter(value=>value!==undefined);
  const sourceMatches=state.importedDeck ? importedSignatures.length>0&&importedSignatures.every(value=>value===state.importedDeck.signature)&&(importedAnalyses.length?importedAnalyses:[undefined]).every(value=>WingImportedAnalysis.matches(value,state.importedDeck)) :
    importedSignatures.length===0&&[r.model_params,payload.model_params].filter(Boolean).every(params=>formSignature(params)===state.modelSignature);
  const expectedLoadVersion=state.data?.loads?.load_application_version;
  const resultLoadVersions=[r.load_application_version,payload.load_application_version].filter(value=>value!==undefined);
  // Missing or old generated-load metadata must not turn an earlier
  // incompressible baseline green. Geometry still permits historical viewing.
  // Imported decks have their own source identity and are unaffected by PG.
  const historicalLoads=!state.importedDeck&&!!expectedLoadVersion&&
    (!resultLoadVersions.length||resultLoadVersions.some(value=>value!==expectedLoadVersion));
  const results = {
    analysis: payload.analysis_type || r.analysis_type,
    signature,
    meshIdentity:signature===state.modelSignature?state.meshIdentity:null,
    variantId: payload.variant_id || (payload.id === "sol101" || payload.id === "sol106" ? payload.id : null),
    source:payload.source||r.source, historical:payload.historical===true||r.historical===true||historicalLoads,
    loadApplicationVersion:payload.load_application_version??r.load_application_version??null,
    variantLabel: payload.label || "",
    available: payload.available !== false,
    status: payload.status || "complete",
    message: (payload.message || "")+(historicalLoads?" Historical load formulation: rerun the analysis to use the current aerodynamic model and load application convention.":""),
    convergence: payload.convergence || null,
    loadScale: payload.load_scale ?? payload.convergence?.exported_load_scale ?? 1,
    followerLoading: payload.follower_loading || null,
    comparisonMethod: payload.comparison_method || null,
    reactions: payload.reactions && payload.reactions.available !== false && payload.available !== false ? {
      nodes: asI32(payload.reactions.nodes), forces: asF32(payload.reactions.forces),
      moments: payload.reactions.moments ? asF32(payload.reactions.moments) : null,
    } : null,
    modeKind: payload.mode_kind || r.mode_kind || "none",
    summary: payload.summary || [],
    report: payload.report_md || (payload.available === false ? payload.message || "No completed results are available for this analysis." : r.report_md || ""),
    outDir: payload.out_dir || r.out_dir,
    modes: [],
    static: null,
    contours: [],
    matches: r.node_count === n && (payload.node_count===undefined||payload.node_count===n) && signature === state.modelSignature && sourceMatches,
    elementResults: payload.available === false ? {} : payload.element_results || {},
    modelParams: payload.model_params || r.model_params || state.values,
  };

  for (const m of results.available ? payload.modes || [] : []) {
    results.modes.push({
      mode: m.mode,
      freq: m.freq_hz,
      loadFactor: m.load_factor,
      eigenvalue: m.eigenvalue,
      maxDisp: m.max_disp,
      meffX: m.meff_x, meffY: m.meff_y, meffZ: m.meff_z,
      shape: vector(m.shape,"mode "+m.mode+" translations"),
      // Rotations are axial vectors; the cyclic, right-handed model-to-view
      // permutation applies to them exactly as it does to translations.
      rotation: m.rotation ? permute(vector(m.rotation,"mode "+m.mode+" rotations")) : null,
    });
  }
  if (payload.static && results.available) {
    results.static = {
      disp: vector(payload.static.disp,"static translations"),
      rotation: payload.static.rotation ? permute(vector(payload.static.rotation,"static rotations")) : null,
      maxDisp: payload.static.max_disp,
    };
  }
  for (const c of results.available ? payload.contours || [] : []) {
    results.contours.push({
      name: c.name, unit: c.unit, min: c.min, max: c.max, domain: c.domain, note: c.note,
      values: asF32(c.values),
      location: c.location || "node",
      ids: c.ids ? asI32(c.ids) : null,
    });
  }

  for (const c of results.contours) {
    if (c.location === "element" && c.ids) c.byId = new Map(Array.from(c.ids, (id, i) => [id, c.values[i]]));
  }
  return results;
  }

/* --- Babylon scene ------------------------------------------------------- */

function viewportDisplayActions() {
  const change=(id,value)=>{const control=document.getElementById(id);if(!control)return;if(control.type==="checkbox")control.checked=value;else control.value=value;control.dispatchEvent(new Event("change",{bubbles:true}));};
  return [
    {id:"reference",icon:'<path d="m4 7 8-4 8 4v10l-8 4-8-4zm0 0 8 4 8-4M12 11v10"/>',
      read:()=>{const items=state.reference?.entries||[],on=items.some(entry=>entry.visible);return{label:"Reference",active:on,disabled:!items.length,title:!items.length?"Load a 3D reference in the Reference tab":on?"Hide all reference geometry":"Show all reference geometry"};},
      toggle:()=>state.reference?.setAllVisible(!state.reference.entries.some(entry=>entry.visible))},
    {id:"surfaces",icon:'<path d="m3 7 9-4 9 4-9 4zM3 7v10l9 4 9-4V7M12 11v10M5 9l14 7M5 13l10 5"/>',
      read:()=>{const solid=document.getElementById("surface-mode").value==="solid";return{label:solid?"Solid":"Translucent",active:solid,title:solid?"Structural surfaces are solid. Click for translucent surfaces.":"Structural surfaces are translucent. Click for solid surfaces."};},
      toggle:()=>change("surface-mode",document.getElementById("surface-mode").value==="solid"?"translucent":"solid")},
    {id:"beams",icon:'<path d="M5 3h14v4h-5v10h5v4H5v-4h5V7H5z"/>',
      read:()=>{const sections=document.getElementById("beam-style").value==="sections";return{label:sections?"Bars 3D":"Bars lines",active:sections,title:sections?"Explicit sections, or area-equivalent squares/circular rod approximations when the shape is unknown. Display only; I/J are unchanged. Click for lines.":"Bar centerlines. Click for explicit or area-equivalent 3D sections."};},
      toggle:()=>change("beam-style",document.getElementById("beam-style").value==="sections"?"lines":"sections")},
    ...[["ground","show-ground-plane","Ground",'<path d="m2 15 10-8 10 8-10 7zM6 12l12 6M10 9l12 6M6 18 16 10M10 21l10-8"/>'],["symmetry","show-symmetry-plane","Symmetry",'<path d="M12 2v20M3 7l6-3v16l-6-3zm18 0-6-3v16l6-3z"/>']].map(([id,control,label,icon])=>({id,icon,read:()=>({label,active:document.getElementById(control)?.checked===true,title:(document.getElementById(control)?.checked?"Hide ":"Show ")+label.toLowerCase()+" plane"}),toggle:()=>change(control,!document.getElementById(control).checked)})),
  ];
}

function initScene() {
  const canvas = document.getElementById("render");
  state.engine = new BABYLON.Engine(canvas, true, {
    preserveDrawingBuffer: true,
    stencil: true,
  });
  const scene = new BABYLON.Scene(state.engine);
  state.scene = scene;
  // The model uses x aft, y span, z up; Babylon is shown with y up, so the
  // axes are cycled on the way in. A cyclic permutation keeps the system
  // right handed, which keeps the element normals consistent.
  scene.useRightHandedSystem = true;
  let background = document.getElementById("background-color")?.value || "#0e131a";
  try { background = localStorage.getItem("wingfegen-background") || background; } catch (_) {}
  applyBackgroundColor(background, false);
  // Later VLM/helpers passes still obey opaque structural depth. Babylon
  // clears each rendering group's depth by default, which made rear geometry
  // appear through Solid skins even though their material was fully opaque.
  scene.setRenderingAutoClearDepthStencil(1, false);
  scene.setRenderingAutoClearDepthStencil(2, false);
  applyBarDepthPolicy();
  if(typeof WingTransparency!=="undefined")state.transparency=WingTransparency.create({
    BABYLON,scene,
    throughMeshes:()=>document.getElementById("show-bars-through")?.checked?state.barMeshes:[],
    onUnsupported:()=>log("This graphics device uses approximate transparency sorting; overlapping surfaces may change order while rotating. Solid display remains available.","warn"),
  });

  state.camera = new BABYLON.ArcRotateCamera(
    "cam", -Math.PI / 3, Math.PI / 3, 12, BABYLON.Vector3.Zero(), scene);
  state.camera.attachControl(canvas, true);
  state.camera.wheelDeltaPercentage = 0.02;
  // Pan sensitivity is recomputed in screen units after each fit/zoom, so
  // millimetre decks and metre wings respond to the same pointer gesture.
  state.camera.panningSensibility = 400 / 1.5;
  state.camera.useInputToRestoreState = false;
  // Reserve the middle button for node centering, without moving on drag.
  state.camera.inputs.attached.pointers.buttons = [0, 2];
  state.camera.minZ = 0.01;
  state.camera.lowerRadiusLimit = 0.05;
  state.camera.lowerBetaLimit = 0.001;
  let cameraStamp = "";
  state.camera.onViewMatrixChangedObservable.add(() => {
    const c = state.camera, stamp = [c.alpha,c.beta,c.radius,...c.target.asArray(),c.mode,c.orthoLeft,c.orthoRight,c.orthoTop,c.orthoBottom].join(",");
    const changed = cameraStamp && cameraStamp !== stamp; cameraStamp = stamp;
    if (changed && !state.busy && !state.buildingScene) markStudyViewModified();
  });
  if (typeof WingViewportTools !== "undefined") state.viewportTools = WingViewportTools.create({
    scene,camera:state.camera,engine:state.engine,host:document.getElementById("viewport-tools"),
    onView:(_name,alpha,beta)=>setView(alpha,beta),onChange:markStudyViewModified,
    onSaveSVG:saveViewportSVG,onExportError:error=>log("SVG export: "+error.message,"err"),
    displayActions: viewportDisplayActions(),
    translucency:{
      read:()=>({value:document.getElementById("surface-translucency").value,visible:document.getElementById("surface-mode").value==="translucent"}),
      change:value=>{const input=document.getElementById("surface-translucency");input.value=value;input.dispatchEvent(new Event("input",{bubbles:true}));},
    },
    ground: {
      read:()=>{const input=document.getElementById("ground-plane-z");return{value:input.value,error:input.validationMessage,visible:document.getElementById("show-ground-plane").checked,units:state.importedDeck?'source':'m'};},
      change:(value,commit)=>{const input=document.getElementById("ground-plane-z");input.value=value;input.dispatchEvent(new Event(commit?"change":"input",{bubbles:true}));},
    },
    inspection: {
      read: () => { const select=document.getElementById("inspect-entity");return {active:workspaceUI.activeTab==="inspect",value:select.value,options:Array.from(select.options,option=>({value:option.value,label:option.textContent,disabled:option.disabled}))}; },
      activate: () => activateWorkspaceTab("inspect"),
      select: value => { document.getElementById("inspect-entity").value=value;inspectFilterChanged();markStudyViewModified(); },
    },
  });

  if (typeof WingSceneLighting !== "undefined") state.sceneLighting = WingSceneLighting.create({
    BABYLON,scene,host:document.getElementById("scene-lighting-controls"),onChange:markStudyViewModified,
  });

  state.root = new BABYLON.TransformNode("model", scene);
  if (typeof WingGeometryTools !== "undefined") state.geometryTools = WingGeometryTools.create(BABYLON, {
    scene, camera: state.camera, engine: state.engine, canvas, getState: () => state,
    getPositions: currentPositions, visibleNodes: visibleNodeIndices, markerRadius,
    decodeFloat: asF32, groupIds, sections: typeof WingSections !== "undefined" ? WingSections : null,
    format: eng, onHelp: openHelp, clearSelection: clearInspection,
  });
  if (typeof WingAnnotations !== "undefined") {
    state.annotations = WingAnnotations.create({ scene, camera: state.camera, engine: state.engine, canvas,
      getState: () => state, getPositions: currentPositions });
  }
  if (typeof WingReference !== "undefined") {
    let referenceDefinition="[]";
    state.reference = WingReference.create({
      scene, camera: state.camera, engine: state.engine,
      host: document.getElementById("reference-panel"),
      onLog: (text, kind) => log(text, kind),
      onHelp: (title, paragraphs) => openHelp({ title, paragraphs }),
      onChange: reference => {
        const definition=JSON.stringify(reference.entries.map(entry=>[entry.id,entry.name,entry.units,entry.axis,reference.getTransform(entry)]));
        if(definition!==referenceDefinition){referenceDefinition=definition;markStudyModified();}else markStudyViewModified();
        state.viewportTools?.syncDisplay();
      },
    });
  }
  installPicking(canvas);

  scene.onBeforeRenderObservable.add(() => {
    syncCameraClipping();
    enforcePanelIsolation();
    syncHistoricalBaselineOverlays();
    suppressSensitivityOverlays();
    if (!state.results || state.activeMode < -1) return;
    if (!activeShape()) return;
    if (animating()) {
      state.phase += (state.engine.getDeltaTime() / 1000) * 2 * Math.PI * ANIMATION_HZ;
      applyDeformation();
    }
  });

  state.engine.runRenderLoop(() => { if (!state.buildingScene) scene.render(); });
  window.addEventListener("resize", () => state.engine.resize());
}

/** Model (x aft, y span, z up) to Babylon (x span, y up, z aft). */
function permute(xyz) {
  const n = xyz.length / 3;
  const out = new Float32Array(xyz.length);
  for (let i = 0; i < n; i++) {
    out[3 * i] = xyz[3 * i + 1];
    out[3 * i + 1] = xyz[3 * i + 2];
    out[3 * i + 2] = xyz[3 * i];
  }
  return out;
}

function vec(xyz, i) {
  return new BABYLON.Vector3(xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]);
}

function color3(hex) {
  return BABYLON.Color3.FromHexString(hex);
}

/** Lit surfaces retain palette RGB while their normals supply face contrast. */
function setSurfaceLighting(material, color) {
  material.disableLighting = false;
  material.diffuseColor = color.scale(.86);
  material.emissiveColor = color.scale(.035);
  material.specularColor = new BABYLON.Color3(.045, .045, .045);
  material.specularPower = 48;
}

function shellMaterial(name, hex, alpha) {
  const m = new BABYLON.StandardMaterial(name, state.scene);
  setSurfaceLighting(m, color3(hex));
  m.backFaceCulling = false;
  m.twoSidedLighting = true;
  m.alpha = alpha === undefined ? 1 : alpha;
  m.transparencyMode = m.alpha < 1 ? BABYLON.Material.MATERIAL_ALPHABLEND : BABYLON.Material.MATERIAL_OPAQUE;
  m.separateCullingPass = m.alpha < 1 && !state.transparency?.enabled;
  m.disableDepthWrite = false;
  return m;
}

function disposeModel() {
  state.fuelMassDisplay?.dispose(); state.fuelMassDisplay = null;
  state.ribDatums?.setVisible(false);
  state.supportGlyphs?.dispose(); state.supportGlyphs = null;
  state.aeroDisplay?.dispose(); state.aeroDisplay = null;
  state.geometryTools?.resetModel();
  disposeComparisonOverlay();
  for (const layer of state.layers.values()) {
    // Reverse order so instances go before the mesh they were cloned from.
    for (const mesh of layer.meshes.slice().reverse()) {
      if (!mesh.isDisposed()) mesh.dispose(false, true);
    }
  }
  state.layers.clear();
  if (state.selectionMesh) state.selectionMesh.dispose(false, true);
  state.selectionMesh = null;
  state.selectedElement = null;
  state.selectedNode = null;
  state.selectedCoordinate = null;
  state.elements.clear();
  document.getElementById("pick-card").hidden = true;
  state.deformable = [];
  state.markers = [];
  state.shellMeshes = [];
  state.barMeshes = [];
  state.baseline = null;
  state.deformed = null;
  state.scene.meshes.slice().forEach((m) => {
    if (m.name.startsWith("axis-")) m.dispose();
  });
}

function addLayer(name, label, color, count, meshes) {
  const vis = !DEFAULT_HIDDEN.has(name);
  state.layers.set(name, {
    label: label, color: color, count: count, meshes: meshes, visible: vis,
  });
  for (const m of meshes) m.setEnabled(vis);
}

function shellMesh(name, positions, conn, nodesPerElement, hex, alpha, deformable, group) {
  const ne = conn.length / nodesPerElement;
  // Every FE element owns its vertices. A CQUAD4 still has one constant
  // element result on both triangles, and adjacent elements never share it.
  const local = !!deformable;
  const vertexMap = local ? conn.slice() : null;
  const points = local ? new Float32Array(conn.length * 3) : positions.slice();
  if (local) {
    for (let v = 0; v < conn.length; v++) points.set(positions.subarray(3 * conn[v], 3 * conn[v] + 3), 3 * v);
  }
  const indicesPerElement = nodesPerElement === 3 ? 3 : 6;
  const idx = new Int32Array(ne * indicesPerElement);
  for (let e = 0; e < ne; e++) {
    const n = nodesPerElement * e, t = indicesPerElement * e;
    const a = local ? n : conn[n], b = local ? n + 1 : conn[n + 1], c = local ? n + 2 : conn[n + 2];
    idx[t] = a; idx[t + 1] = b; idx[t + 2] = c;
    if (nodesPerElement === 4) {
      idx[t + 3] = a; idx[t + 4] = c; idx[t + 5] = local ? n + 3 : conn[n + 3];
    }
  }
  const mesh = new BABYLON.Mesh(name, state.scene);
  const vd = new BABYLON.VertexData();
  vd.positions = points;
  vd.indices = idx;
  const normals = new Float32Array(points.length);
  BABYLON.VertexData.ComputeNormals(points, idx, normals, { useRightHandedSystem: state.scene.useRightHandedSystem });
  vd.normals = normals;
  // White vertex colours leave the material colour showing; a contour
  // overwrites them and the material is set to white so the colours show true.
  const colors = new Float32Array((points.length / 3) * 4).fill(1);
  vd.colors = colors;
  vd.applyToMesh(mesh, true);      // updatable: the shape follows the results
  // Color buffers carry RGB contours; material.alpha alone controls opacity.
  mesh.hasVertexAlpha = false;
  mesh.material = shellMaterial(name + "-mat", hex, alpha);
  // These indices use the right-hand normal convention, rather than the
  // inward winding of Babylon's built-in primitive builders in an RH scene.
  mesh.sideOrientation = state.scene.useRightHandedSystem ? BABYLON.Material.CounterClockWiseSideOrientation : BABYLON.Material.ClockWiseSideOrientation;
  mesh.baseColorHex = hex;
  mesh.translucentAlpha = alpha === undefined ? 0.55 : alpha;
  mesh.nodeMap = vertexMap;
  mesh.nodesPerElement = nodesPerElement;
  mesh.surfaceNormals = normals;
  mesh.surfaceIndices = idx;
  mesh.elementIds = group ? groupIds(group) : null;
  mesh.parent = state.root;
  mesh.isPickable = !!group;
  if (group) mesh.metadata = { feGroup: group, facesPerElement: nodesPerElement - 2 };
  if (deformable) {
    state.deformable.push({ mesh: mesh, map: vertexMap, buf: vd.positions });
    state.shellMeshes.push(mesh);
  }
  return mesh;
}

function lineMesh(name, positions, pairs, hex, alpha, deformable, colorable) {
  if (!pairs.length) return null;
  // Allocate typed buffers directly. CreateLineSystem materializes two
  // Vector3 objects per edge and millions of temporary JS arrays on a deck.
  const mesh = new BABYLON.LinesMesh(name,state.scene,null,undefined,false,!!colorable,false);
  const vd=new BABYLON.VertexData(),points=new Float32Array(pairs.length*3),indices=new Int32Array(pairs.length);
  for(let i=0;i<pairs.length;i++){const k=3*pairs[i];points[3*i]=positions[k];points[3*i+1]=positions[k+1];points[3*i+2]=positions[k+2];indices[i]=i;}
  vd.positions=points;vd.indices=indices;
  if (colorable) {
    const color=color3(hex),colors=new Float32Array(pairs.length*4);
    for(let i=0;i<pairs.length;i++)colors.set([color.r,color.g,color.b,1],i*4);
    vd.colors=colors;
  }
  vd.applyToMesh(mesh,true);
  mesh.color = colorable ? BABYLON.Color3.White() : color3(hex);
  mesh.baseColorHex = hex;
  // A LinesMesh blends as soon as its alpha drops below one.
  if (alpha !== undefined) mesh.alpha = alpha;
  mesh.parent = state.root;
  mesh.isPickable = false;
  if (deformable) {
    // CreateLineSystem lays vertices out line by line, two per line, so the
    // node index of vertex v is simply pairs[v].
    state.deformable.push({
      mesh: mesh, map: pairs, buf: new Float32Array(pairs.length * 3),
    });
  }
  return mesh;
}

function barSectionMesh(group, positions, conn, hex, reference) {
  if (typeof WingSections === "undefined") return null;
  const section = WingSections.displaySection(group.properties?.section,/C(?:ON)?ROD/.test(group.name));
  if (!section) return null;
  const orientation = group.orient ? permute(asF32(group.orient)) :
    group.axes && group.axes.y ? permute(asF32(group.axes.y)) : null;
  if (!orientation) return null;
  let mesh;
  try {
    mesh = WingSections.createMesh(BABYLON, {
      name: group.name + (reference ? "-reference-sections" : "-sections"),
      scene: state.scene, positions, conn, orientations: orientation, section,
    });
  } catch (error) {
    if (!/Degenerate CBAR frame in section display/.test(error.message)) throw error;
    // A failed display frame must not discard already built skins or block
    // analysis. Keep this group's original centerlines and section metadata;
    // the native solver still validates the unchanged source coordinates.
    if (!reference) log("Section display for " + group.name + " uses beam lines: " + error.message +
      ". No FE coordinates or properties were changed; inspect this beam group if solver validation also reports a problem.", "warn");
    return null;
  }
  mesh.material = shellMaterial(mesh.name + "-mat", "#ffffff", reference ? 0.25 : 1);
  // PBARL sections are closed solids with outward normals. Unlike an open
  // shell midsurface their underside must not flip toward the viewing eye.
  mesh.material.twoSidedLighting = false;
  mesh.sideOrientation = BABYLON.Material.CounterClockWiseSideOrientation;
  mesh.baseColorHex = hex;
  mesh.parent = state.root;
  mesh.elementIds = groupIds(group);
  mesh.isPickable = !reference;
  mesh.metadata = reference ? null : { feGroup: group, faceElements: mesh.sectionGeometry.faceElements };
  mesh.renderingGroupId = reference ? 1 : BAR_RENDER_GROUP;
  if (reference) {
    setSurfaceLighting(mesh.material, color3(hex));
  } else {
    state.deformable.push({ mesh, barSection: true });
    state.barMeshes.push(mesh);
  }
  return mesh;
}

/** Select a bar representation without changing the structural layer switch. */
function applyBeamStyle() {
  const control = document.getElementById("beam-style");
  const sections = control && control.value === "sections";
  if(control)control.title="Explicit PBARL shapes are preserved. Unknown sections use area-equivalent squares, or circular approximations for rods; I/J and the analysis are unchanged.";
  const visited=new Set();let created=false;
  for (const layer of state.layers.values()) {
    for (const mesh of layer.meshes) {
      if(visited.has(mesh))continue;visited.add(mesh);
      if(mesh.importedRanges)WingImportedRender.sync(mesh,state.layers);
      if (!mesh.barRepresentation) continue;
      const visible=mesh.importedRanges?mesh.isEnabled():layer.visible;
      if(sections&&visible&&mesh.createSolid){const make=mesh.createSolid;mesh.createSolid=null;const solid=make();mesh.hasSectionShape=!!solid;created=created||!!solid;}
      const active = mesh.barRepresentation === "sections" ? sections : !sections || !mesh.hasSectionShape;
      mesh.setEnabled(visible && active);
    }
  }
  syncComparisonVisibility();
  applyShellGeometry(true);
  if(created)applyContour();
  state.viewportTools?.syncDisplay();
}

function importedRepresentation(mesh,group) {
  if(!mesh||!group.sourceRanges)return;
  mesh.importedRanges=group.sourceRanges.map(range=>({...range}));
  mesh.importedIndicesPerElement=mesh.sectionGeometry?.verticesPerElement||mesh.shellThicknessGeometry?.verticesPerElement||(group.kind==="quad"?6:group.kind==="tria"?3:2);
}

function prepareBarSolid(line,peers,group,positions,conn,color,reference) {
  if(!line||typeof WingSections==="undefined")return;
  const section=WingSections.displaySection(group.properties?.section,/C(?:ON)?ROD/.test(group.name));
  if(!section?.equivalent)return;
  line.hasSectionShape=true;
  line.createSolid=()=>{
    const solid=barSectionMesh(group,positions,conn,color,reference);if(!solid)return null;
    importedRepresentation(solid,reference?{}:group);peers.push(solid);
    if(!reference){const shape=activeShape();WingSections.updateMesh(BABYLON,solid,currentPositions(),shape?.rotation,amplitude()*(animating()?Math.sin(state.phase):1));state.panelExplosion?.applyMesh(solid);}
    return solid;
  };
}

function prepareShellThickness(surface,peers,group,positions,conn,stride,color,alpha) {
  surface.shellRepresentation="midsurface";
  const bounds=globalThis.WingShellThickness?.boundsForGroup(group);
  surface.hasPhysicalThickness=!!bounds;
  if(!bounds)return;
  surface.createThickness=()=>{
    const mesh=WingShellThickness.createMesh(BABYLON,{name:group.name+"-thickness",scene:state.scene,positions,conn,nodesPerElement:stride,bounds});
    mesh.material=shellMaterial(mesh.name+"-mat",color,alpha);mesh.material.twoSidedLighting=false;
    mesh.sideOrientation=BABYLON.Material.CounterClockWiseSideOrientation;
    mesh.parent=state.root;mesh.isPickable=true;mesh.elementIds=groupIds(group);mesh.baseColorHex=color;mesh.translucentAlpha=alpha;
    mesh.nodesPerElement=mesh.shellThicknessGeometry.verticesPerElement;mesh.contourNodeMap=conn;mesh.contourNodesPerElement=stride;
    mesh.shellRepresentation="thickness";mesh.metadata={feGroup:group,faceElements:mesh.shellThicknessGeometry.faceElements};
    mesh.fallbackElements=surface.fallbackElements;importedRepresentation(mesh,group);
    peers.push(mesh);state.shellMeshes.push(mesh);state.deformable.push({mesh,shellThickness:true});
    WingShellThickness.updateMesh(BABYLON,mesh,currentPositions());state.panelExplosion?.applyMesh(mesh);return mesh;
  };
}

function applyShellGeometry(fromBeamStyle=false) {
  const thick=document.getElementById("shell-geometry")?.value==="thickness",visited=new Set();let created=false;
  for(const layer of state.layers.values())for(const mesh of layer.meshes){
    if(visited.has(mesh)||!mesh.shellRepresentation)continue;visited.add(mesh);
    if(mesh.importedRanges)WingImportedRender.sync(mesh,state.layers);
    const visible=mesh.importedRanges?mesh.isEnabled():layer.visible;
    if(thick&&visible&&mesh.createThickness){const make=mesh.createThickness;mesh.createThickness=null;created=!!make()||created;}
    const selected=mesh.shellRepresentation==="thickness"?thick:!thick||!mesh.hasPhysicalThickness;
    mesh.setEnabled(visible&&selected);
  }
  const note=document.getElementById("shell-geometry-note");
  if(note){const unavailable=thick?(state.data?.groups||[]).filter(g=>["quad","tria"].includes(g.kind)&&(!(g.properties?.thickness_m>0)||!Number.isFinite(g.properties?.thickness_m)||g.properties?.thickness_display_supported===false)).reduce((n,g)=>n+g.count,0):0;
    note.textContent="Display geometry only: midsurfaces retain the FE reference plane; physical thickness uses each property’s T and the laminate Z0 where available. Nodal coordinates, properties and analysis are unchanged."+(state.importedDeck?" Imported shell element offsets and corner-thickness overrides are not represented.":"")+(unavailable?" "+unavailable+" shells remain midsurfaces because thickness display data are unavailable.":"");}
  if(created||!fromBeamStyle){applySurfaceMode();applyContour();}
  state.annotations?.invalidate();
}

function markerMesh(name, positions, nodes, hex, radius) {
  if (!nodes.length) return null;
  const mat = new BABYLON.StandardMaterial(name + "-mat", state.scene);
  mat.diffuseColor = color3(hex);
  mat.emissiveColor = color3(hex).scale(0.55);
  mat.specularColor = new BABYLON.Color3(0.1, 0.1, 0.1);
  const proto = BABYLON.MeshBuilder.CreateSphere(
    name, { diameter: 2 * radius, segments: 6 }, state.scene);
  proto.material = mat;
  proto.parent = state.root;
  proto.isPickable = false;
  proto.position = vec(positions, nodes[0]);
  state.markers.push({ mesh: proto, node: nodes[0], kind: name, originalRadius: radius });
  const all = [proto];
  for (let i = 1; i < nodes.length; i++) {
    const inst = proto.createInstance(name + "-" + i);
    inst.position = vec(positions, nodes[i]);
    inst.parent = state.root;
    inst.isPickable = false;
    state.markers.push({ mesh: inst, node: nodes[i], kind: name, originalRadius: radius });
    all.push(inst);
  }
  return all;
}

/** Unique element edges of every shell group, for the FE wireframe. */
function shellEdgePairs(groups) {
  const seen = new Set();
  const pairs = [];
  for (const g of groups) {
    if (g.kind !== "quad" && g.kind !== "tria") continue;
    const stride = g.n_per_elem || (g.kind === "tria" ? 3 : 4);
    const conn = asI32(g.conn);
    for (let e = 0; e < conn.length / stride; e++) {
      for (let t = 0; t < stride; t++) {
        const a = conn[stride * e + t];
        const b = conn[stride * e + ((t + 1) % stride)];
        const key = a < b ? a + ":" + b : b + ":" + a;
        if (seen.has(key)) continue;
        seen.add(key);
        pairs.push(a, b);
      }
    }
  }
  return new Int32Array(pairs);
}

function addAxes(diag) {
  const L = 0.12 * diag;
  // Drawn in model axes, then permuted like everything else.
  const defs = [
    ["axis-x", [L, 0, 0], "#ef5f6b"],   // x aft
    ["axis-y", [0, L, 0], "#4cc38a"],   // y span
    ["axis-z", [0, 0, L], "#56a8f5"],   // z up
  ];
  for (const [name, v, hex] of defs) {
    const p = permute(new Float32Array([0, 0, 0, v[0], v[1], v[2]]));
    const m = BABYLON.MeshBuilder.CreateLines(
      name, { points: [vec(p, 0), vec(p, 1)] }, state.scene);
    m.color = color3(hex);
    m.isPickable = false;
  }
}

function buildModel(data, options = {}) {
  for (const unused of buildModelSteps(data, options)) { /* synchronous path for restoration/tests */ }
}

function resultMeshIdentity(data) {
  return JSON.stringify([Array.from(asI32(data.nodes.ids)),Array.from(asF32(data.nodes.xyz)),
    data.groups.map(g=>[g.kind,g.pid,Array.from(asI32(g.eids)),Array.from(asI32(g.conn))])]);
}

function* buildModelSteps(data, options = {}) {
  // Babylon material setters scan the scene's submeshes for invalidation.
  // Repeating that for every property during construction is quadratic even
  // though the meshes have never been drawn. Invalidate once when all buffers
  // and appearance settings are ready; restore the prior mode on failure too.
  const wasMaterialBatch=state.scene.blockMaterialDirtyMechanism;
  state.scene.blockMaterialDirtyMechanism=true;
  try {
  yield "Preparing viewport geometry…";
  if(data.imported_buffers)WingImportedRender.expand(data);
  const restorePanels=document.getElementById("show-panels").checked;
  if(state.panelView)setPanelDisplay(false,false);
  if (!options.preserveView || options.resetIsolation) state.fuelIsolation = null;
  if (state.fuelIsolation && !data.fuel?.enabled) {
    const saved = state.fuelIsolation; state.fuelIsolation = null;
    for (const [name, visible] of saved) setLayerVisible(name, visible);
  }
  const savedView = options.preserveView && state.baseline ? {
    layers: new Map(Array.from(state.layers, ([name, layer]) => [name, layer.visible])),
    activeCase: state.activeCase,
  } : null;
  const retainedResults=!options.resetIsolation&&state.resultCases?.size?{
    cases:state.resultCases,caseId:state.activeCase,variant:state.resultVariantPreference,independent:state.resultsLoadCaseIndependent}:null;
  disposeModel();
  clearResults();
  state.meshIdentity=resultMeshIdentity(data);
  state.propertyDisplay?.refresh(data);
  state.activeCase = Number(data.load_cases?.[0]?.id)||1;
  document.getElementById("axes-note").hidden = true;
  document.getElementById("splash").classList.add("hidden");

  const positions = permute(asF32(data.nodes.xyz));
  state.nodeIds = asI32(data.nodes.ids);
  state.baseline = positions;
  state.deformed = new Float32Array(positions.length);
  const bb = WingImportedRender.bounds(data);
  const diag = Math.hypot(bb.max[0] - bb.min[0],
                          bb.max[1] - bb.min[1],
                          bb.max[2] - bb.min[2]) || 1;
  state.bbox = bb;
  state.diag = diag;
  state.panelIndex=WingStiffenedPanels.index(data);
  const panelToggle=document.getElementById("show-panels");panelToggle.disabled=!state.panelIndex.panels.length;
  document.getElementById("stiffened-panel-note").textContent=state.panelIndex.panels.length?
    state.panelIndex.panels.length+" panels; each P label matches the panel property tables. Each color joins a normal stringer segment with its skin. Shell and beam visibility is controlled by Panels while it is on; all other entity controls remain available. "+(data.stiffened_panels.coverage?.unassigned_shells||0)+" shells have no normal stringer and remain outside the panels.":"No stiffened panels: this mesh has no normal stringer segments between ribs.";
  updateViewPlanes(data);

  // Structural element groups.
  const fallbackByElement=new Map();
  for(const rib of data.leading_edge?.ribs || []) if(rib.fallback) for(const eid of rib.eids || []) fallbackByElement.set(eid,rib);
  const renderGroups=data.imported_deck&&typeof WingImportedRender!=="undefined"?WingImportedRender.batches(data.groups,asI32,asF32):data.groups;
  for (const g of renderGroups) {
    yield "Drawing " + g.name.toLowerCase().replaceAll("_", " ") + "…";
    const style = GROUP_STYLE[g.base_group || g.name] || { color: "#9aa6b2", alpha: 0.9 };
    const conn = asI32(g.conn);
    const ids = groupIds(g);
    const stride = g.n_per_elem || (g.kind === "tria" ? 3 : g.kind === "quad" ? 4 : 2);
    let rangeIndex=0;
    for (let e = 0; e < ids.length; e++) {
      while(g.sourceRanges&&e>=g.sourceRanges[rangeIndex].start+g.sourceRanges[rangeIndex].count)rangeIndex++;
      state.elements.set(ids[e], { id: ids[e], group: g.sourceRanges?.[rangeIndex].group||g, nodes: conn.slice(e * stride, (e + 1) * stride), leadingEdgeFallback:fallbackByElement.get(ids[e]) });
    }
    const family=state.importedDeck?0:Math.floor(g.pid/1000000),physical=g.pid%1000000;
    const label = g.panel_id!=null ? (state.panelIndex.byId.get(g.panel_id)?.label||"Panel "+g.panel_id)+" · "+(g.kind==="bar"?"stringer":"skin") : family ? (g.base_group||g.name).replace(/_/g," ").toLowerCase()+" · "+(family<=2?"R ":"bay ")+physical : g.name.replace(/_/g, " ").toLowerCase();
    if (g.kind === "quad" || g.kind === "tria") {
      const stride = g.n_per_elem || (g.kind === "tria" ? 3 : 4);
      const mesh = shellMesh(g.name, positions, conn, stride,
                             style.color, style.alpha, true, g);
      mesh.fallbackElements=ids.map(id=>fallbackByElement.has(id)?1:0);
      const warnings=[];
      for(let e=0;e<ids.length;e++) if(mesh.fallbackElements[e]) for(let k=0;k<stride;k++) warnings.push(conn[e*stride+k],conn[e*stride+(k+1)%stride]);
      const warning=lineMesh(g.name+"-flight-fallback",positions,Int32Array.from(warnings),"#ff323d",1,true);
      if(warning){
        warning.metadata={wingViewHelper:true,leadingEdgeFallback:true};
        warning.renderingGroupId=2;
        warning.material.depthFunction=BABYLON.Constants.ALWAYS;
        warning.material.disableDepthWrite=true;
      }
      const peers=[mesh,warning].filter(Boolean);
      prepareShellThickness(mesh,peers,g,positions,conn,stride,style.color,style.alpha);
      addLayer(g.name, label, style.color,
               g.count + (stride === 3 ? " triangles" : " quads"), peers);
    } else {
      const mesh = lineMesh(g.name, positions, conn, style.color, undefined, true, true);
      const physical=!!g.properties?.section?.polygon_yz_m;
      const solid = physical?barSectionMesh(g, positions, conn, style.color, false):null;
      if (mesh) {
        mesh.isPickable = true;
        mesh.intersectionThreshold = 0.004 * diag;
        mesh.metadata = { feGroup: g, facesPerElement: 1 };
        mesh.elementIds = ids;
        mesh.barRepresentation = "lines";
        mesh.hasSectionShape = !!solid;
        state.barMeshes.push(mesh);
      }
      if (mesh && isForegroundBar(g)) mesh.renderingGroupId = BAR_RENDER_GROUP;
      const peers=[mesh,solid].filter(Boolean);prepareBarSolid(mesh,peers,g,positions,conn,style.color,false);
      addLayer(g.name, label, style.color, g.count + " bars",peers);
    }
    if(g.sourceRanges){
      const batch=state.layers.get(g.name);state.layers.delete(g.name);
      for(const mesh of batch.meshes)importedRepresentation(mesh,g);
      for(const range of g.sourceRanges)addLayer(range.group.name,range.group.name.replaceAll("_"," ").toLowerCase(),style.color,range.count+(g.kind==="bar"?" bars":" shells"),batch.meshes);
    }
  }

  // Element edges of the shells, drawn as the FE wireframe.
  yield "Building mesh edges and undeformed overlay…";
  const edges = shellEdgePairs(data.groups);
  const ghost = lineMesh("UNDEFORMED", positions, edges, "#c5d1df", 0.42, false);
  const referenceMeshes = ghost ? [ghost] : [];
  for (const g of renderGroups) {
    if (g.kind !== "bar") continue;
    const conn = asI32(g.conn);
    const lines = lineMesh(g.name + "-reference", positions, conn, "#c5d1df", 0.42, false);
    const solid = g.properties?.section?.polygon_yz_m?barSectionMesh(g, positions, conn, "#c5d1df", true):null;
    if (lines) { lines.barRepresentation = "lines"; lines.hasSectionShape = !!solid; referenceMeshes.push(lines); }
    if (solid) referenceMeshes.push(solid);
    prepareBarSolid(lines,referenceMeshes,g,positions,conn,"#c5d1df",true);
  }
  addLayer("UNDEFORMED", "Undeformed model", "#c5d1df", "reference", referenceMeshes);
  addLayer("NODES", EXTRA_STYLE.NODES.label, EXTRA_STYLE.NODES.color, data.nodes.n_structural + " nodes", []);
  const edgeMesh = lineMesh("MESH_EDGES", positions, edges,
                            EXTRA_STYLE.MESH_EDGES.color, 1, true);
  if(edgeMesh){edgeMesh.renderingGroupId=1;edgeMesh.material.zOffset=-1;}
  addLayer("MESH_EDGES", EXTRA_STYLE.MESH_EDGES.label,
           EXTRA_STYLE.MESH_EDGES.color, (edges.length / 2) + " edges",
           edgeMesh ? [edgeMesh] : []);
  state.edgeVisibilityKey=null;

  // RBE3 spiders and their reference nodes.
  yield "Building load attachments and support markers…";
  const attachmentLoads = WingGeometryExport.loadsByNode(WingGeometryExport.loadStations(data.loads));
  for(const [attachments,layerName,nodeLayerName] of [[data.rbe3,"RBE3","RBE3_NODES"],[data.fuel_rbe3,"FUEL_RBE3","FUEL_RBE3_NODES"]]) {
    if(!attachments?.count)continue;
    const lines = asI32(attachments.lines);
    const spider = lineMesh(layerName, positions, lines,
                            EXTRA_STYLE[layerName].color, 0.5, true);
    if (spider && attachments.elements && attachments.eids) {
      const ids = asI32(attachments.eids);
      const gridIndex = new Map(Array.from(state.nodeIds, (id, i) => [id, i]));
      const faceElements = [];
      attachments.elements.forEach((sp, index) => {
        const nodes = [sp.ref, ...sp.connected_grids.map((id) => gridIndex.get(id))];
        const applied = attachmentLoads.get(sp.ref);
        const properties = { ...sp };
        if (applied) {
          properties.applied_force_N = applied.force;
          if(applied.source_forces_N)properties.source_forces_N=applied.source_forces_N;
          properties.applied_moment_Nm = applied.moment;
          if(applied.source_moments_Nm)properties.source_moments_Nm=applied.source_moments_Nm;
          if(data.loads?.moment_routing_note)properties.moment_routing_note=data.loads.moment_routing_note;
        }
        const group = { name: layerName, kind: "rbe3", properties };
        state.elements.set(sp.eid, { id: sp.eid, group, nodes: Int32Array.from(nodes) });
        for (let i = 1; i < nodes.length; i++) faceElements.push(index);
      });
      spider.metadata = { feGroup: { name: layerName, kind: "rbe3" }, faceElements, facesPerElement: 1 };
      spider.elementIds = ids;
      spider.isPickable = true;
      spider.intersectionThreshold = 0.003 * diag;
    }
    addLayer(layerName, EXTRA_STYLE[layerName].label, EXTRA_STYLE[layerName].color,
             attachments.count + " elements", spider ? [spider] : []);
    const refs = Array.from(asI32(attachments.refs));
    const marks = markerMesh(nodeLayerName, positions, refs,
                             EXTRA_STYLE[nodeLayerName].color, Math.max(markerRadius(), diag * 1e-8));
    addLayer(nodeLayerName, EXTRA_STYLE[nodeLayerName].label,
             EXTRA_STYLE[nodeLayerName].color, refs.length + " nodes",
             marks || []);
  }

  if(typeof WingModelEntities!=='undefined'){
    WingModelEntities.renderConnections({data,state,positions,lineMesh,markerMesh,markerRadius,addLayer,diag});
    const systems=data.coordinate_systems?.systems||[];
    if(systems.length)addLayer('COORDINATE_SYSTEMS','Coordinate systems · global positions',WingModelEntities.COLORS.coordinate,
      systems.length+' frames',[]);
  }

  // Generated supports or the imported subcase's effective SPC selection.
  refreshSupportLayer(data,positions);

  // Aerodynamic surface. It has its own node set, so Julia sends structural
  yield "Building aerodynamic surfaces…";
  // attachment nodes and weights that let it follow a deformed shape.
  if (data.aero.count > 0) {
    const apos = permute(asF32(data.aero.xyz));
    const aconn = asI32(data.aero.conn);
    const mesh = shellMesh("AERO_SURFACE", apos, aconn, 4,
                          EXTRA_STYLE.AERO_SURFACE.color,
                          EXTRA_STYLE.AERO_SURFACE.alpha, false);
    if (data.aero.map && data.aero.weights) {
      state.deformable.push({
        mesh: mesh,
        aero: true,
        map: asI32(data.aero.map),
        weights: asF32(data.aero.weights),
        nodesPerPoint: data.aero.n_per_node || 4,
        rotationLever: data.aero.rotation_lever_m ? permute(asF32(data.aero.rotation_lever_m)) : null,
        base: apos,
        buf: apos.slice(),
      });
    }
    addLayer("AERO_SURFACE", EXTRA_STYLE.AERO_SURFACE.label,
             EXTRA_STYLE.AERO_SURFACE.color, data.aero.count + " quads",
             [mesh]);
    const reference = shellMesh("REFERENCE_AERO", apos, aconn, 4, "#c5d1df", 0.14, false);
    reference.material.wireframe = false;
    addLayer("REFERENCE_AERO", "Undeformed aero · translucent", "#c5d1df", "reference", [reference]);
  }

  if(typeof WingAeroDisplay !== "undefined") {
    state.aeroDisplay=WingAeroDisplay.create({scene:state.scene,parent:state.root,data});
    if(state.aeroDisplay.count) addLayer("AIRFOIL_SECTIONS","Defined airfoils · wireframes",WingAeroDisplay.SECTION_COLOR,
      state.aeroDisplay.count+" sections",state.aeroDisplay.meshes);
  }
  state.panelExplosion ??= WingPanelExplode.create();
  state.panelExplosion.configure(state.panelIndex,state.elements,state.baseline,data.rib_layout);
  syncPanelExplosionControls();
  addAxes(diag);
  yield "Drawing fuel tank…";
  addFuelTank(data.fuel);
  if(typeof WingMassProperties!=="undefined") state.fuelMassDisplay=WingMassProperties.create({BABYLON,scene:state.scene,parent:state.root,data});
  refreshFuelMassProperties();
  syncRibDatums(data);
  yield "Building element axes and aerodynamic loads…";
  yield* elementAxesSteps(data.groups);
  refreshLoadLayers();
  buildCaseSelectors();
  yield "Finalizing display and reports…";
  buildLayerPanel();
  applySurfaceMode();
  applyContour();
  applyBeamStyle();
  updateMarkerRadii();
  syncResultOverlays();
  if (savedView) {
    if (savedView.activeCase !== state.activeCase) selectLoadCase(savedView.activeCase);
    batchLayerVisibility(()=>{for (const [name, visible] of savedView.layers) setLayerVisible(name, visible);});
    // Building meshes never changes the camera; omit fitView so ongoing
    // orbit/pan/zoom gestures and a user-selected node center stay untouched.
    if (state.camera) state.camera.maxZ = Math.max(state.camera.maxZ, state.diag * 100);
  } else fitView();
  enforceFuelIsolation();
  refreshWeights(data);
  state.supportEditor?.refresh?.();
  for(const editor of state.componentEditors||[])editor.refresh();
  syncLeadingEdgeFallbackNotice();
  state.panelTables?.refresh();
  if(retainedResults){
    state.resultCases=retainedResults.cases;state.resultsLoadCaseIndependent=retainedResults.independent;
    state.resultVariantPreference=retainedResults.variant;
    for(const record of state.resultCases.values())for(const result of [record,...(record.variants?.values()||[])])
      result.matches=!!result.meshIdentity&&result.meshIdentity===state.meshIdentity;
    selectLoadCase(retainedResults.caseId);
  }
  if(restorePanels&&state.panelIndex.panels.length)setPanelDisplay(true);
  refreshPanelExplosion();
  } finally { state.scene.blockMaterialDirtyMechanism=wasMaterialBatch; }
}

function syncPanelExplosionControls(){
  const settings=state.panelExplosion?.capture()||WingPanelExplode.normalize();
  document.getElementById("explode-panels").checked=settings.enabled;
  document.getElementById("explode-panels").disabled=!state.panelIndex?.panels.length;
  document.getElementById("explode-origin").value=settings.origin;
  document.getElementById("explode-distance").value=settings.distance;
  const slider=document.getElementById("explode-slider"),limit=Math.min(10000,Math.max(1,(state.diag||20)*.5,settings.distance));
  slider.max=limit;slider.step="any";slider.value=settings.distance;slider.disabled=!state.panelIndex?.panels.length;
  slider.setAttribute("aria-valuetext",eng(settings.distance,4)+" metres");
}
function applyPanelMeshOffsets(){
  if(!state.panelExplosion)return;
  for(const mesh of [...state.shellMeshes,...state.barMeshes,...(state.layers.get("MESH_EDGES")?.meshes||[])])state.panelExplosion.applyMesh(mesh);
}
function refreshPanelExplosion(){
  if(!state.baseline)return;
  syncMeshEdges();
  applyPanelMeshOffsets();
  if(activeShape())applyDeformation();else restoreBaseline();
  state.annotations?.invalidate();
}
function editPanelExplosion(){
  const error=document.getElementById("explode-error");
  try{
    state.panelExplosion ??= WingPanelExplode.create();
    const text=document.getElementById("explode-distance").value.trim();
    state.panelExplosion.restore({enabled:document.getElementById("explode-panels").checked,origin:document.getElementById("explode-origin").value,distance:text===""?NaN:Number(text)});
    syncPanelExplosionControls();refreshPanelExplosion();error.hidden=true;markStudyViewModified();
  }catch(problem){error.textContent=problem.message;error.hidden=false;}
}
for(const id of ["explode-panels","explode-origin","explode-distance"])document.getElementById(id).addEventListener("change",()=>editPanelExplosion());
let pendingPanelExplosion=null;
document.getElementById("explode-slider").oninput=event=>{
  document.getElementById("explode-distance").value=event.target.value;document.getElementById("explode-panels").checked=true;
  if(pendingPanelExplosion===null)pendingPanelExplosion=requestAnimationFrame(()=>{pendingPanelExplosion=null;editPanelExplosion();});
};

function setPanelDisplay(enabled,redraw=true){
  enabled=!!enabled&&!!state.panelIndex?.panels.length;
  if(enabled&&!state.panelView){
    // Restore the underlying model before taking another isolation snapshot.
    // Otherwise a tank-only view becomes the saved state and hides skins again
    // when panel coloring is later replaced by sensitivity or FE results.
    restoreFuelIsolation();
    state.propertyDisplay?.setEnabled(false);
    clearSensitivityMap();
    const previous=new Map();
    for(const group of state.data?.groups||[]){
      if(!["quad","tria","bar"].includes(group.kind))continue;
      const name=group.name,layer=state.layers.get(name);if(!layer)continue;previous.set(name,layer.visible);
      const on=group.panel_id!=null;
      layer.visible=on;for(const mesh of layer.meshes)mesh.setEnabled(on);
      const checkbox=document.getElementById("layer-"+name);if(checkbox)checkbox.checked=on;
    }
    state.panelView={previous,contour:WingStiffenedPanels.contour(state.panelIndex)};
  }else if(!enabled&&state.panelView){
    const {previous}=state.panelView;state.panelView=null;
    for(const [name,visible]of previous){const layer=state.layers.get(name);if(!layer)continue;layer.visible=visible;for(const mesh of layer.meshes)mesh.setEnabled(visible);const cb=document.getElementById("layer-"+name);if(cb)cb.checked=visible;}
  }
  document.getElementById("show-panels").checked=enabled;
  // A structural layer can contain both line and full-section meshes.
  // Restoring its switch must still respect the selected beam representation.
  applyBeamStyle();syncMeshEdges();syncLayerGroupControls();
  if(redraw&&state.data){syncResultOverlays();applyContour();syncLayerGroupControls();state.annotations?.invalidate();}
}

function enforcePanelIsolation(){
  if(!state.panelView)return;
  const panelGroups=new Set((state.data?.groups||[]).filter(g=>g.panel_id!=null).map(g=>g.name));
  const sections=document.getElementById("beam-style").value==="sections";
  const thick=document.getElementById("shell-geometry")?.value==="thickness";
  for(const name of state.panelView.previous.keys()){
    const layer=state.layers.get(name);if(!layer)continue;
    const on=panelGroups.has(name);layer.visible=on;
    for(const mesh of layer.meshes){
      const bar=!mesh.barRepresentation||mesh.barRepresentation===(sections?"sections":"lines")||mesh.barRepresentation==="lines"&&!mesh.hasSectionShape;
      const shell=!mesh.shellRepresentation||(mesh.shellRepresentation==="thickness"?thick:!thick||!mesh.hasPhysicalThickness);
      if(mesh.isEnabled()!==!!(on&&bar&&shell))mesh.setEnabled(on&&bar&&shell);
    }
    const checkbox=document.getElementById("layer-"+name);if(checkbox)checkbox.checked=on;
  }
}

function panelControlsLayer(name){return!!state.panelView?.previous.has(name);}

// Only draw edges belonging to visible shells, retaining opaque depth so
// hidden ribs/lower surfaces do not bleed through an isolated skin.
function syncMeshEdges(){
  const layer=state.layers.get("MESH_EDGES");if(!layer||!state.data||state.edgeUpdateBatch)return;
  const groups=state.data.groups.filter(g=>(g.kind==="quad"||g.kind==="tria")&&state.layers.get(g.name)?.visible);
  const key=groups.map(g=>g.name).join("|")+"/explode:"+!!state.panelExplosion?.active;
  if(key!==state.edgeVisibilityKey){
    const disposed=new Set(layer.meshes);for(const mesh of disposed)mesh.dispose(false,true);
    state.deformable=state.deformable.filter(item=>!disposed.has(item.mesh));
    const batches=new Map();for(const group of groups){const id=state.panelExplosion?.active?(group.panel_id??null):null;if(!batches.has(id))batches.set(id,[]);batches.get(id).push(group);}
    layer.meshes=[];let count=0;
    for(const [id,members]of batches){const edges=shellEdgePairs(members),mesh=lineMesh("MESH_EDGES"+(id==null?"":"-P"+id),currentPositions(),edges,"#101720",1,true);count+=edges.length/2;
      if(mesh){mesh.renderingGroupId=1;mesh.material.zOffset=-1;mesh.explodedPanelId=id;state.panelExplosion?.applyMesh(mesh,id);layer.meshes.push(mesh);}}
    layer.count=count+" edges";state.edgeVisibilityKey=key;
  }
  for(const mesh of layer.meshes)mesh.setEnabled(layer.visible);
}

function refreshWeights(data = state.data) {
  const host = document.getElementById("weights-report");
  if (!host || typeof WingWeights === "undefined") return;
  if(state.importedDeck){const note=document.createElement("p");note.className="pick-note";note.textContent="Component mass accounting is not available for imported decks. Original material densities, section properties and mass cards remain authoritative in the solver; inspect the source deck and solver report.";host.replaceChildren(note);return;}
  if (!state.weightsView) state.weightsView = WingWeights.create(host,selectLoadCase);
  const cases=data?.load_cases || [],selected=cases.find(c=>Number(c.id)===state.activeCase);
  state.weightsView.update(selected?.weights || data?.weights, state.modelDirty,cases,state.activeCase);
}

function refreshFuelMassProperties() {
  const display=state.fuelMassDisplay;
  if(!display)return;
  const fuel=state.data?.load_cases?.find(c=>Number(c.id)===state.activeCase)?.fuel || {bays:[]};
  const input=document.getElementById("fuel-inertia-scale"),requestedScale=Number(input?.value??1);
  const note=document.getElementById("fuel-mass-status");
  const invalidScale=!Number.isFinite(requestedScale)||requestedScale<.01||requestedScale>100;
  const scale=invalidScale ? state.fuelMassScale || 1 : requestedScale;
  state.fuelMassScale=scale;
  const enabled=document.getElementById("show-fuel-inertia")?.checked===true;
  const result=display.update({fuel,enabled,scale,showCG:document.getElementById("show-fuel-cg")?.checked===true,
    markerRadius:Math.max(markerRadius(),state.diag*1e-8)});
  WingMassProperties.renderDetails?.(document.getElementById("fuel-mass-details"),result);
  let layer=state.layers.get("FUEL_INERTIA");
  if(!layer){layer={label:"Fuel inertia · undeformed",color:WingMassProperties.COLOR,count:"",meshes:display.meshes,visible:enabled};state.layers.set("FUEL_INERTIA",layer);}
  layer.meshes=display.meshes;layer.visible=enabled;layer.count=result.bays.filter(b=>b.mass>0).length+" masses";
  const checkbox=document.getElementById("layer-FUEL_INERTIA");if(checkbox)checkbox.checked=enabled;
  if(note)note.textContent=invalidScale ? "Radius scale must be between 0.01 and 100; retaining the last valid size." : result.errors.length ? result.errors.map(e=>"Bay "+e.bay+": "+e.message).join("; ") :
    fuel.bays?.length ? "Case "+state.activeCase+": "+eng(fuel.mass_kg)+" kg, "+layer.count+(state.modelDirty?" · regenerate for changed inputs.":".") : state.data?.fuel?.enabled && state.data.fuel.active_bay_count===0 ? "All selected fuel bays are dry; no fuel masses are generated." : "Enable a fuel tank and create FEM to calculate fuel masses.";
}

function modelEntityGroups() {
  const structural = state.data?.groups || [];
  const definitions = [
    ["shells", "Shell elements", structural.filter(g => g.kind === "quad" || g.kind === "tria").map(g => g.name)],
    ["beams", "Beam elements", structural.filter(g => g.kind === "bar").map(g => g.name)],
    ["connections", "Nodes, connections and supports", ["NODES", "RBE3", "RBE3_NODES", "FUEL_RBE3", "FUEL_RBE3_NODES", "SPC"]],
    ["aerodynamics", "Aerodynamic geometry", ["AERO_SURFACE", "AIRFOIL_SECTIONS", "VLM_MESH", "VLM_PRESSURE"]],
    ["loads", "Forces and moments", ["AERO_LOADS", "AERO_MOMENTS", "VLM_FORCES", "SUPPORT_FORCES"]],
    ["masses", "Mass properties", ["FUEL_INERTIA"]],
    ["overlays", "Context and result overlays", ["FUEL_TANK", "UNDEFORMED", "REFERENCE_AERO"]],
    ["aids", "Mesh and element axes", ["MESH_EDGES", "SHELL_AXES", "BAR_AXES"]],
    ["coordinates", "Coordinate systems", ["COORDINATE_SYSTEMS"]],
  ];
  const seen = new Set(definitions.flatMap(item => item[2]));
  definitions.push(["other", "Other model entities", Array.from(state.layers.keys()).filter(name => !seen.has(name))]);
  return definitions.map(([id, label, names]) => ({ id, label, names: names.filter(name => state.layers.has(name)) })).filter(group => group.names.length);
}

function modelEntityLayerAvailable(name) {
  return !["UNDEFORMED", "REFERENCE_AERO"].includes(name) || !!activeShape();
}

function appliedMomentHint() {
  return "Global X red, Y green, Z blue; each curved arrow shows one signed component by the right-hand rule. " + (Array.isArray(activeLoads()?.moment_stations)
    ? "Aerodynamic moments act at rib-plane RBE3s; fuel and structural inertia moments act at mid-bay mass RBE3s. Moments include the lever arm of relocated forces. Inspect either reference GRID for signed totals and source contributions in Nm."
    : "Applied moment couples in global axes. Inspect an RBE3 or its reference GRID for signed components in Nm.");
}

function syncLayerGroupControls() {
  const panelLockNote="Panels controls shell and beam visibility. Turn Panels off to choose these components.";
  for (const [groupId,{ checkbox, count, names, rows }] of state.layerGroupControls) {
    const available = names.filter(modelEntityLayerAvailable);
    const enabled = available.filter(name => state.layers.get(name)?.visible).length;
    const locked=!!state.panelView&&["shells","beams"].includes(groupId);
    checkbox.disabled = locked||!available.length;checkbox.title=locked?panelLockNote:"";
    const fieldset=document.getElementById("entity-group-"+groupId);if(fieldset){fieldset.dataset.panelLocked=String(locked);fieldset.title=locked?panelLockNote:"";}
    checkbox.checked = !!available.length && enabled === available.length;
    checkbox.indeterminate = enabled > 0 && enabled < available.length;
    checkbox.setAttribute("aria-checked", checkbox.indeterminate ? "mixed" : String(checkbox.checked));
    count.textContent = rows ? rows.filter(row=>row.names.some(name=>state.layers.get(name)?.visible)).length+"/"+rows.length : enabled+"/"+available.length;
    for (const name of names) {
      const rowControl = document.getElementById("layer-" + name);
      if (rowControl) {
        rowControl.disabled = locked||!modelEntityLayerAvailable(name);
        rowControl.title = locked?panelLockNote:rowControl.disabled ? "Available when a deformed result is displayed" : name === "AERO_MOMENTS" ? appliedMomentHint() : "";
      }
    }
  }
  for(const {checkbox,names}of state.layerRowControls.values()){
    const available=names.filter(modelEntityLayerAvailable),enabled=available.filter(name=>state.layers.get(name)?.visible).length;
    const locked=names.some(panelControlsLayer);
    checkbox.disabled=locked||!available.length;checkbox.title=locked?panelLockNote:!available.length?"Available when a deformed result is displayed":"";checkbox.checked=!!available.length&&enabled===available.length;
    checkbox.indeterminate=enabled>0&&enabled<available.length;
    checkbox.setAttribute("aria-checked",checkbox.indeterminate?"mixed":String(checkbox.checked));
  }
  for (const id of ["entities-show-all", "entities-hide-all"]) {
    const button = document.getElementById(id); if (button) button.disabled = !state.layers.size;
  }
}

function setModelEntitiesVisible(names, on) {
  // A new explicit group choice ends the temporary tank-isolation mode.
  state.fuelIsolation = null;
  batchLayerVisibility(()=>{for (const name of names) setLayerVisible(name, on);});
  if(state.sensitivityMap?.contour.kind==="sensitivity_field")applyContour();
  syncFuelControls(); syncLayerGroupControls();applyAeroOverlayStyles();updateViewportLegends();
  state.annotations?.invalidate();
}

function componentLayerRows(group){
  if(!["shells","beams"].includes(group.id))return group.names.map(name=>({key:name,names:[name],label:state.layers.get(name).label,color:state.layers.get(name).color,count:state.layers.get(name).count}));
  const families=new Map(),byName=new Map(state.data.groups.map(g=>[g.name,g]));
  for(const name of group.names){
    const g=byName.get(name),family=(g?.base_group||name).replace(/_KINKS$/,"").replace(/^(UPPER_SKIN|LOWER_SKIN)_RUNOUTS$/,"$1");
    if(!families.has(family))families.set(family,{key:family,names:[],label:({UPPER_SKIN:"Upper skin",LOWER_SKIN:"Lower skin",STRINGERS:"Stringers"})[family]||family.replaceAll("_"," ").toLowerCase(),color:state.layers.get(name).color,total:0});
    const row=families.get(family);row.names.push(name);row.total+=g?.count||0;
  }
  return [...families.values()].map(row=>({...row,count:row.total+(group.id==="beams"?" bars":" shells")}));
}

function buildLayerPanel() {
  const aeroAppearance=document.getElementById("aerodynamic-appearance");aeroAppearance?.remove();
  const host = document.getElementById("layers"); host.innerHTML = "";
  state.layerGroupControls.clear();
  state.layerRowControls.clear();
  for (const group of modelEntityGroups()) {
    const fieldset = document.createElement("fieldset"); fieldset.className = "entity-group"; fieldset.id = "entity-group-" + group.id;
    const legend = document.createElement("legend"), label = document.createElement("label"), checkbox = document.createElement("input");
    checkbox.type = "checkbox"; checkbox.id = "entity-group-toggle-" + group.id; checkbox.setAttribute("aria-label", "Show " + group.label.toLowerCase());
    checkbox.onchange = () => setModelEntitiesVisible(group.names, checkbox.checked);
    const title = document.createElement("span"); title.textContent = group.label;
    const count = document.createElement("span"); count.className = "entity-group-count";
    const toggle=document.createElement("button"),body=document.createElement("div");
    toggle.type="button";toggle.className="entity-list-toggle mini";toggle.id="entity-list-toggle-"+group.id;
    body.id="entity-list-"+group.id;body.className="entity-list-body";toggle.setAttribute("aria-controls",body.id);
    const collapse=value=>{body.hidden=value;toggle.textContent=value?"+":"−";toggle.setAttribute("aria-expanded",String(!value));toggle.setAttribute("aria-label",(value?"Expand ":"Collapse ")+group.label.toLowerCase()+" list");};
    collapse(state.layerGroupCollapsed.get(group.id)===true);
    toggle.onclick=()=>{state.layerGroupCollapsed.set(group.id,!body.hidden);collapse(!body.hidden);markStudyViewModified();};
    label.append(checkbox, title, count);legend.append(toggle,label);fieldset.append(legend,body);
    const rows=componentLayerRows(group);
    state.layerGroupControls.set(group.id, { checkbox, count, names: group.names, rows,collapse });
    const pageSize=200;let page=0,filtered=rows;
    const list=document.createElement("div"),pager=document.createElement("div");
    const search=document.createElement("input"),previous=document.createElement("button"),next=document.createElement("button"),pageInfo=document.createElement("span");
    if(rows.length>pageSize){search.type="search";search.placeholder="Find property or entity…";search.setAttribute("aria-label","Filter "+group.label);previous.textContent="Previous";next.textContent="Next";previous.type=next.type="button";pager.append(search,previous,pageInfo,next);pager.className="entity-list-pager";body.append(pager);}
    body.append(list);
    const renderRows=()=>{
    for(const key of state.layerRowControls.keys())if(key.startsWith(group.id+":"))state.layerRowControls.delete(key);
    list.replaceChildren();
    page=Math.max(0,Math.min(page,Math.ceil(filtered.length/pageSize)-1));
    for (const item of filtered.slice(page*pageSize,(page+1)*pageSize)) {
      const name=item.names[0],layer=state.layers.get(name),row=document.createElement("label");row.className="layer";
      row.dataset.component=item.key;
      if(name === "AERO_MOMENTS")row.title=appliedMomentHint();
      const cb = document.createElement("input");cb.type="checkbox";cb.checked=layer.visible;cb.id="layer-"+(item.names.length===1?name:"component-"+item.key);
      cb.onchange=()=>setModelEntitiesVisible(item.names,cb.checked);
      state.layerRowControls.set(group.id+":"+item.key,{checkbox:cb,names:item.names});
      const sw = document.createElement("span"); sw.className = "swatch";
      sw.style.background=group.id==="loads"&&name!=="VLM_FORCES"?"linear-gradient(90deg, #ef5f6b 0% 33.33%, #4cc38a 33.33% 66.66%, #56a8f5 66.66% 100%)":item.color;
      if(group.id==="loads")sw.title=name==="VLM_FORCES"?"Magenta: signed panel-normal pressure force":"Global X red, Y green, Z blue";
      const text = document.createElement("span"); text.className = "layer-name"; text.textContent = item.label;
      const count = document.createElement("span"); count.className = "count"; count.textContent = item.count;
      row.append(cb, sw, text, count); list.appendChild(row);
    }
    previous.disabled=page===0;next.disabled=(page+1)*pageSize>=filtered.length;pageInfo.textContent=filtered.length?`${page*pageSize+1}–${Math.min((page+1)*pageSize,filtered.length)} / ${filtered.length}`:"No matches";
    };
    previous.onclick=()=>{page--;renderRows();syncLayerGroupControls();};next.onclick=()=>{page++;renderRows();syncLayerGroupControls();};
    search.oninput=()=>{const query=search.value.toLowerCase().trim();filtered=rows.filter(row=>row.label.toLowerCase().includes(query));page=0;renderRows();syncLayerGroupControls();};
    renderRows();
    if(group.id==="aerodynamics" && aeroAppearance)body.appendChild(aeroAppearance);
    host.appendChild(fieldset);
  }
  if(aeroAppearance && !aeroAppearance.parentElement)host.appendChild(aeroAppearance);
  for(const [id,collapsed]of [["btn-collapse-layer-groups",true],["btn-expand-layer-groups",false]]){const button=document.getElementById(id);if(button)button.onclick=()=>{for(const [key,control]of state.layerGroupControls){state.layerGroupCollapsed.set(key,collapsed);control.collapse(collapsed);}markStudyViewModified();};}
  syncLayerGroupControls(); syncAxesControls(); syncAeroOverlayControl(); syncFuelControls();
}

function updateViewPlanes(data = state.data) {
  if (!state.scene || !data || typeof WingViewPlanes === "undefined") return;
  if (!state.viewPlanes) state.viewPlanes = WingViewPlanes.create({ scene: state.scene });
  const bounds=WingImportedRender.bounds(data,!!state.layers.get("NODES")?.visible);
  state.viewPlanes.update(bounds===data.bbox?data:{...data,bbox:bounds}, groundViewSettings() || undefined); syncViewPlanes();
}

function groundViewSettings(report = false) {
  const settings = {}; let valid = true;
  for (const [id, key, fallback] of [["ground-plane-z", "z", 0], ["ground-grid-spacing", "spacing", 5]]) {
    const control = document.getElementById(id), text = control ? control.value.trim() : String(fallback), value = Number(text);
    const error = !text || !Number.isFinite(value) || key === "spacing" && value <= 0;
    const message = error ? (key === "z" ? "Ground z must be a finite number of metres." : "Grid spacing must be a finite number greater than zero.") : "";
    control?.setCustomValidity?.(message);
    if (error && report) control?.reportValidity?.();
    valid = valid && !error; settings[key] = value;
  }
  return valid ? settings : null;
}

function syncViewPlanes(report = false) {
  document.getElementById("ground-height-field").hidden=!document.getElementById("show-ground-plane").checked;
  const settings = groundViewSettings(report === true), previous = state.viewPlanes?.layout;
  if (settings && previous && (settings.z !== previous.z || settings.spacing !== previous.spacing)) state.viewPlanes.configure(settings);
  state.viewPlanes?.setVisible(document.getElementById("show-ground-plane")?.checked, document.getElementById("show-symmetry-plane")?.checked);
  state.viewportTools?.syncDisplay();
  const note = document.getElementById("view-planes-note");
  const plane = state.viewPlanes?.layout;
  const units=state.data?.imported_deck?"source units":"m";
  if (note && plane) note.textContent = "Ground: global z = " + eng(plane.z, 5) + " "+units+", with " + eng(plane.spacing, 5) + " "+units+" tiles and grid lines. Symmetry: global y = " +
    eng(plane.root[1], 5) + " "+units+". "+(state.data?.imported_deck?"Imported deck coordinates are retained without unit conversion. ":"")+"Ground is a background guide; symmetry is translucent. These display settings do not remesh or change the FE model, picking, mass or export.";
}

function syncAeroOverlayControl() {
  const control = document.getElementById("show-aero-overlay"), layer = state.layers.get("AERO_SURFACE");
  if (control) { control.disabled = !layer; control.checked = !!layer?.visible; }
  const resultToggle=document.getElementById("show-deformed-aero");if(resultToggle){resultToggle.disabled=!layer;resultToggle.checked=!!layer?.visible;}
  const style=document.getElementById("aero-deformed-style"),note=document.getElementById("aero-display-note");
  const effective=aeroSurfaceStyle(),finish={steel:"metallic",wireframe:"wireframe",translucent:"translucent"}[effective];
  const label=document.getElementById("deformed-aero-label");if(label)label.textContent=(activeShape()?"Deformed aero":"Undeformed aero")+" · "+finish;
  if(style)style.disabled=!layer || !state.aeroDisplay;
  if(note)note.textContent="Airfoil wires show the defined, undeformed sections at their exact span positions. "+(state.sensitivityMap?"Sensitivity colors describe property derivatives; the aero loft is undeformed. Open FE Results to see the primal deformed shape. ":activeShape()?"The loft follows the selected FE result and deformation scale. ":"The loft is undeformed because no displacement shape is displayed. ")+(style?.value==="auto"?"Auto uses wireframe over colored structural results and panels, metallic for other deformed views, and translucent otherwise.":"The selected finish is used directly; metallic surfaces may cover underlying structural colors.");
  if(note&&!layer)note.textContent=state.data?.imported_deck?"This imported deck has no aerodynamic loft. Its shell elements remain available in Display and Results.":"Create FEM to display the aerodynamic loft and defined airfoil sections.";
}

function syncAxesControls() {
  for (const [id, name] of [["show-shell-axes", "SHELL_AXES"], ["show-bar-axes", "BAR_AXES"]]) {
    const control = document.getElementById(id); if (!control) continue;
    const layer = state.layers.get(name); control.disabled = !layer; control.checked = !!(layer && layer.visible);
  }
}

// Restoration paths finish with contour/aero appearance synchronization.
// Restore hundreds of property switches with one shared edge/form update,
// not one for every property. Nested batches retain edge-update suspension.
function batchLayerVisibility(action) {
  const wasBatch=state.layerVisibilityBatch,wasEdges=state.edgeUpdateBatch;
  state.layerVisibilityBatch=true;state.edgeUpdateBatch=true;
  try{return action();}
  finally{
    state.layerVisibilityBatch=wasBatch;state.edgeUpdateBatch=wasEdges;
    if(!wasBatch){
      applyBeamStyle();applySurfaceMode();syncMeshEdges();syncLayerGroupControls();syncAeroOverlayControl();syncVlmControls();
      if(state.selectedElement!==null||state.selectedNode!==null)updateSelection();
      state.annotations?.invalidate();
    }
  }
}

function setLayerVisible(name, on) {
  on = !!on;
  if(panelControlsLayer(name)){if(!state.edgeUpdateBatch)syncLayerGroupControls();return;}
  if (on && !modelEntityLayerAvailable(name)) on = false;
  if (name === "VLM_PRESSURE" && state.vlm) {
    const field = document.getElementById("vlm-field");
    if (on && (!field.value || field.value === "none")) { field.value = state.vlm.pressure ? "pressure" : "cp"; applyVlmContour(); return; }
    if (!on && field.value !== "none") { field.value = "none"; applyVlmContour(); return; }
  }
  if (["AERO_LOADS", "AERO_MOMENTS", "VLM_MESH", "VLM_FORCES"].includes(name)) state.loadLayerVisibility.set(name, on);
  const layer = state.layers.get(name);
  if (!layer) return;
  if (layer.visible !== on && !state.busy && !state.buildingScene) markStudyViewModified();
  if(name==='COORDINATE_SYSTEMS'&&on&&!layer.meshes.length){
    layer.meshes=WingModelEntities.coordinateMeshes(BABYLON,{scene:state.scene,parent:state.root,payload:state.data?.coordinate_systems,diag:state.diag});
  }
  if (name === "NODES" && on && !layer.meshes.length && state.baseline) {
    const nodes = Array.from({ length: state.data.nodes.n_structural }, (_, i) => i);
    layer.meshes = markerMesh("NODES", currentPositions(), nodes, EXTRA_STYLE.NODES.color,
                              Math.max(nodeRadius(), state.diag * 1e-8)) || [];
    updateMarkerRadii();
  }
  layer.visible = on;
  if(name==="NODES"&&state.importedDeck)updateViewPlanes();
  if(name!=="FUEL_INERTIA")for (const m of layer.meshes) m.setEnabled(on);
  if(name==="FUEL_INERTIA") {document.getElementById("show-fuel-inertia").checked=on;refreshFuelMassProperties();}
  if(!state.layerVisibilityBatch)applyBeamStyle();
  if(on&&!state.layerVisibilityBatch&&layer.meshes.some(mesh=>mesh.shellRepresentation))applySurfaceMode();
  const cb = document.getElementById("layer-" + name);
  if (cb) cb.checked = on;
  if (name === "SHELL_AXES" || name === "BAR_AXES") document.getElementById("axes-note").hidden =
    !["SHELL_AXES", "BAR_AXES"].some((key) => state.layers.get(key) && state.layers.get(key).visible);
  if (name === "SHELL_AXES" || name === "BAR_AXES") syncAxesControls();
  if (name === "UNDEFORMED") document.getElementById("show-undeformed").checked = on;
  if (name === "REFERENCE_AERO") document.getElementById("show-reference-aero").checked = on;
  if (name === "AERO_SURFACE"&&!state.layerVisibilityBatch) {syncAeroOverlayControl();updateViewportLegends();}
  if (name === "FUEL_TANK") syncFuelControls();
  if (name === "SUPPORT_FORCES") document.getElementById("show-support-forces").checked = on;
  if (!state.layerVisibilityBatch&&(state.selectedElement !== null || state.selectedNode !== null)) updateSelection();
  if (!state.layerVisibilityBatch&&["VLM_MESH", "VLM_PRESSURE", "VLM_FORCES", "AERO_LOADS", "AERO_MOMENTS"].includes(name)) syncVlmControls();
  if(!state.layerVisibilityBatch)syncComparisonVisibility();
  syncMeshEdges();
  if(!state.edgeUpdateBatch){syncLayerGroupControls();if(state.sensitivityMap?.contour.kind==="sensitivity_field")applyContour();else if(layer.meshes.some(mesh=>["quad","tria"].includes(mesh.metadata?.feGroup?.kind)))applyAeroOverlayStyles();}
  state.annotations?.invalidate();
}

/* --- results display ----------------------------------------------------- */

function currentResultVariants() {
  return state.resultCases?.get(state.activeCase)?.variants || new Map();
}

function resultAnalysisLabel(result) {
  const label = result?.source === "sensitivity_baseline" ? (result.historical?"Historical ":"")+(result.variantLabel||"Sensitivity baseline "+result.analysis) : result?.variantId === "sol101" ? "Linear SOL101" : result?.variantId === "sol106" ? "Nonlinear SOL106" : result?.analysis || "Analysis";
  return label + (result?.available !== false && Number.isFinite(result?.loadScale) && result.loadScale < 1 ? " · " + (100 * result.loadScale).toFixed(2) + "% load" : "");
}

function syncNonlinearWarning() {
  const nonlinear = currentResultVariants().get("sol106");
  const failed = nonlinear && nonlinear.convergence?.converged === false;
  const partial = failed && nonlinear.available !== false && nonlinear.static && nonlinear.convergence?.partial;
  const text = !failed ? "" : partial ? "SOL106 DID NOT CONVERGE AT FULL LOAD. Showing the last converged state at " +
    (100 * nonlinear.loadScale).toFixed(2) + "% load. " +
    (currentResultVariants().get("sol101")?.available === false ? "The matching SOL101 solution is unavailable. " :
      currentResultVariants().get("sol101")?.comparisonMethod === "matched_load_rerun" ? "SOL101 was solved again at this load, including follower load stiffness. " : "The SOL101 solution is scaled to the same load. ") + "The failed increment is excluded." :
    "SOL106 DID NOT CONVERGE. No verified converged nonlinear state is available. Any displayed linear result is identified separately.";
  for (const id of ["nonlinear-warning", "nonlinear-viewport-warning"]) {
    const host = document.getElementById(id); if (host) { host.hidden = !text; host.textContent = text; }
  }
}

function selectResultAnalysis(id) {
  clearSensitivityMap();
  const result = currentResultVariants().get(id);
  if (!result) return;
  const selectedContour = contourValues()?.name || "None";
  restoreBaseline();
  state.resultVariantPreference = id;
  state.results = result; state.activeMode = -1; state.contourIdx = 0;
  document.getElementById("report-text").textContent = result.report;
  showResults();
  const index = contourOptions().findIndex(c => c.name === selectedContour);
  state.contourIdx = index >= 0 ? index : 0;
  document.getElementById("contour-select").value = String(state.contourIdx);
  applyContour();
  if (state.selectedElement !== null) showElement(state.selectedElement);
  if (state.selectedNode !== null) showNode(state.selectedNode);
}

function syncAnalysisControls() {
  updateAnalysisValidity();
  syncNonlinearWarning();
  const variants = currentResultVariants(), host = document.getElementById("result-comparison");
  if (!host) return;
  host.hidden = !variants.size;
  const select = document.getElementById("result-analysis-select"); select.innerHTML = "";
  for (const [id, result] of variants) {
    const option = document.createElement("option"); option.value = id;
    option.textContent = resultAnalysisLabel(result) + (result.available === false ? " — " + result.status : "");
    select.appendChild(option);
  }
  select.value = state.results?.variantId || "";
  const available = Array.from(variants.values()).filter(r => r.available !== false && r.matches && r.static);
  document.getElementById("compare-results").disabled = available.length < 2;
  const rows = Array.from(variants.values()).map(r => {
    const cv = r.convergence;
    const status = r.available === false ? r.status + (r.message ? ": " + r.message : "") :
      cv ? (cv.converged && cv.full_load ? "Converged at full load" : "Load factor " + eng(cv.exported_load_scale ?? cv.final_load_scale, 4)) : "Complete";
    const details = cv ? [Number.isFinite(cv.accepted_steps) ? cv.accepted_steps + " accepted steps" : "",
      Number.isFinite(cv.exported_relative_residual ?? cv.final_relative_residual) ? (cv.partial ? "accepted-state relative residual " : "relative residual ") + eng(cv.exported_relative_residual ?? cv.final_relative_residual, 4) : "",
      cv.termination_reason || ""].filter(Boolean).join("; ") : "";
    return "<tr><th scope=\"row\">" + esc(resultAnalysisLabel(r)) + "</th><td>" +
      (r.available !== false && r.static ? eng(r.static.maxDisp, 6) + " m" : "Unavailable") +
      "<small>" + esc(status) + (details ? "<br>" + esc(details) : "") + "</small></td></tr>";
  });
  const linear = variants.get("sol101"), nonlinear = variants.get("sol106");
  if (linear?.available !== false && nonlinear?.available !== false && linear?.static?.maxDisp > 0 && nonlinear?.static) {
    rows.push("<tr><th scope=\"row\">Peak ratio NL / linear</th><td>" + eng(nonlinear.static.maxDisp / linear.static.maxDisp, 5) + "</td></tr>");
  }
  document.getElementById("comparison-summary").innerHTML = "<table><caption>Peak displacement · current load case</caption>" + rows.join("") + "</table>";
}

function comparisonResult() {
  if (!document.getElementById("compare-results")?.checked || !activeShape()) return null;
  return Array.from(currentResultVariants().values()).find(r => r !== state.results && r.available !== false && r.matches && r.static) || null;
}

function disposeComparisonOverlay() {
  for (const item of state.comparisonMeshes) item.mesh.dispose(false, true);
  state.comparisonMeshes = [];
  const key = document.getElementById("comparison-key"); if (key) key.hidden = true;
}

function rebuildComparisonOverlay() {
  disposeComparisonOverlay();
  if(state.panelView)return;
  const result = comparisonResult();
  if (!result || !state.baseline) return;
  const hex = result.variantId === "sol101" ? "#59ddff" : "#ed87ff";
  let sectionBuffer;
  const groups=state.importedDeck?WingImportedRender.batches(state.data.groups,asI32,asF32):state.data.groups;
  for (const group of groups) {
    // Keep one stable edge segment range per element in batched overlays so
    // hiding a PID never changes the numbering of neighbouring elements.
    let pairs;
    if(group.kind==="bar")pairs=asI32(group.conn);
    else if(group.sourceRanges){
      const conn=asI32(group.conn),stride=group.kind==="quad"?4:3;
      pairs=new Int32Array(group.count*stride*2);
      for(let e=0;e<group.count;e++)for(let k=0;k<stride;k++){
        pairs[(e*stride+k)*2]=conn[e*stride+k];pairs[(e*stride+k)*2+1]=conn[e*stride+(k+1)%stride];
      }
    }else pairs=shellEdgePairs([group]);
    const mesh = lineMesh("COMPARE_" + group.name, state.baseline, pairs, hex, 1, false);
    if (!mesh) continue;
    if(group.sourceRanges){mesh.importedRanges=group.sourceRanges.map(range=>({...range}));mesh.importedIndicesPerElement=group.kind==="bar"?2:group.kind==="quad"?8:6;}
    // Explicit comparison overlay: the legend identifies its wireframe as
    // visible through surfaces, while ordinary model layers retain depth.
    mesh.renderingGroupId = BAR_RENDER_GROUP;
    mesh.material.depthFunction = BABYLON.Constants.ALWAYS;
    mesh.material.disableDepthWrite = true;
    const section = group.kind === "bar" ? barSectionMesh(group, state.baseline, pairs, hex, true) : null;
    state.comparisonMeshes.push({ mesh, group: group.name, pairs, buf: new Float32Array(pairs.length * 3), result,
      representation: section ? "lines" : null });
    if (section) {
      section.name = "COMPARE_" + group.name + "-sections";
      section.material.wireframe = true;
      section.material.alpha = 1;
      section.material.transparencyMode = BABYLON.Material.MATERIAL_OPAQUE;
      section.material.disableLighting = true;
      section.material.emissiveColor = color3(hex);
      section.material.depthFunction = BABYLON.Constants.ALWAYS;
      section.material.disableDepthWrite = true;
      section.renderingGroupId = BAR_RENDER_GROUP;
      state.comparisonMeshes.push({mesh: section, group:group.name, result, representation:"sections", barSection:true,
        buf: sectionBuffer||(sectionBuffer=new Float32Array(state.baseline.length))});
    }
  }
  const key = document.getElementById("comparison-key");
  if (key) {
    key.hidden = false;
    key.innerHTML = "<b>" + esc(resultAnalysisLabel(state.results)) + "</b>: filled / active contour<br>" +
      '<span class="comparison-swatch" style="background:' + hex + '"></span>' + esc(resultAnalysisLabel(result)) +
      ": wireframe through surfaces<br><small>Same deformation magnification · current load case</small>";
  }
  updateComparisonPositions(amplitude() * (animating() ? Math.sin(state.phase) : 1));
  syncComparisonVisibility();
}

function updateComparisonPositions(amp) {
  const base = state.baseline;
  if (!base) return;
  const sectionPositions=new Map();
  for (const {mesh, pairs, buf, result} of state.comparisonMeshes) {
    const shape = result.static.disp;
    if (mesh.sectionGeometry) {
      let positions=sectionPositions.get(result);
      if(!positions){positions=buf;sectionPositions.set(result,positions);
        for (let n = 0; n < base.length; n += 3) {
          positions[n] = base[n] + amp * shape[n + 1]; positions[n + 1] = base[n + 1] + amp * shape[n + 2]; positions[n + 2] = base[n + 2] + amp * shape[n];
        }
      }
      WingSections.updateMesh(BABYLON, mesh, positions, result.static.rotation, amp);
      continue;
    }
    for (let i = 0; i < pairs.length; i++) {
      const n = 3 * pairs[i], v = 3 * i;
      buf[v] = base[n] + amp * shape[n + 1];
      buf[v + 1] = base[n + 1] + amp * shape[n + 2];
      buf[v + 2] = base[n + 2] + amp * shape[n];
    }
    mesh.updateVerticesData(BABYLON.VertexBuffer.PositionKind, buf, true, false);
  }
}

function syncComparisonVisibility() {
  const representation = document.getElementById("beam-style")?.value || "lines";
  const available = !state.sensitivityMap && !!comparisonResult();
  for (const item of state.comparisonMeshes) {
    if(item.mesh.importedRanges)WingImportedRender.sync(item.mesh,state.layers);
    const visible=item.mesh.importedRanges?item.mesh.isEnabled():!!state.layers.get(item.group)?.visible;
    item.mesh.setEnabled(visible && available && (!item.representation || item.representation === representation));
  }
}

function activeShape() {
  if(state.sensitivityMap)return null;
  const r = state.results;
  if (!r || !r.matches || r.available === false) return null;
  if (state.activeMode >= 0 && r.modes[state.activeMode]) {
    return r.modes[state.activeMode];
  }
  if (r.static) return { shape: r.static.disp, rotation: r.static.rotation, maxDisp: r.static.maxDisp };
  return null;
}

function animating() {
  return !state.svgExportSnapshot && document.getElementById("animate").checked;
}

function scaleFactor() {
  const v = parseFloat(document.getElementById("deform-scale").value);
  return Math.pow(10, Number.isFinite(v) ? v : 0);
}

/** Amplitude that puts the peak deflection at a tenth of the model size. */
function amplitude() {
  const a = activeShape();
  if (!a) return 0;
  if (state.realScale && state.activeMode < 0) return 1;
  const paired = Array.from(currentResultVariants().values()).filter(r => r.available !== false && r.matches && r.static);
  const maxDisp = paired.length ? Math.max(...paired.map(r => r.static.maxDisp || 0)) : a.maxDisp;
  // Pure beam torsion can have zero grid translation. Keep its physical
  // rotation visible, with the same user-controlled scale multiplier.
  if (!(maxDisp > 0)) return [a.rotation, ...paired.map(r => r.static.rotation)].some(rotation =>
    rotation?.some(v => Number.isFinite(v) && v !== 0)) ? scaleFactor() : 0;
  return (0.10 * state.diag / maxDisp) * scaleFactor();
}

function applyDeformation() {
  const a = activeShape();
  const base = state.baseline;
  if (!a || !base) return;
  const dp = state.deformed;
  const shape = a.shape;
  const amp = amplitude() * (animating() ? Math.sin(state.phase) : 1);
  const n = base.length / 3;
  for (let i = 0; i < n; i++) {
    // The shape is in model axes, so it is permuted like the geometry.
    dp[3 * i] = base[3 * i] + amp * shape[3 * i + 1];
    dp[3 * i + 1] = base[3 * i + 1] + amp * shape[3 * i + 2];
    dp[3 * i + 2] = base[3 * i + 2] + amp * shape[3 * i];
  }
  pushPositions(dp, a.rotation, amp);
  updateComparisonPositions(amp);
}

function restoreBaseline() {
  if (!state.baseline) return;
  pushPositions(state.baseline);
}

function updateSurfaceNormals(mesh, positions) {
  if (!mesh.surfaceNormals) return;
  BABYLON.VertexData.ComputeNormals(positions, mesh.surfaceIndices, mesh.surfaceNormals,
    { useRightHandedSystem: state.scene.useRightHandedSystem });
  mesh.updateVerticesData(BABYLON.VertexBuffer.NormalKind, mesh.surfaceNormals);
}

function pushPositions(dp, rotations, rotationScale = 1) {
  state.geometryTools?.setPose(dp, rotations, rotationScale);
  const base = state.baseline;
  for (const d of state.deformable) {
    if (d.shellThickness) {
      WingShellThickness.updateMesh(BABYLON,d.mesh,dp);
    } else if (d.barSection) {
      WingSections.updateMesh(BABYLON, d.mesh, dp, rotations, rotationScale);
    } else if (d.axisCenters) {
      for (const frame of d.axisCenters) {
        const origin = frame.origin.clone();
        const explosion=state.panelExplosion?.offsetElement(frame.eid)||[0,0,0];origin.addInPlaceFromFloats(...explosion);
        for (const node of frame.nodes) {
          origin.x += (dp[3 * node] - base[3 * node]) / frame.nodes.length;
          origin.y += (dp[3 * node + 1] - base[3 * node + 1]) / frame.nodes.length;
          origin.z += (dp[3 * node + 2] - base[3 * node + 2]) / frame.nodes.length;
        }
        for (let i = frame.start; i < frame.start + frame.count; i++) {
          d.buf[3 * i] = origin.x + d.offsets[3 * i];
          d.buf[3 * i + 1] = origin.y + d.offsets[3 * i + 1];
          d.buf[3 * i + 2] = origin.z + d.offsets[3 * i + 2];
        }
      }
      d.mesh.updateVerticesData(BABYLON.VertexBuffer.PositionKind, d.buf, true, false);
    } else if (d.aero) {
      // Aero stations may lie between structural rows. Blend their supplied
      // attachment weights (four or eight corners); their sum is one.
      const map = d.map, w = d.weights, ab = d.base, buf = d.buf;
      const na = buf.length / 3, stride = d.nodesPerPoint || 4;
      for (let a = 0; a < na; a++) {
        let dx = 0, dy = 0, dz = 0;
        for (let k = 0; k < stride; k++) {
          const s = map[stride * a + k];
          const wk = w[stride * a + k];
          dx += wk * (dp[3 * s] - base[3 * s]);
          dy += wk * (dp[3 * s + 1] - base[3 * s + 1]);
          dz += wk * (dp[3 * s + 2] - base[3 * s + 2]);
          // Beyond a shortened box, continue the terminal rib's small-angle
          // rigid motion along the physical aerodynamic wing.
          if (rotations && d.rotationLever) {
            const lx = d.rotationLever[3 * a], ly = d.rotationLever[3 * a + 1], lz = d.rotationLever[3 * a + 2];
            const rx = rotations[3 * s], ry = rotations[3 * s + 1], rz = rotations[3 * s + 2];
            dx += wk * rotationScale * (ry * lz - rz * ly);
            dy += wk * rotationScale * (rz * lx - rx * lz);
            dz += wk * rotationScale * (rx * ly - ry * lx);
          }
        }
        buf[3 * a] = ab[3 * a] + dx;
        buf[3 * a + 1] = ab[3 * a + 1] + dy;
        buf[3 * a + 2] = ab[3 * a + 2] + dz;
      }
      d.mesh.updateVerticesData(BABYLON.VertexBuffer.PositionKind, buf, true, false);
      state.aeroDisplay?.updateNormals(d.mesh);
    } else if (d.map === null) {
      d.mesh.updateVerticesData(BABYLON.VertexBuffer.PositionKind, dp, true, false);
      updateSurfaceNormals(d.mesh, dp);
    } else {
      const buf = d.buf;
      const map = d.map;
      for (let v = 0; v < map.length; v++) {
        const n = map[v];
        buf[3 * v] = dp[3 * n] + (d.offsets ? d.offsets[3 * v] : 0);
        buf[3 * v + 1] = dp[3 * n + 1] + (d.offsets ? d.offsets[3 * v + 1] : 0);
        buf[3 * v + 2] = dp[3 * n + 2] + (d.offsets ? d.offsets[3 * v + 2] : 0);
      }
      d.mesh.updateVerticesData(BABYLON.VertexBuffer.PositionKind, buf, true, false);
      updateSurfaceNormals(d.mesh, buf);
    }
  }
  for (const m of state.markers) {
    const n = m.node;
    m.mesh.position.set(dp[3 * n], dp[3 * n + 1], dp[3 * n + 2]);
  }
  state.supportGlyphs?.update({positions:dp});
  updateVlmPose(dp, rotations, rotationScale);
  applyPanelMeshOffsets();
  updateSelection(dp);
}

const COLOR_SCALES = WingColorScales.scales;
const CMAP = COLOR_SCALES.spectrum;
function contourPaletteKey(contour) {
  if(contour?.kind==="properties")return "properties";
  return contour?.kind?.startsWith("sensitivity") ? "sensitivity" : "fe";
}
function selectedColorScale(scope="fe") {
  return COLOR_SCALES[WingLegends.getPalette(scope)] || CMAP;
}

function cmap(t,scope="fe") {
  const scale = selectedColorScale(scope);
  const x = Math.max(0, Math.min(1, t));
  for (let i = 1; i < scale.length; i++) {
    if (x <= scale[i][0]) {
      const [t0, c0] = scale[i - 1];
      const [t1, c1] = scale[i];
      const w = (x - t0) / (t1 - t0);
      return [c0[0] + w * (c1[0] - c0[0]),
              c0[1] + w * (c1[1] - c0[1]),
              c0[2] + w * (c1[2] - c0[2])];
    }
  }
  return scale[scale.length - 1][1];
}

function contourOptions() {
  const r = state.results;
  const opts = [{ kind: "none", name: "None" }];
  if (!r || !r.matches) return opts;
  if (activeShape()) {
    // A mode shape is mass normalised, so its magnitude has no units; a static
    // or prebuckling shape is a real deflection in metres.
    const isShape = state.activeMode >= 0 && r.modeKind !== "none";
    opts.push({
      kind: "disp",
      name: "Displacement magnitude",
      unit: isShape ? "normalised" : "m",
    });
  }
  r.contours.forEach((c, i) => {
    opts.push({ kind: "data", idx: i, name: c.name, unit: c.unit });
  });
  return opts;
}

/** Element values remain keyed by true NASTRAN EID, never by a shared node. */
function contourValues() {
  const c=rawContourValues();
  if(!c||c.kind==="panels")return c;
  if(c.kind==="properties"){
    const stale=state.modelDirty||resultsHavePendingDrafts(),note=c.note+(stale?" Definition changed: showing the last generated FEM.":"");
    const shape=activeShape(),caseLabel=shape?(state.importedDeck?"Imported properties":"Generated properties")+" · geometry: "+resultCaseLabel()+" · deformation ×"+eng(amplitude(),5)+(animating()?" (animated peak)":""):c.caseLabel+" · undeformed";
    if(c.categories)return{...c,note,caseLabel};
    const limitKey=JSON.stringify(["properties",c.field,c.materialRole]);
    return{...c,note,caseLabel,limitKey,...WingLegends.resolveLimits(limitKey,c.min,c.max)};
  }
  updateSensitivityVisibleRange(c);
  const limitKey=JSON.stringify(["fe",c.kind||"data",c.name,c.unit||""]);
  return {...c,limitKey,...WingLegends.resolveLimits(limitKey,c.min,c.max)};
}

function rawContourValues() {
  if(state.propertyDisplay?.enabled)return state.propertyDisplay.contour();
  if(state.sensitivityMap)return state.sensitivityMap.contour;
  if(state.panelView)return state.panelView.contour;
  const opts = contourOptions();
  const opt = opts[Math.min(state.contourIdx, opts.length - 1)];
  if (!opt || opt.kind === "none") return null;
  if (opt.kind === "data") {
    const c = state.results.contours[opt.idx];
    return c;
  }
  const a = activeShape();
  if (!a) return null;
  const n = a.shape.length / 3;
  const v = new Float32Array(n);
  let mx = 0;
  for (let i = 0; i < n; i++) {
    const m = Math.hypot(a.shape[3 * i], a.shape[3 * i + 1], a.shape[3 * i + 2]);
    v[i] = m;
    if (m > mx) mx = m;
  }
  return { values: v, min: 0, max: mx, unit: opt.unit, name: opt.name, location: "node" };
}

function elementContourValue(c, mesh, e) {
  if (c.location === "element") return c.byId ? c.byId.get(mesh.elementIds[e]) : undefined;
  // Nodal displacement is reduced only within this element, for a full,
  // constant fill. Stress/force data never take this nodal path.
  let sum = 0;
  const nodes = mesh.contourNodeMap ? mesh.contourNodeMap.slice(e*mesh.contourNodesPerElement,(e+1)*mesh.contourNodesPerElement) : mesh.nodeMap ? mesh.nodeMap.slice(e * mesh.nodesPerElement, (e + 1) * mesh.nodesPerElement) :
    state.elements.get(mesh.elementIds[e])?.nodes || mesh.sectionGeometry?.conn.slice(2*e,2*e+2);
  if (!nodes?.length) return undefined;
  for (const node of nodes) {
    if (!Number.isFinite(c.values[node])) return undefined;
    sum += c.values[node];
  }
  return sum / nodes.length;
}

function beamContourApplies(c) {
  return !!c && (c.location === "node" || c.domain === "bar" || c.domain === "all" || /^Bar\b/.test(c.name || "") ||
    !!c.byId && state.barMeshes.some(mesh => mesh.elementIds.some(id => c.byId.has(id))));
}

function contourRGB(c, value) {
  if(c.kind==="panels")return c.colors.get(value)||[.32,.36,.41];
  if(c.categories&&Number.isFinite(value)){
    // Discrete assignments need recognizable swatches even on a dark canvas.
    // Keep numeric palettes exact; sample/tint only the categorical palette.
    const t=c.max>c.min?(value-c.min)/(c.max-c.min):.5,rgb=cmap(.18+.70*t,contourPaletteKey(c));
    const luminance=.2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2],white=luminance<.40?(.40-luminance)/(1-luminance):0;
    return rgb.map(channel=>channel+(1-channel)*white);
  }
  return Number.isFinite(value) ? cmap(c.max > c.min ? (value-c.min)/(c.max-c.min) : .5,contourPaletteKey(c)) : [0.32,0.36,0.41];
}

function contourGradient(min, max,scope="fe") {
  const rgb = value => "rgb(" + cmap(value,scope).map(v=>Math.round(v*255)).join(",") + ")";
  return max > min ? "linear-gradient(90deg," + selectedColorScale(scope).map(([t])=>rgb(t)+" "+Math.round(t*100)+"%").join(",") + ")" : rgb(.5);
}

function propertyLegendCategories(c){
  return c.categories?.map(category=>({...category,color:"#"+contourRGB(c,category.value).map(v=>Math.round(255*v).toString(16).padStart(2,"0")).join("")}));
}

function resultCaseLabel() {
  if (state.results?.modeKind === "frequency") return "SOL103 · Mode " + (state.results.modes[state.activeMode]?.mode || state.activeMode+1) + " · all load cases";
  const current = modelCases().find(c=>Number(c.id)===state.activeCase);
  const analysis = state.results?.variantId ? resultAnalysisLabel(state.results) + " · " : "";
  return analysis + "Case " + state.activeCase + (current?.label ? " · " + current.label : "");
}

function updateViewportLegends() {
  if (typeof WingLegends === "undefined") return;
  const entries=[], c=contourValues();
  if (c&&c.kind!=="panels") entries.push({kind:c.kind==="properties"?"properties":"fe",paletteKey:contourPaletteKey(c),categories:propertyLegendCategories(c),limitKey:c.limitKey,title:c.name,unit:c.unit,min:c.min,max:c.max,caseLabel:c.caseLabel||resultCaseLabel(),
    gradient:contourGradient(c.min,c.max,contourPaletteKey(c)),note:[c.kind?.startsWith("sensitivity")?"Undeformed model · full element values":c.location==="node"?"Element mean displacement · no cross-element averaging":
      beamContourApplies(c)?"Full elements · gray = unavailable":"Full elements · gray = unavailable; beams keep group colors",
      typeof c.note==="string"?c.note:"",aeroSurfaceStyle()==="wireframe"&&aeroContourProtection()&&state.layers.get("AERO_SURFACE")?.visible?"Aero loft uses wireframe to reveal shell contours":""].filter(Boolean).join(" · ")});
  const field=document.getElementById("vlm-field")?.value,values=state.vlm?.[field];
  if (state.layers.get("VLM_PRESSURE")?.visible && values) {
    const {min,max,limitKey}=vlmColorRange(field,values);
    const current=modelCases().find(c=>Number(c.id)===state.activeCase);
    entries.push({kind:"vlm",limitKey,title:field==="pressure"?"VLM pressure jump":"VLM Cp jump",unit:field==="pressure"?"Pa":"dimensionless",min,max,
      caseLabel:"Case "+state.activeCase+(current?.label?" · "+current.label:""),gradient:contourGradient(min,max,"vlm"),note:"Lower minus upper · prescribed pressure; lattice follows displayed shape"});
  }
  WingLegends.render(document.getElementById("viewport-legends"),entries);
}

function applyContour() {
  const c = contourValues();
  if (c && state.fuelIsolation) {
    const previous = state.fuelIsolation;
    state.fuelIsolation = null;
    for (const [name, visible] of previous) setLayerVisible(name, visible);
    syncFuelControls();
  }
  const legend = document.getElementById(c?.kind==="properties"?"property-legend":"contour-legend");
  WingLegends.render(document.getElementById(c?.kind==="properties"?"contour-legend":"property-legend"),[]);
  const barContour = beamContourApplies(c);
  for (const mesh of state.barMeshes) {
    const base = color3(mesh.baseColorHex);
    const stride = mesh.sectionGeometry ? mesh.sectionGeometry.verticesPerElement : 2;
    const colors = new Float32Array(mesh.elementIds.length * stride * 4);
    mesh.elementIds.forEach((id, index) => {
      const value = barContour ? elementContourValue(c, mesh, index) : undefined;
      const rgb = barContour ? contourRGB(c,value) : [base.r, base.g, base.b];
      for (let vertex = 0; vertex < stride; vertex++) colors.set([...rgb, 1], 4 * stride * index + 4 * vertex);
    });
    mesh.updateVerticesData(BABYLON.VertexBuffer.ColorKind, colors);
    if (mesh.sectionGeometry) {
      setSurfaceLighting(mesh.material, BABYLON.Color3.White());
    }
  }
  for (const mesh of state.shellMeshes) {
    const nv = mesh.getTotalVertices();
    const colors = new Float32Array(nv * 4);
    if (!c) {
      colors.fill(1);
      setSurfaceLighting(mesh.material, color3(mesh.baseColorHex));
      if(mesh.fallbackElements?.some(Boolean)) {
        const base=color3(mesh.baseColorHex);
        for(let e=0;e<mesh.fallbackElements.length;e++) {
          const rgb=mesh.fallbackElements[e] ? [1,.08,.12] : [base.r,base.g,base.b];
          for(let k=0;k<mesh.nodesPerElement;k++) colors.set([...rgb,1],4*(e*mesh.nodesPerElement+k));
        }
        setSurfaceLighting(mesh.material, BABYLON.Color3.White());
      }
    } else {
      for (let e = 0; e < nv / mesh.nodesPerElement; e++) {
        const value = elementContourValue(c, mesh, e);
        const rgb = contourRGB(c,value);
        for (let k = 0; k < mesh.nodesPerElement; k++) {
          const i = e * mesh.nodesPerElement + k;
          colors[4 * i] = rgb[0]; colors[4 * i + 1] = rgb[1];
          colors[4 * i + 2] = rgb[2]; colors[4 * i + 3] = 1;
        }
      }
      setSurfaceLighting(mesh.material, BABYLON.Color3.White());
    }
    mesh.setVerticesData(BABYLON.VertexBuffer.ColorKind, colors, true);
  }

  applyAeroOverlayStyles();
  syncFuelResultOverlay(c);
  if (!c||c.kind==="panels") {
    legend.className = "empty";
    WingLegends.render(legend,[]);
    updateViewportLegends();
    return;
  }
  legend.className = "";
  WingLegends.render(legend,[{kind:c.kind==="properties"?"properties":"fe",paletteKey:contourPaletteKey(c),categories:propertyLegendCategories(c),limitKey:c.limitKey,title:c.name,unit:c.unit,min:c.min,max:c.max,caseLabel:c.caseLabel||resultCaseLabel(),gradient:contourGradient(c.min,c.max,contourPaletteKey(c)),
    note:["Full elements · no averaging across elements",c.location==="node"?"Element mean displacement":"Gray = unavailable",barContour?"Bar contour replaces stringer/cap colors.":"No applicable beam values; beams retain group colors.",typeof c.note==="string"?c.note:""].filter(Boolean).join(" · ")}]);
  updateViewportLegends();
  if (state.selectedElement !== null) showElement(state.selectedElement);
  if (state.selectedNode !== null) showNode(state.selectedNode);
}

function resultModelParams() {
  return state.results && state.results.modelParams || state.data && state.data.model_params || state.values;
}

/** Use the solved model snapshot, not a possibly edited parameter form. */
function loadFactorApplied() {
  if(state.importedDeck)return 1; // Native eigenvalues multiply the deck preload.
  const v = parseFloat(resultModelParams()["loads.load_factor"]);
  return Number.isFinite(v) ? v : 1;
}

function bucklingLoadLabel(multiplier) {
  if(state.importedDeck)return eng(multiplier,3)+" × source deck preload";
  const aero = resultModelParams()["loads.method"] === "vortex_lattice";
  return eng(multiplier * loadFactorApplied(), 3) + (aero ? " × aero loads" : " × prescribed loads");
}

function selectMode(i) {
  clearSensitivityMap();
  const r = state.results;
  if (!r) return;
  if (i >= r.modes.length) i = r.modes.length - 1;
  if (i < 0 && !r.static) i = 0;
  state.activeMode = i;
  updateScaleText();
  rebuildSupportForces();
  state.phase = Math.PI / 2;        // start at the peak, not at zero
  for (const el of document.querySelectorAll(".mode")) {
    el.classList.remove("active");
  }
  const row = document.getElementById("mode-" + i);
  if (row) row.classList.add("active");
  applyContour();
  applyDeformation();
  if (i < 0) {
    log("prebuckling static shape, peak " + eng(r.static.maxDisp, 4) + " m");
  } else if (r.modes[i]) {
    const m = r.modes[i];
    log(r.modeKind === "buckling"
        ? "buckling root " + m.mode + " at load factor " + eng(m.loadFactor, 5) +
          " (" + bucklingLoadLabel(m.loadFactor) + ")"
        : "mode " + m.mode + " at " + eng(m.freq, 5) + " Hz");
  }
}

function stepMode(delta) {
  const r = state.results;
  if (!r || !r.modes.length) return;
  const lo = r.static ? -1 : 0;
  selectMode(Math.max(lo, Math.min(state.activeMode + delta, r.modes.length - 1)));
}

function showResults() {
  clearSensitivityMap();
  const r = state.results;
  const card = document.getElementById("results-card");
  card.hidden = false;
  syncAnalysisControls();
  refreshAppliedLoadLayers();
  rebuildSupportForces();
  buildLayerPanel();

  document.getElementById("results-summary").innerHTML = "<table>" +
    r.summary.map(([k, v]) =>
      "<tr><td>" + esc(String(k)) + "</td><td>" + esc(reportValue(v)) +
      "</td></tr>").join("") + "</table>";

  const haveShape = r.available !== false && r.matches && (r.modes.length > 0 || r.static);
  document.getElementById("result-controls").hidden = !haveShape;
  document.getElementById("mode-list-wrap").hidden = r.modes.length === 0;

  if (r.modes.length) {
    const buckling = r.modeKind === "buckling";
    document.getElementById("mode-list-title").textContent =
      buckling ? "Buckling roots" : "Modes";
    const host = document.getElementById("mode-list");
    host.innerHTML = "";

    // A buckling run also carries its prebuckling static shape; offer it as
    // the first row so both can be looked at.
    if (r.static) {
      const row = document.createElement("div");
      row.className = "mode";
      row.id = "mode--1";
      row.onclick = () => selectMode(-1);
      row.innerHTML = '<span class="n">0</span><span>Static preload</span>' +
        '<span class="meff">' + eng(r.static.maxDisp, 3) + " m</span>";
      row.title = state.importedDeck ? "Prebuckling deflection under the original deck preload" : "the prebuckling deflection under the applied lift";
      host.appendChild(row);
    }

    r.modes.forEach((m, i) => {
      const row = document.createElement("div");
      row.className = "mode";
      row.id = "mode-" + i;
      row.onclick = () => selectMode(i);
      const value = buckling ? "&lambda; = " + eng(m.loadFactor, 5)
                             : eng(m.freq, 5) + " Hz";
      const right = buckling ? bucklingLoadLabel(m.loadFactor)
                             : "Mz " + eng(m.meffZ, 3);
      row.innerHTML = '<span class="n">' + m.mode + "</span>" +
        "<span>" + value + "</span>" +
        '<span class="meff">' + right + "</span>";
      row.title = buckling && state.importedDeck ? "Buckling root "+m.mode+"\nMultiplier on the original deck preload: "+eng(m.loadFactor,6) : buckling
        ? "buckling root " + m.mode + "\nload factor on the applied lift " +
          eng(m.loadFactor, 6) +
          (resultModelParams()["loads.method"] === "vortex_lattice"
            ? "\ntotal multiplier on the unscaled aerodynamic loads (not aircraft g)"
            : "\ntotal multiplier on the unscaled prescribed loads (not aircraft g)")
        : "mode " + m.mode + "\neigenvalue " + eng(m.eigenvalue, 6) +
          "\nmodal effective mass  x " + eng(m.meffX, 4) +
          "  y " + eng(m.meffY, 4) + "  z " + eng(m.meffZ, 4);
      host.appendChild(row);
    });
  }

  if (!haveShape) {
    state.activeMode = -1; state.contourIdx = 0;
    applyContour(); restoreBaseline(); syncResultOverlays();
    if (r.available !== false) log("the results do not match the displayed mesh, so no deformed shape is drawn", "warn");
    return;
  }

  // Choose the active shape before listing the contours, because the
  // displacement contour only exists once there is a shape to measure.
  state.activeMode = r.modes.length ? 0 : -1;
  state.phase = Math.PI / 2;
  document.getElementById("animate").checked = r.modes.length > 0;

  const sel = document.getElementById("contour-select");
  const opts = contourOptions();
  sel.innerHTML = "";
  opts.forEach((o, i) => {
    const el = document.createElement("option");
    el.value = String(i);
    el.textContent = o.name;
    sel.appendChild(el);
  });
  // Static runs open on von Mises when it is there, modes on displacement.
  const vmIdx = opts.findIndex((o) => o.kind === "data");
  state.contourIdx = (r.analysis.startsWith("SOL101") && vmIdx > 0) ? vmIdx : 1;
  state.contourIdx = Math.min(state.contourIdx, opts.length - 1);
  const preferred=state.contourPreference;
  const preferredIndex=preferred ? opts.findIndex(option=>option.kind===preferred.kind&&option.name===preferred.name) : -1;
  if(preferredIndex>=0)state.contourIdx=preferredIndex;
  if(!preferred)state.contourPreference={kind:opts[state.contourIdx].kind,name:opts[state.contourIdx].name};
  sel.value = String(state.contourIdx);

  if (r.modes.length) {
    selectMode(0);
  } else {
    applyContour();
    applyDeformation();
  }
  updateScaleText();
  syncResultOverlays();
}

function clearResults() {
  clearSensitivityMap();
  disposeComparisonOverlay();
  state.results = null;
  state.resultCases = null;
  refreshAppliedLoadLayers();
  rebuildSupportForces();
  buildLayerPanel();
  state.activeMode = -1;
  state.contourIdx = 0;
  document.getElementById("results-card").hidden = true;
  document.getElementById("report-text").textContent = "";
  applyContour();
  restoreBaseline();
  syncResultOverlays();
  syncAnalysisControls();
  if (state.selectedElement !== null) showElement(state.selectedElement);
  if (state.selectedNode !== null) showNode(state.selectedNode);
  badge("");
  if (!state.polling) { const clock = document.getElementById("load-clock"); if (clock) clock.hidden = true; }
}

function updateScaleText() {
  const f = scaleFactor();
  const physical = state.realScale && state.activeMode < 0;
  document.getElementById("deform-scale-txt").textContent =
    physical ? "1:1" : (f >= 10 ? f.toFixed(0) : f.toFixed(f < 1 ? 2 : 1)) + "×";
  const realButton = document.getElementById("btn-real-scale");
  if (realButton) {
    realButton.setAttribute("aria-pressed", String(physical));
    realButton.disabled = !activeShape() || state.activeMode >= 0;
    realButton.title = state.activeMode >= 0 ? "Eigenmodes are normalized shapes without a physical displacement scale." : "Actual static translations and rotations; magnification exactly one.";
  }
  const note = document.getElementById("comparison-scale");
  if (note) note.textContent = activeShape() ?
    "Physical magnification: ×" + eng(amplitude(), 5) + (currentResultVariants().size ? ". Both analyses use this same scale." : ".") : "";
  if(state.propertyDisplay?.enabled)applyContour();
}

function setRealScale(on) {
  if (on && (!activeShape() || state.activeMode >= 0)) return;
  state.realScale = on;
  if (on) { document.getElementById("animate").checked = false; state.phase = Math.PI / 2; }
  updateScaleText(); applyDeformation();
}

/* --- statistics panel ---------------------------------------------------- */

function totalElements(data) {
  let n = 0;
  for (const g of data.groups) n += g.count;
  return n + data.rbe3.count;
}

function showStats(data, bytes, seconds) {
  state.lastTransfer = { bytes, seconds };
  const fuelHost = document.getElementById("fuel-volume-summary");
  if (fuelHost) {
    const fuel = data.fuel;
    fuelHost.textContent = fuel?.enabled ? "Ribs " + fuel.start_rib + " to " + fuel.end_rib + ": " + eng(fuel.volume_m3, 6) +
      " m³ (" + eng(fuel.volume_litres, 6) + " L), gross half-wing capacity."+(fuel.active_bay_count!==undefined ? " "+fuel.active_bay_count+" wet bays; "+(fuel.excluded_bays?.length||0)+" dry/vent bays excluded." : "")+" See Summary for the volume basis." :
      "Enable the tank to compute its capacity when the mesh updates.";
  }
  const host = document.getElementById("stats");
  const rows = [];
  rows.push(['<td class="section" colspan="2">Geometry and mesh</td>']);
  for (const [k, v] of data.info) {
    rows.push(["<td>" + esc(k) + "</td><td>" + esc(reportValue(v)) + "</td>"]);
  }
  if (activeLoads() && activeLoads().summary && !state.importedDeck) {
    const loads = activeLoads().summary;
    rows.push(['<td class="section" colspan="2">Aerodynamic loads</td>']);
    for (const [label, key, unit] of [["Method", "method", ""], ["Lift", "lift_N", " N"],
      ["Lift coefficient", "CL", ""], ["Induced drag coefficient", "CDi", ""], ["Dynamic pressure", "q_Pa", " Pa"]]) {
      if (loads[key] === undefined) continue;
      const value = typeof loads[key] === "number" ? eng(loads[key], 4) : String(loads[key]);
      rows.push(["<td>" + label + "</td><td>" + esc(value + unit) + "</td>"]);
    }
  }
  rows.push(['<td class="section" colspan="2">Congruency checks</td>']);
  for (const [name, detail, ok] of data.checks) {
    const cls = ok ? "check-ok" : "check-bad";
    rows.push(['<td class="' + cls + '">' + (ok ? "✓ " : "✗ ") +
               esc(name) + '</td><td class="' + cls + '">' +
               esc(reportValue(detail)) + "</td>"]);
  }
  rows.push(['<td class="section" colspan="2">Transfer</td>']);
  rows.push(["<td>MsgPack payload</td><td>" +
             (bytes / 1024).toFixed(1) + " kB</td>"]);
  if (data.generate_seconds !== undefined) {
    rows.push(["<td>Julia generation</td><td>" +
               eng(data.generate_seconds,6) + " s</td>"]);
  }
  rows.push(["<td>Round trip</td><td>" + seconds.toFixed(2) + " s</td>"]);

  host.innerHTML = "<table>" +
    rows.map((r) => "<tr>" + r[0] + "</tr>").join("") + "</table>";
}

function esc(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/* --- camera -------------------------------------------------------------- */

function modelCentre() {
  const bb = state.data?WingImportedRender.bounds(state.data,!!state.layers.get("NODES")?.visible):state.bbox;
  if (!bb) return { target: BABYLON.Vector3.Zero(), diag: 10 };
  // Centre in Babylon axes, remembering the permutation.
  const cx = 0.5 * (bb.min[1] + bb.max[1]);
  const cy = 0.5 * (bb.min[2] + bb.max[2]);
  const cz = 0.5 * (bb.min[0] + bb.max[0]);
  const diag = Math.hypot(bb.max[0] - bb.min[0],
                          bb.max[1] - bb.min[1],
                          bb.max[2] - bb.min[2]) || 10;
  return { target: new BABYLON.Vector3(cx, cy, cz), diag: diag };
}

function syncCameraClipping() {
  const camera = state.camera, diag = state.diag;
  if (!camera || !(diag > 0)) return;
  // Fixed metre-sized clip planes destroy depth precision for imported decks
  // expressed in millimetres. Scale with the model and reduce near distance
  // during a close zoom; neither FE coordinates nor source units are changed.
  const radius = Math.max(camera.radius || diag, diag * 1e-8);
  const near = Math.max(diag * 1e-8, Math.min(diag * .001, radius * .01));
  const far = Math.max(diag * 10, radius + diag * 3);
  if (camera.minZ !== near) camera.minZ = near;
  if (camera.maxZ !== far) camera.maxZ = far;
  const canvas=document.getElementById("render"),height=Math.max(1,canvas?.clientHeight||state.engine.getRenderHeight());
  let worldHeight=camera.mode===BABYLON.Camera.ORTHOGRAPHIC_CAMERA?Math.abs(camera.orthoTop-camera.orthoBottom):2*radius*Math.tan(camera.fov/2);
  if(camera.mode!==BABYLON.Camera.ORTHOGRAPHIC_CAMERA&&camera.fovMode===BABYLON.Camera.FOVMODE_HORIZONTAL_FIXED)worldHeight/=Math.max(.01,(canvas?.clientWidth||state.engine.getRenderWidth())/height);
  // ArcRotate accumulates pan in world units, including its inertial tail.
  // Target approximately 0.65 screen pixels per pointer pixel at every scale.
  if(Number.isFinite(worldHeight)&&worldHeight>0)camera.panningSensibility=height/(worldHeight*.65*1.5*Math.max(.001,1-camera.panningInertia));
  camera.lowerRadiusLimit=Math.max(diag*1e-6,1e-10);
}

function fitView() {
  const { target, diag } = modelCentre();
  const camera = state.camera;
  const engine = state.engine;
  const canvas = document.getElementById("render");
  const canvasRect = canvas.getBoundingClientRect ? canvas.getBoundingClientRect() : null;
  const width = canvasRect && canvasRect.width || engine.getRenderWidth();
  const height = canvasRect && canvasRect.height || engine.getRenderHeight();
  const aspect = width / Math.max(height, 1);
  let vertical = camera.fov / 2;
  let horizontal = Math.atan(Math.tan(vertical) * aspect);
  if (camera.fovMode === BABYLON.Camera.FOVMODE_HORIZONTAL_FIXED) {
    horizontal = camera.fov / 2;
    vertical = Math.atan(Math.tan(horizontal) / aspect);
  }
  // Tabs and the control pane are outside the canvas. Its measured dimensions
  // already account for them; reserving their width again would shrink the fit.
  const angle = Math.max(0.02, Math.min(horizontal, vertical));
  // Fit a sphere enclosing the entire bbox. This is valid at every orbit
  // angle and respects both camera FOV conventions and viewport aspect.
  const radius = 0.56 * diag / Math.sin(angle);
  camera.setTarget(target,false,true,true);
  camera.radius = radius;
  camera.upperRadiusLimit = Math.max(12 * diag, radius * 2);
  syncCameraClipping();
  state.viewportTools?.fit();
}

function setView(alpha, beta) {
  for (const key of ["inertialAlphaOffset","inertialBetaOffset","inertialRadiusOffset","inertialPanningX","inertialPanningY"]) state.camera[key] = 0;
  fitView();
  state.camera.alpha = alpha;
  state.camera.beta = beta;
  markStudyViewModified();
}

function syncRibDatums(data = state.data) {
  const sizeInput = document.getElementById("rib-datum-size"), note = document.getElementById("rib-datum-status");
  const side = Number(sizeInput.value), valid = sizeInput.value.trim() !== "" && Number.isFinite(side) && side > 0;
  sizeInput.setAttribute("aria-invalid",String(!valid));
  if (!valid) { if(note)note.textContent="Enter a positive square side length in metres."; state.ribDatums?.setVisible(false); return; }
  if (!state.scene || !data || typeof WingRibDatums === "undefined") return;
  if (!state.ribDatums) state.ribDatums=WingRibDatums.create({scene:state.scene});
  state.ribDatums.update(data,side);
  state.ribDatums.setVisible(document.getElementById("show-rib-datums").checked);
  const count=(data.annotations?.ribs || []).filter(rib=>rib.datum_origin).length;
  if(note)note.textContent=count ? count+" undeformed rib datums. Orange: master ribs; blue: secondary ribs. Side length in metres." : "Create FEM with the updated generator to locate the rib datum squares.";
}

document.getElementById("btn-fit").onclick = fitView;
document.getElementById("btn-iso").onclick =
  () => setView(-Math.PI / 4, Math.acos(1 / Math.sqrt(3)));
document.getElementById("btn-front").onclick =
  () => setView(-Math.PI / 2, Math.PI / 2);   // looking aft along global +X
document.getElementById("btn-top").onclick =
  () => setView(Math.PI / 2, 0.001);          // global +X points down in the right-handed scene

/* --- display controls and picking --------------------------------------- */

function groupIds(group) {
  return group.eids ? asI32(group.eids) : Int32Array.from({ length: group.count }, (_, i) => group.eid_first + i);
}

function modelCases() {
  return state.data && state.data.load_cases && state.data.load_cases.length
    ? state.data.load_cases : [{ id: 1, label: "Load case 1", loads: state.data && state.data.loads }];
}

function activeLoads() {
  const selected = modelCases().find((c) => Number(c.id) === state.activeCase);
  return selected && selected.loads || null;
}

function refreshSupportLayer(data=state.data,positions=currentPositions()) {
  if(!data?.spc||!state.scene)return;
  const previous=state.layers.get('SPC'),visible=previous?.visible??true;
  const selected=data.imported_deck&&WingImportedCases.supports(data,state.activeCase);
  // All support consumers (node inspection, reactions, export) use the same
  // active mask; individual subcase masks remain immutable in load_cases.
  if(selected)data.spc=selected;
  state.supportGlyphs?.dispose();state.supportGlyphs=null;
  for(const mesh of previous?.meshes||[])if(!mesh.isDisposed())mesh.dispose(false,true);
  const nodes=Array.from(asI32(data.spc.nodes));let meshes;
  if(typeof WingSupportGlyphs!=='undefined'){
    state.supportGlyphs=WingSupportGlyphs.create({scene:state.scene,positions,data,radius:markerRadius()});
    meshes=state.supportGlyphs.meshes;for(const mesh of meshes)mesh.parent=state.root;
  }else meshes=markerMesh('SPC',positions,nodes,EXTRA_STYLE.SPC.color,Math.max(markerRadius(),state.diag*1e-8));
  addLayer('SPC',EXTRA_STYLE.SPC.label,EXTRA_STYLE.SPC.color,nodes.length+' nodes'+(state.supportGlyphs?' · '+state.supportGlyphs.counts.total+' DOFs':''),meshes||[]);
  setLayerVisible('SPC',visible);
}

// Contours and force glyphs describe the selected physical solution. The VLM
// geometry follows its displayed shape; pressure coefficients and load plots
// remain the prescribed aerodynamic solution (no aeroelastic recalculation).
function appliedResultLoads() {
  const source = activeLoads(), result = state.results;
  const loads=source?{...source,stations:WingGeometryExport.loadStations(source)}:null;
  if (!loads || state.sensitivityMap || !result?.matches || result.available === false || !result.static) return loads;
  const scale = Number.isFinite(result.loadScale) ? result.loadScale : 1;
  const actual = new Map((result.followerLoading?.forces || []).map(row => [Number(row.grid_id), row]));
  const stations=(loads.stations||[]).slice(),imported=loads.method==="imported";
  const finiteVector=v=>v?.length===3&&v.every(Number.isFinite);
  if(imported&&actual.size){
    // Exactly cancelling source contributions can have no undeformed glyph.
    // Keep those nodes: their follower correction need not remain zero.
    const present=new Set(stations.filter(s=>!s.routed_moment).map(s=>Number(state.nodeIds[s.node_index])));
    const missing=new Set([...actual.keys()].filter(gid=>!present.has(gid)));
    for(let i=0;missing.size&&i<state.nodeIds.length;i++)if(missing.delete(Number(state.nodeIds[i])))
      stations.push({node_index:i,gid:Number(state.nodeIds[i]),target_kind:"imported_grid",source:"imported loads",routed_force:true,force:[0,0,0],moment:[0,0,0]});
  }
  return {...loads, stations:stations.map(station => {
    const row=actual.get(Number(state.nodeIds[station.node_index]));
    let force=station.source === "aerodynamic" && station.follower_forces !== false ? row?.force_basic : null;
    // Imported equivalent nodal loads also contain fixed pressures, body loads
    // and unmarked FORCE cards. Replace only the follower contribution.
    if(imported&&!station.routed_moment&&finiteVector(row?.force_basic)&&finiteVector(row?.reference_force_basic))
      force=station.force.map((v,i)=>v*scale+row.force_basic[i]-row.reference_force_basic[i]);
    return {...station, force:force?.length === 3 && force.every(Number.isFinite) ? force : station.force.map(v => v*scale),
      moment:(station.moment || [0,0,0]).map(v => v*scale),
      source_forces_N:station.source_forces_N?Object.fromEntries(Object.entries(station.source_forces_N).map(([key,vector])=>[key,force?.length===3&&key==="aerodynamic"?force:vector.map(v=>v*scale)])):undefined,
      source_moments_Nm:station.source_moments_Nm?Object.fromEntries(Object.entries(station.source_moments_Nm).map(([key,vector])=>[key,vector.map(v=>v*scale)])):undefined};
  })};
}

function refreshAppliedLoadLayers() {
  if (!state.scene || !state.baseline) return;
  for (const name of ["AERO_LOADS", "AERO_MOMENTS"]) {
    const layer = state.layers.get(name);
    if (!layer) continue;
    state.loadLayerVisibility.set(name, layer.visible);
    const removed = new Set(layer.meshes);
    state.deformable = state.deformable.filter(d => !removed.has(d.mesh));
    layer.meshes.forEach(mesh => mesh.dispose(false,true));
    state.layers.delete(name);
  }
  const loads = appliedResultLoads();
  const attachmentLoads = WingGeometryExport.loadsByNode(loads?.stations);
  for (const element of state.elements.values()) {
    if (element.group.kind !== "rbe3") continue;
    const properties = element.group.properties;
    if(element.group.name==="FUEL_RBE3") {
      const bay=modelCases().find(c=>Number(c.id)===state.activeCase)?.fuel?.bays?.find(b=>Number(b.rbe3_eid)===element.id);
      if(bay)Object.assign(properties,{fuel_mass_kg:bay.mass_kg,fuel_volume_m3:bay.filled_volume_m3,center_of_gravity_m:bay.center_of_gravity_m,inertia_kg_m2:bay.inertia_kg_m2,conm2_eid:bay.conm2_eid});
    }
    delete properties.applied_force_N; delete properties.applied_moment_Nm; delete properties.applied_load_basis;
    delete properties.source_moments_Nm; delete properties.source_forces_N; delete properties.moment_routing_note;
    const station = attachmentLoads.get(Number(element.nodes[0]));
    if (station) {
      properties.applied_force_N = station.force; properties.applied_moment_Nm = station.moment;
      if(station.source_forces_N)properties.source_forces_N=station.source_forces_N;
      if(station.source_moments_Nm)properties.source_moments_Nm=station.source_moments_Nm;
      if(loads.moment_routing_note)properties.moment_routing_note=loads.moment_routing_note;
      properties.applied_load_basis = !state.sensitivityMap && state.results?.matches && state.results.available !== false && state.results.static
        ? resultAnalysisLabel(state.results) + (state.results.followerLoading?.enabled ? " · actual follower force; fixed global moment" : " · fixed global loads") : "Prescribed undeformed loads";
    }
  }
  addAeroLoads(loads); addAeroMoments(loads);
  for (const name of ["AERO_LOADS", "AERO_MOMENTS"])
    if (state.loadLayerVisibility.has(name)) setLayerVisible(name, state.loadLayerVisibility.get(name));
  updateVlmPose(currentPositions(), activeShape()?.rotation,
    activeShape() ? amplitude() * (animating() ? Math.sin(state.phase) : 1) : 0);
}

function refreshLoadPlots() {
  if (typeof WingLoadPlots === "undefined") return;
  const host = document.getElementById("load-plots");
  if (!host) return;
  if (!state.loadPlots) state.loadPlots = WingLoadPlots.create(host, selectLoadCase, markStudyViewModified);
  state.loadPlots.update(state.data ? modelCases() : [], state.activeCase, state.modelDirty);
}

function syncFuelControls() {
  const layer = state.layers.get("FUEL_TANK"), control = document.getElementById("show-fuel-tank");
  if (control) { control.disabled = !layer; control.checked = !!layer?.visible; }
  const button = document.getElementById("btn-isolate-fuel");
  if (button) { button.disabled = !layer; button.textContent = state.fuelIsolation ? "Restore model layers" : "Isolate tank"; }
  syncFuelResultOverlay();
}

function syncFuelResultOverlay(contour = contourValues()) {
  const layer = state.layers.get("FUEL_TANK"), note = document.getElementById("fuel-display-note");
  const suspended = !!(layer?.visible && contour && contour.kind!=="panels");
  if (layer) for (const mesh of layer.meshes) mesh.setEnabled(layer.visible && !suspended);
  if (note) note.textContent = suspended ? "Fuel overlay is hidden while FE result colors are active." : "";
}

function addFuelTank(fuel) {
  const surface = fuel?.enabled && fuel.surface;
  if (surface?.count) {
    const mesh = shellMesh("FUEL_TANK", permute(asF32(surface.xyz)), asI32(surface.conn), 3,
      EXTRA_STYLE.FUEL_TANK.color, .42, false);
    mesh.renderingGroupId = 1; mesh.isPickable = false;
    // The capacity envelope meets the shell midsurfaces. A small depth bias
    // avoids flicker on their common boundary; opaque skins still hide its back.
    mesh.material.zOffset = -1;
    addLayer("FUEL_TANK", EXTRA_STYLE.FUEL_TANK.label, EXTRA_STYLE.FUEL_TANK.color,
      eng(fuel.volume_litres, 5) + " L", [mesh]);
  }
  syncFuelControls();
}

function restoreFuelIsolation() {
  const saved=state.fuelIsolation;if(!saved)return false;
  state.fuelIsolation=null;const batching=state.edgeUpdateBatch;state.edgeUpdateBatch=true;
  try{for(const [name,visible]of saved)setLayerVisible(name,visible);}
  finally{state.edgeUpdateBatch=batching;if(!batching){syncMeshEdges();syncLayerGroupControls();}}
  syncFuelControls();return true;
}

function isolateFuelTank() {
  if (!state.layers.has("FUEL_TANK")) return;
  if (state.fuelIsolation) {
    restoreFuelIsolation();
  } else {
    // Only one temporary isolation may own structural visibility at a time.
    if(state.panelView)setPanelDisplay(false);
    state.propertyDisplay?.setEnabled(false);
    clearSensitivityMap();
    state.fuelIsolation = new Map(Array.from(state.layers, ([name, layer]) => [name, layer.visible]));
    state.contourIdx = 0;
    document.getElementById("contour-select").value = "0";
    applyContour();
    enforceFuelIsolation();
  }
  syncFuelControls();
}

function enforceFuelIsolation() {
  if (!state.fuelIsolation) return;
  for (const name of state.layers.keys()) setLayerVisible(name, name === "FUEL_TANK");
}

function rebuildVlmForceArrows() {
  const input = document.getElementById("vlm-force-scale"), note = document.getElementById("vlm-force-scale-note");
  const multiplier = input ? Number(input.value) : 1;
  if (!(multiplier >= .01 && multiplier <= 100)) {
    input?.setCustomValidity?.("Choose an arrow multiplier from 0.01 to 100.");
    if (note) note.textContent = "Choose an arrow multiplier from 0.01 to 100; existing arrows are retained.";
    return;
  }
  input?.setCustomValidity?.("");
  const previous = state.layers.get("VLM_FORCES");
  const visible = previous?.visible ?? state.loadLayerVisibility.get("VLM_FORCES") ?? false;
  previous?.meshes.forEach(mesh => mesh.dispose(false, true));
  state.layers.delete("VLM_FORCES");
  const vlm = activeLoads()?.vlm;
  if (!vlm?.xyz || !vlm.conn || !state.scene) {
    if (note) note.textContent = "Panel arrows are available for Aerodynamic (VLM) cases after mesh creation.";
    syncVlmControls(); return;
  }
  let maxForce=0;
  for(const c of modelCases())maxForce=Math.max(maxForce,WingLoadGlyphs.panelNormalForces(c.loads?.vlm).peak);
  const normalLoads=WingLoadGlyphs.panelNormalForces(vlm),scale=maxForce>0?state.diag*.1*multiplier/maxForce:0,points=[],glyphs=[];
  for(const record of normalLoads.records){
    const vertices=WingLoadGlyphs.vectorArrow(record.force,{scale,diag:state.diag});if(!vertices.length)continue;
    const first_vertex=points.length/3;
    for(const p of vertices)points.push(record.position[1]+p[1],record.position[2]+p[2],record.position[0]+p[0]);
    glyphs.push({...record,first_vertex,vertex_count:vertices.length,scale});
  }
  const mesh=lineMesh("VLM_FORCES",Float32Array.from(points),Int32Array.from({length:points.length/3},(_,i)=>i),EXTRA_STYLE.VLM_FORCES.color,1,false);
  if(mesh){mesh.renderingGroupId=2;mesh.metadata={forceScale:scale,multiplier,panelCount:vlm.count,glyphs,force_basis:"signed panel-normal pressure force",invalidPanels:normalLoads.invalid};
    const centers=Float32Array.from(glyphs.flatMap(g=>[g.position[1],g.position[2],g.position[0]]));
    mesh.vlmPose={bindings:WingVlmDeformation.attach(centers,activeLoads()?.stations,state.baseline,
      {etas:glyphs.map(g=>activeLoads()?.panels?.[g.panel_id-1]?.eta)}),buf:Float32Array.from(points)};}
  addLayer("VLM_FORCES",EXTRA_STYLE.VLM_FORCES.label,EXTRA_STYLE.VLM_FORCES.color,glyphs.length+" normal arrows",mesh?[mesh]:[]);
  setLayerVisible("VLM_FORCES",visible);
  updateVlmPose(currentPositions(),activeShape()?.rotation,activeShape()?amplitude()*(animating()?Math.sin(state.phase):1):0);
  if(note)note.textContent=(maxForce>0?eng(scale,5)+" m/N; common scale across cases. Magenta arrows show signed panel-normal pressure force. Origins follow the displayed shape; follower directions use the actual solved rotations, not exaggerated display rotations. Fixed loads keep their global directions. The full force remains applied at the RBE3s; no aerodynamic recomputation is performed.":"All panel-normal forces are zero; no arrows are drawn.")+
    (normalLoads.invalid.length?" "+normalLoads.invalid.length+" invalid panel geometries/loads were omitted.":"");
}

/** Reuse the existing VLM meshes; deformation never rebuilds the model or
 * allocates one draw call per aerodynamic panel. Geometry is display-scaled,
 * force directions/magnitudes describe the accepted physical result. */
function updateVlmPose(positions=state.baseline,rotations=null,rotationScale=0) {
  if(!positions||!state.baseline||typeof WingVlmDeformation==='undefined')return;
  const pose=state.vlm?.pose;
  if(pose){
    for(let i=0;i<pose.bindings.length;i++)pose.buf.set(WingVlmDeformation.point(pose.bindings[i],state.baseline,positions,rotations,rotationScale),3*i);
    for(const item of pose.meshes){const mesh=item.mesh;if(!mesh||mesh.isDisposed())continue;
      const buf=item.map?item.buf:pose.buf;
      if(item.map)for(let i=0;i<item.map.length;i++)buf.set(pose.buf.subarray(3*item.map[i],3*item.map[i]+3),3*i);
      mesh.updateVerticesData(BABYLON.VertexBuffer.PositionKind,buf,true,false);updateSurfaceNormals(mesh,buf);}
  }
  const result=!state.sensitivityMap&&state.activeMode<0&&state.results?.matches&&state.results.available!==false&&state.results.static?state.results:null;
  const loading=result?.followerLoading,followers=loading?.enabled?new Map((loading.forces||[]).map(row=>[Number(row.grid_id),row.rotation_basic])):null;
  const scale=Number.isFinite(result?.loadScale)?result.loadScale:1;
  for(const mesh of state.layers.get('VLM_FORCES')?.meshes||[]){
    const data=mesh.vlmPose;if(!data)continue;
    const glyphs=mesh.metadata.glyphs;
    for(let i=0;i<glyphs.length;i++){
      const glyph=glyphs[i],binding=data.bindings[i],center=WingVlmDeformation.point(binding,state.baseline,positions,rotations,rotationScale);
      const force=WingVlmDeformation.force(glyph.force,binding,{scale,followers,linear:loading?.mode==='first_order'});
      const vertices=WingLoadGlyphs.vectorArrow(force,{scale:mesh.metadata.forceScale,diag:state.diag});
      for(let j=0;j<glyph.vertex_count;j++){const p=vertices[j]||[0,0,0];data.buf.set([center[0]+p[1],center[1]+p[2],center[2]+p[0]],3*(glyph.first_vertex+j));}
      glyph.display_force=force;glyph.display_position=[center[2],center[0],center[1]];
    }
    mesh.updateVerticesData(BABYLON.VertexBuffer.PositionKind,data.buf,true,false);
    mesh.metadata.force_basis=followers?'Prescribed panel-normal force rotated with solved rib reference rotations':'Prescribed panel-normal force in fixed global axes';
    mesh.metadata.physical_load_scale=scale;
  }
}

function buildCaseSelectors() {
  const cases = modelCases();
  for (const id of ["load-case-select", "result-case-select", "vlm-case-select"]) {
    const select = document.getElementById(id); select.innerHTML = "";
    for (const c of cases) {
      const option = document.createElement("option"); option.value = String(c.id);
      option.textContent = c.id + " · " + c.label; select.appendChild(option);
    }
    select.value = String(state.activeCase);
    select.disabled = cases.length < 2;
  }
  document.getElementById("result-case-control").hidden = cases.length < 2;
  state.importedCases?.refresh();
  syncVlmControls();
  refreshLoadPlots();
}

function selectLoadCase(id,{preserveSensitivity=false}={}) {
  const sensitivityContour=preserveSensitivity?state.sensitivityMap?.contour:null;
  restoreHistoricalBaselineOverlays();
  clearSensitivityMap();
  if (!modelCases().some((c) => Number(c.id) === Number(id))) id = modelCases()[0]?.id||1;
  restoreBaseline();
  state.activeCase = Number(id);
  if(state.data?.imported_deck)refreshSupportLayer(state.data,state.baseline);
  const commonModes = state.resultCases && state.resultCases.get(1);
  const record = state.resultCases && (state.resultCases.get(state.activeCase) ||
    (state.resultsLoadCaseIndependent && commonModes && commonModes.modeKind === "frequency" ? commonModes : null));
  state.results = record?.variants ? record.variants.get(state.resultVariantPreference || record.defaultVariant) || record.variants.values().next().value : record;
  state.activeMode = -1; state.contourIdx = 0;
  refreshLoadLayers();
  refreshWeights();
  refreshFuelMassProperties();
  buildCaseSelectors(); buildLayerPanel(); applySurfaceMode();
  if (state.results) {
    document.getElementById("report-text").textContent = state.results.report;
    showResults();
  } else {
    document.getElementById("results-card").hidden = true;
    applyContour(); syncResultOverlays();
    syncAnalysisControls();
  }
  if (state.data) showStats(state.data, state.lastTransfer.bytes, state.lastTransfer.seconds);
  if (state.selectedElement !== null) showElement(state.selectedElement);
  if (state.selectedNode !== null) showNode(state.selectedNode);
  if(sensitivityContour)displaySensitivityContour(sensitivityContour);
}

function refreshLoadLayers() {
  const visibility = state.loadLayerVisibility;
  for (const name of ["AERO_LOADS", "AERO_MOMENTS", "VLM_MESH", "VLM_PRESSURE", "VLM_FORCES"]) {
    const layer = state.layers.get(name);
    if (!layer) continue;
    if (name !== "VLM_PRESSURE") visibility.set(name, layer.visible);
    const removed = new Set(layer.meshes);
    state.deformable = state.deformable.filter((d) => !removed.has(d.mesh));
    layer.meshes.forEach((mesh) => mesh.dispose(false, true));
    state.layers.delete(name);
  }
  const loads = activeLoads();
  refreshAppliedLoadLayers(); addVlm(loads && loads.vlm);
  rebuildVlmForceArrows();
  for (const [name, visible] of visibility) setLayerVisible(name, visible);
  applyVlmContour();
  enforceFuelIsolation();
}

function arrowVertices(vector) {
  const length = vector.length();
  if (!(length > 0)) return [];
  const direction = vector.normalizeToNew();
  const side = BABYLON.Vector3.Cross(direction, Math.abs(direction.y) < 0.9 ? BABYLON.Axis.Y : BABYLON.Axis.X).normalize();
  const head = Math.min(length * 0.25, state.diag * 0.014);
  const back = vector.subtract(direction.scale(head));
  return [BABYLON.Vector3.Zero(), vector, vector, back.add(side.scale(head * 0.45)), vector, back.subtract(side.scale(head * 0.45))];
}

function addElementAxes(groups) {
  for(const unused of elementAxesSteps(groups)) { /* synchronous callers */ }
}

function* elementAxesSteps(groups) {
  for (const [kind, name] of [["shell", "SHELL_AXES"], ["bar", "BAR_AXES"]]) {
    const meshes = []; let count = 0;
    for (const axis of (kind === "bar" ? ["x", "y", "z"] : ["x"])) {
      yield "Preparing "+kind+" local "+axis+" axes…";
      const points = [], offsets = [], centers = [];
      for (const g of groups) {
        if ((g.kind === "bar") !== (kind === "bar") || !g.axes || !g.axes[axis]) continue;
        const directions = permute(asF32(g.axes[axis])), origins = permute(asF32(g.axes.centers)), ids=groupIds(g);
        const conn = asI32(g.conn), stride = g.n_per_elem || (g.kind === "quad" ? 4 : g.kind === "tria" ? 3 : 2);
        for (let e = 0; e < g.count; e++) {
          const nodes = conn.slice(e * stride, (e + 1) * stride);
          const origin = vec(origins, e);
          let size = Infinity;
          for (let n = 0; n < nodes.length - 1; n++) size = Math.min(size, BABYLON.Vector3.Distance(vec(state.baseline, nodes[n]), vec(state.baseline, nodes[n + 1])));
          const direction = vec(directions, e).normalize().scale(Math.min(size * 0.28, state.diag * 0.025));
          const vertices = arrowVertices(direction), start = points.length / 3;
          for (const v of vertices) { points.push(origin.x + v.x, origin.y + v.y, origin.z + v.z); offsets.push(v.x, v.y, v.z); }
          centers.push({ nodes, start, count: vertices.length, origin, eid:ids[e] });
          if (axis === "x") count++;
        }
      }
      const mesh = lineMesh(name + "-" + axis, Float32Array.from(points), Int32Array.from({ length: points.length / 3 }, (_, i) => i),
        { x: "#ef5f6b", y: "#4cc38a", z: "#56a8f5" }[axis], 1, false);
      if (mesh) {
        mesh.renderingGroupId = 2; meshes.push(mesh);
        state.deformable.push({ mesh, axisCenters: centers, offsets: Float32Array.from(offsets), buf: Float32Array.from(points) });
      }
    }
    if (meshes.length) addLayer(name, EXTRA_STYLE[name].label, EXTRA_STYLE[name].color, count + " frames", meshes);
  }
}

function addVlm(vlm) {
  state.vlm = null;
  document.getElementById("vlm-controls").hidden = !vlm || !vlm.count;
  if (!vlm || !vlm.count) return;
  const original = permute(asF32(vlm.xyz)), conn = asI32(vlm.conn), points = new Float32Array(conn.length * 3), pairs = [];
  for (let i = 0; i < conn.length; i++) points.set(original.subarray(3 * conn[i], 3 * conn[i] + 3), 3 * i);
  for (let e = 0; e < vlm.count; e++) for (let n = 0; n < 4; n++) pairs.push(4 * e + n, 4 * e + (n + 1) % 4);
  const edges = lineMesh("VLM_MESH", points, Int32Array.from(pairs), EXTRA_STYLE.VLM_MESH.color, 1, false);
  if (edges) edges.renderingGroupId = 2;
  addLayer("VLM_MESH", EXTRA_STYLE.VLM_MESH.label, EXTRA_STYLE.VLM_MESH.color, vlm.count + " panels", edges ? [edges] : []);
  const mesh = shellMesh("VLM_PRESSURE", points, Int32Array.from({ length: conn.length }, (_, i) => i), 4, "#ffffff", 0.85, false);
  mesh.renderingGroupId = 1;
  mesh.material.disableLighting = true; mesh.material.emissiveColor = BABYLON.Color3.White();
  addLayer("VLM_PRESSURE", EXTRA_STYLE.VLM_PRESSURE.label, EXTRA_STYLE.VLM_PRESSURE.color, vlm.count + " panels", [mesh]);
  // Physical y = root y + eta * half-span. Use the original panel station
  // metadata to recover this affine relation, including nonzero root offsets.
  // An oblique rib reference center is not generally at its nominal eta.
  const stations=(activeLoads()?.panels||[]).filter(p=>Number.isFinite(p.eta)&&Number.isFinite(p.position?.[1])).sort((a,b)=>a.eta-b.eta),first=stations[0],last=stations.at(-1);
  const halfSpan=last&&last.eta>first.eta?(last.position[1]-first.position[1])/(last.eta-first.eta):NaN,rootY=first?first.position[1]-first.eta*halfSpan:NaN;
  const etas=halfSpan>0?Array.from({length:points.length/3},(_,i)=>(points[3*i]-rootY)/halfSpan):null;
  state.vlm = { mesh, pressure: vlm.pressure ? asF32(vlm.pressure) : null, cp: vlm.cp ? asF32(vlm.cp) : null, count: vlm.count,
    pose:{meshes:[{mesh:edges,map:Int32Array.from(pairs),buf:new Float32Array(pairs.length*3)},{mesh}],buf:new Float32Array(points),bindings:WingVlmDeformation.attach(points,activeLoads()?.stations,state.baseline,{etas})} };
  updateVlmPose(currentPositions(),activeShape()?.rotation,activeShape()?amplitude()*(animating()?Math.sin(state.phase):1):0);
}

function vlmColorRange(field,values){
  let min=Infinity,max=-Infinity;for(const value of values||[])if(Number.isFinite(value)){min=Math.min(min,value);max=Math.max(max,value);}
  const limitKey=JSON.stringify(["vlm",field]);
  return{limitKey,...WingLegends.resolveLimits(limitKey,min,max)};
}

function applyVlmContour() {
  const host = document.getElementById("vlm-legend"); WingLegends.render(host,[]);
  if (!state.vlm) { syncVlmControls(); return; }
  const field = document.getElementById("vlm-field").value || "none";
  const values = state.vlm[field];
  setLayerVisible("VLM_PRESSURE", field !== "none" && !!values);
  if (field === "none" || !values) { syncVlmControls(); return; }
  const {min,max,limitKey}=vlmColorRange(field,values);
  if (!Number.isFinite(min)||!Number.isFinite(max)) { syncVlmControls(); return; }
  const colors = new Float32Array(state.vlm.count * 16);
  for (let e = 0; e < state.vlm.count; e++) {
    const rgb = Number.isFinite(values[e]) ? cmap(max > min ? (values[e] - min) / (max - min) : 0.5,"vlm") : [0.32, 0.32, 0.32];
    for (let n = 0; n < 4; n++) colors.set([...rgb, 1], 16 * e + 4 * n);
  }
  state.vlm.mesh.updateVerticesData(BABYLON.VertexBuffer.ColorKind, colors, false, false);
  const current=modelCases().find(c=>Number(c.id)===state.activeCase);
  WingLegends.render(host,[{kind:"vlm",limitKey,title:field==="pressure"?"VLM pressure jump":"VLM Cp jump",unit:field==="pressure"?"Pa":"dimensionless",min,max,
    caseLabel:"Case "+state.activeCase+(current?.label?" · "+current.label:""),gradient:contourGradient(min,max,"vlm"),note:"Lower minus upper · prescribed pressure; lattice follows displayed shape"}]);
  syncVlmControls();
}

function syncVlmControls() {
  const field = document.getElementById("vlm-field")?.value || "none";
  const visible = !!state.layers.get("VLM_MESH")?.visible;
  const pressureVisible = !!state.layers.get("VLM_PRESSURE")?.visible;
  for (const [suffix, value] of [["mesh", "none"], ["pressure", "pressure"], ["cp", "cp"]]) {
    const button = document.getElementById("btn-vlm-" + suffix); if (!button) continue;
    button.disabled = !state.vlm || value !== "none" && !state.vlm[value];
    button.setAttribute("aria-pressed", String(value === "none" ? visible && !pressureVisible : pressureVisible && field === value));
  }
  const hide = document.getElementById("btn-vlm-hide"); if (hide) hide.disabled = !state.vlm;
  for (const [id, layerName] of [["vlm-show-forces", "AERO_LOADS"], ["vlm-show-moments", "AERO_MOMENTS"], ["show-vlm-panel-forces", "VLM_FORCES"]]) {
    const control = document.getElementById(id), layer = state.layers.get(layerName); if (!control) continue;
    control.checked = !!layer?.visible; control.disabled = !layer;
  }
  const legend = document.getElementById("vlm-view-legend");
  if (legend) WingLegends.render(legend,pressureVisible?WingLegends.entries(document.getElementById("vlm-legend")):[]);
  const status = document.getElementById("vlm-view-status");
  const warning = document.getElementById("vlm-model-warning");
  if (warning) {
    const warnings = activeLoads()?.summary?.warnings || [];
    warning.textContent = Array.isArray(warnings) ? warnings.join("\n") : String(warnings);
    warning.hidden = !warning.textContent;
  }
  if (status) {
    const summary = activeLoads()?.summary;
    status.textContent = !state.data ? "Create the model to display its aerodynamic lattice." : !state.vlm ?
      "This case uses prescribed lift. Choose an Aerodynamic (VLM) case, or define one in Cases." :
      state.vlm.count + " panels" + (summary?.lift_N === undefined ? "" : " · Lift " + eng(summary.lift_N, 5) + " N") +
      (summary?.CL === undefined ? "" : " · CL " + eng(summary.CL, 4));
  }
  updateViewportLegends();
}

function setVlmView(field) {
  if (!state.vlm) return;
  document.getElementById("vlm-field").value = field === "hide" ? "none" : field;
  setLayerVisible("VLM_MESH", field !== "hide");
  applyVlmContour();
  syncVlmControls();
}

function applyBackgroundColor(hex, remember = true) {
  if (!/^#[0-9a-f]{6}$/i.test(hex)) return false;
  const control = document.getElementById("background-color"); if (control) control.value = hex;
  const rgb = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255);
  if (state.scene) state.scene.clearColor = new BABYLON.Color4(...rgb, 1);
  const viewport = document.getElementById("viewport"); if (viewport) viewport.style.background = hex;
  const hint = document.getElementById("viewport-hint");
  if (hint) hint.style.color = .2126 * rgb[0] + .7152 * rgb[1] + .0722 * rgb[2] > .5 ? "#314458" : "#99adbf";
  if (remember) try { localStorage.setItem("wingfegen-background", hex); } catch (_) {}
  return true;
}

/** Batch signed global components by axis, retaining node maps for deformation. */
function loadComponentMeshes(name, records, {kind="force", scale=1, peak=1, multiplier=1, positions=state.baseline, renderingGroup=2, metadata={}}={}) {
  const batches=WingLoadGlyphs.AXES.map((axis,component)=>({axis,component,points:[],offsets:[],nodes:[],glyphs:[],records:[]}));
  for(const station of records){
    const center=station.position ? new BABYLON.Vector3(station.position[1],station.position[2],station.position[0]) : vec(positions,station.node_index);
    for(const glyph of WingLoadGlyphs.components(station[kind],{kind,scale,peak,multiplier,diag:state.diag})){
      const batch=batches[glyph.component],first=batch.points.length/3;
      for(const vertex of glyph.vertices){const offset=[vertex[1],vertex[2],vertex[0]];batch.points.push(center.x+offset[0],center.y+offset[1],center.z+offset[2]);batch.offsets.push(...offset);batch.nodes.push(station.node_index);}
      const {vertices,...description}=glyph;
      batch.glyphs.push({...description,node_index:station.node_index,panel_id:station.panel_id,first_vertex:first,vertex_count:glyph.vertices.length});batch.records.push(station);
    }
  }
  const meshes=[];
  for(const batch of batches){
    if(!batch.points.length)continue;
    const points=Float32Array.from(batch.points),mesh=lineMesh(name+"_"+batch.axis,points,Int32Array.from({length:points.length/3},(_,i)=>i),WingLoadGlyphs.COLORS[batch.component],1,false);
    mesh.renderingGroupId=renderingGroup;mesh.metadata={...metadata,axis:batch.axis,component:batch.component,glyphs:batch.glyphs,applied_loads:batch.records};
    if(batch.nodes.every(Number.isInteger))state.deformable.push({mesh,map:Int32Array.from(batch.nodes),offsets:Float32Array.from(batch.offsets),buf:points});
    meshes.push(mesh);
  }
  return meshes;
}

function addAeroLoads(loads) {
  if(!loads?.stations?.length)return;
  let peak=0;for(const station of loads.stations)peak=Math.max(peak,Math.hypot(...station.force));
  if(!(peak>0))return;
  const meshes=loadComponentMeshes("AERO_LOADS",loads.stations,{scale:.09*state.diag/peak,renderingGroup:1});
  const count=meshes.reduce((n,m)=>n+m.metadata.glyphs.length,0);
  addLayer("AERO_LOADS",EXTRA_STYLE.AERO_LOADS.label,EXTRA_STYLE.AERO_LOADS.color,count+" components",meshes);
}

/** Native SPC reactions in BASIC axes; display only actual modeled supports. */
function rebuildSupportForces() {
  state.annotations?.invalidate();
  const old=state.layers.get("SUPPORT_FORCES");
  if(old){const removed=new Set(old.meshes);state.deformable=state.deformable.filter(d=>!removed.has(d.mesh));old.meshes.forEach(mesh=>mesh.dispose(false,true));state.layers.delete("SUPPORT_FORCES");}
  const control=document.getElementById("show-support-forces"),note=document.getElementById("support-force-note");
  const result=state.results,reactions=result?.matches&&result.available!==false&&state.activeMode<0?result.reactions:null;
  if(control)control.disabled=!reactions;
  document.getElementById("show-support-force-values").disabled=!reactions;
  if(!reactions||!state.baseline||!state.data?.spc){if(note)note.textContent=state.activeMode>=0?"Support reactions are available for static solutions.":"No support reactions are available for this result.";return;}
  const supports=new Set(asI32(state.data.spc.nodes)),records=[];let peak=0,momentPeak=0;
  for(let i=0;i<reactions.nodes.length;i++){
    const node_index=reactions.nodes[i],force=Array.from(reactions.forces.subarray(3*i,3*i+3)),moment=reactions.moments?Array.from(reactions.moments.subarray(3*i,3*i+3)):[0,0,0];
    if(!supports.has(node_index)||force.length!==3||!force.every(Number.isFinite)||moment.length!==3||!moment.every(Number.isFinite))continue;
    peak=Math.max(peak,Math.hypot(...force));momentPeak=Math.max(momentPeak,...moment.map(Math.abs));records.push({node_index,force,moment});
  }
  const requested=Number(document.getElementById("support-force-scale")?.value),multiplier=Number.isFinite(requested)&&requested>0?Math.min(100,Math.max(.01,requested)):1;
  const scale=peak>0?.09*state.diag*multiplier/peak:0;
  const meshes=[...loadComponentMeshes("SUPPORT_FORCES",records,{scale,positions:currentPositions()}),...loadComponentMeshes("SUPPORT_MOMENTS",records,{kind:"moment",peak:momentPeak,multiplier,positions:currentPositions()})];
  const count=meshes.reduce((n,m)=>n+m.metadata.glyphs.length,0);
  addLayer("SUPPORT_FORCES",EXTRA_STYLE.SUPPORT_FORCES.label,EXTRA_STYLE.SUPPORT_FORCES.color,count+" components",meshes);
  setLayerVisible("SUPPORT_FORCES",control?.checked!==false);
  if(note)note.textContent=resultAnalysisLabel(result)+": support forces use straight arrows; support moments use right-hand arcs. Global X red, Y green, Z blue. Peak force "+eng(peak,5)+" N; arrow scale "+eng(scale,4)+" m/N. Peak moment component "+eng(momentPeak,5)+" Nm. Inspect a supported GRID for signed values; glyph size does not change the result.";
}

function addAeroMoments(loads) {
  if(!loads?.stations?.length)return;
  let peak=0;for(const station of loads.stations)for(const value of station.moment||[])peak=Math.max(peak,Math.abs(value));
  if(!(peak>0))return;
  const meshes=loadComponentMeshes("AERO_MOMENTS",loads.stations,{kind:"moment",peak,metadata:{moment_routing_note:loads.moment_routing_note}});
  const count=meshes.reduce((n,m)=>n+m.metadata.glyphs.length,0);
  addLayer("AERO_MOMENTS",EXTRA_STYLE.AERO_MOMENTS.label,EXTRA_STYLE.AERO_MOMENTS.color,count+" components",meshes);
}

function positiveRadius(id) {
  const value = Number(document.getElementById(id).value);
  return Number.isFinite(value) && value >= 0 ? value : 0;
}
function nodeRadius() { return positiveRadius("node-radius"); }
function markerRadius() { return positiveRadius("marker-radius"); }

function currentPositions() {
  return activeShape() ? state.deformed : state.baseline;
}

function updateMarkerRadii() {
  refreshFuelMassProperties();
  state.geometryTools?.updateRadii();
  state.supportGlyphs?.update({positions:currentPositions(),radius:markerRadius()});
  for (const marker of state.markers) {
    const radius = marker.kind === "NODES" ? nodeRadius() : markerRadius();
    marker.mesh.scaling.setAll(radius / marker.originalRadius);
  }
}

function applySurfaceMode() {
  const solid = document.getElementById("surface-mode").value === "solid";
  state.transparency?.setEnabled(!solid);
  const translucency=Number(document.getElementById("surface-translucency").value),structuralAlpha=1-Math.max(0,Math.min(100,Number.isFinite(translucency)?translucency:45))/100;
  document.getElementById("surface-translucency-control").hidden=solid;
  const visited=new Set();
  for (const [name, layer] of state.layers) {
    if (name === "REFERENCE_AERO") continue;
    // The loft is a context overlay. Making it opaque hides skin elements
    // (especially runout triangles) wherever the two surfaces overlap.
    const opaque = solid && name !== "AERO_SURFACE" && name !== "FUEL_TANK";
    for (const mesh of layer.meshes) {
      if(visited.has(mesh))continue;visited.add(mesh);
      if (mesh.translucentAlpha === undefined) continue;
      if(["quad","tria"].includes(mesh.metadata?.feGroup?.kind))mesh.material.wireframe=false;
      mesh.hasVertexAlpha = false;
      mesh.material.alpha = opaque ? 1 : mesh.metadata?.feGroup&&["quad","tria"].includes(mesh.metadata.feGroup.kind)?structuralAlpha:mesh.translucentAlpha;
      mesh.material.transparencyMode = mesh.material.alpha===1 ? BABYLON.Material.MATERIAL_OPAQUE : BABYLON.Material.MATERIAL_ALPHABLEND;
      mesh.material.separateCullingPass = !opaque && !state.transparency?.enabled;
      mesh.material.disableDepthWrite = false;
    }
  }
  applyBarDepthPolicy();
  applyAeroOverlayStyles();
  state.annotations?.invalidate();
  state.viewportTools?.syncDisplay();
}

function applyBarDepthPolicy() {
  const through = !!document.getElementById("show-bars-through")?.checked;
  state.scene?.setRenderingAutoClearDepthStencil(BAR_RENDER_GROUP, through, true, true);
  state.annotations?.invalidate();
}

function aeroContourProtection(){
  const options=contourOptions(),selected=options[Math.min(state.contourIdx,options.length-1)];
  const hasContour=!!state.propertyDisplay?.enabled||!!state.sensitivityMap||!!state.panelView||!!selected&&selected.kind!=="none"||workspaceUI.activeTab==="results"&&!!activeShape();
  return hasContour && (state.data?.groups||[]).some(group=>["quad","tria"].includes(group.kind)&&state.layers.get(group.name)?.visible);
}
function aeroSurfaceStyle(){
  const style=document.getElementById("aero-deformed-style")?.value||"auto";
  return style==="auto"||style==="steel"?(aeroContourProtection()?"wireframe":activeShape()?"steel":"translucent"):style==="metallic"?"steel":style;
}
function applyAeroOverlayStyles() {
  const deformed=!!activeShape(),style=aeroSurfaceStyle();
  for (const mesh of state.layers.get("AERO_SURFACE")?.meshes || []) {
    const steel=state.aeroDisplay?.apply(mesh,{deformed,style});
    if(steel)continue;
    mesh.material.wireframe=style==="wireframe";
    mesh.material.alpha=style==="wireframe" ? .75 : mesh.translucentAlpha;
    mesh.material.transparencyMode=BABYLON.Material.MATERIAL_ALPHABLEND;
    mesh.material.separateCullingPass=style!=="wireframe"&&!state.transparency?.enabled;
    mesh.material.disableDepthWrite=false;
  }
  for (const mesh of state.layers.get("REFERENCE_AERO")?.meshes || []) {
    mesh.material.wireframe=false; mesh.material.alpha=mesh.translucentAlpha;
    mesh.material.transparencyMode=BABYLON.Material.MATERIAL_ALPHABLEND;
  }
  syncAeroOverlayControl();
}

function syncResultOverlays() {
  const deformed = !!activeShape();
  applyAeroOverlayStyles();
  for (const [name, id] of [["UNDEFORMED", "show-undeformed"], ["REFERENCE_AERO", "show-reference-aero"]]) {
    const layer = state.layers.get(name);
    if (!layer) continue;
    const on = deformed && document.getElementById(id).checked;
    layer.visible = on;
    layer.meshes.forEach((mesh) => mesh.setEnabled(on));
    const cb = document.getElementById("layer-" + name);
    if (cb) cb.checked = on;
  }
  const aero = state.layers.get("AERO_SURFACE");
  if (aero && deformed) {
    const on = document.getElementById("show-deformed-aero").checked;
    aero.visible = on;
    aero.meshes.forEach((mesh) => mesh.setEnabled(on));
    const cb = document.getElementById("layer-AERO_SURFACE");
    if (cb) cb.checked = on;
  }
  syncAeroOverlayControl();
  enforcePanelIsolation();
  syncMeshEdges();
  applyBeamStyle();
  rebuildComparisonOverlay();
  syncLayerGroupControls();
  syncHistoricalBaselineOverlays();
}

function restoreHistoricalBaselineOverlays(){
  for(const [name,on]of state.historicalBaselineOverlays||[]){const layer=state.layers.get(name);if(!layer)continue;layer.visible=on;for(const mesh of layer.meshes)mesh.setEnabled(on);}
  state.historicalBaselineOverlays=null;
}

function syncHistoricalBaselineOverlays(){
  if(state.sensitivityMap)return;
  if(state.results?.source!=="sensitivity_baseline"||!state.results.historical){if(state.historicalBaselineOverlays){restoreHistoricalBaselineOverlays();syncLayerGroupControls();}return;}
  state.historicalBaselineOverlays??=new Map();
  let changed=false;
  for(const name of ["AERO_LOADS","AERO_MOMENTS","VLM_FORCES","VLM_PRESSURE"]){
    const layer=state.layers.get(name);if(!layer)continue;
    if(!state.historicalBaselineOverlays.has(name))state.historicalBaselineOverlays.set(name,layer.visible);
    changed=changed||layer.visible;layer.visible=false;for(const mesh of layer.meshes)if(mesh.isEnabled())mesh.setEnabled(false);
    const checkbox=document.getElementById("layer-"+name);if(checkbox)checkbox.checked=false;
  }
  if(changed){syncLayerGroupControls();updateViewportLegends();}
}

function installPanels() {
  for (const id of ["sidebar", "hud-left", "model-card", "results-card", "pick-card", "log-wrap", "deck-panel"]) {
    const panel = document.getElementById(id);
    if (!panel) continue;
    const title = panel.querySelector(".hud-title");
    if (!title) continue;
    const toggle = document.createElement("button");
    const panelName = id === "sidebar" ? "options pane" : title.textContent.trim().split("\n")[0];
    toggle.className = "mini panel-toggle";
    toggle.textContent = "−";
    toggle.title = "Hide panel";
    toggle.setAttribute("aria-label", "Hide " + panelName);
    toggle.setAttribute("aria-expanded", "true");
    toggle.setAttribute("aria-controls", id);
    toggle.onclick = () => {
      const collapsed = panel.classList.toggle("panel-collapsed");
      toggle.textContent = collapsed ? "+" : "−";
      toggle.title = collapsed ? "Show panel" : "Hide panel";
      toggle.setAttribute("aria-label", (collapsed ? "Show " : "Hide ") + panelName);
      toggle.setAttribute("aria-expanded", String(!collapsed));
      if (id === "sidebar") {
        document.getElementById("app").classList.toggle("sidebar-collapsed", collapsed);
        if (collapsed) setWorkspaceMaximized(null);
        if (state.engine) state.engine.resize();
      }
    };
    title.prepend(toggle);
  }
}

function expandPanel(id) {
  const panel = document.getElementById(id);
  if (!panel) return;
  panel.hidden = false;
  if (panel.classList.contains("panel-collapsed")) panel.querySelector(".panel-toggle").click();
  if (WORKSPACE_CARD_TAB[id]) activateWorkspaceTab(WORKSPACE_CARD_TAB[id]);
}

function setLogMaximized(on) {
  setWorkspaceMaximized(on ? "log" : null);
}

function syncDrawingMaximizeButton() {
  const button = document.getElementById("btn-max-drawing");
  if (!button) return;
  button.hidden = !DRAWING_TABS.has(workspaceUI.activeTab);
  const on = workspaceUI.maximizedTab === workspaceUI.activeTab;
  button.textContent = on ? "Restore" : "Maximize";
  button.title = on ? "Restore the drawing pane beside the 3D model" : "Maximize the 2D drawing and its parameters";
  button.setAttribute("aria-label", button.title);
  button.setAttribute("aria-pressed", String(on));
}

function setWorkspaceMaximized(tab) {
  const selected = DRAWING_TABS.has(tab) || ["log", "deck", "loadplots", "sensitivity"].includes(tab) ? tab : null;
  workspaceUI.maximizedTab = selected;
  const app = document.getElementById("app"); app.classList.toggle("workspace-maximized", !!selected);
  app.setAttribute("data-maximized-pane", selected || "");
  app.classList.toggle("drawing-maximized", DRAWING_TABS.has(selected));
  for (const [id, panelId] of [["log", "log-wrap"], ["deck", "deck-panel"], ["loadplots", "panel-loadplots"], ["sensitivity", "panel-sensitivity"]]) {
    const on = id === selected, panel = document.getElementById(panelId), button = document.getElementById("btn-max-" + id);
    if (panel) panel.classList.toggle("maximized", on);
    if (button) {
      button.textContent = on ? "Restore" : "Maximize";
      button.title = (on ? "Restore " : "Maximize ") + id; button.setAttribute("aria-label", button.title);
      button.setAttribute("aria-pressed", String(on));
    }
  }
  syncDrawingMaximizeButton();
  if (state.engine) state.engine.resize();
}

function showDeck(text, path, metadata = {}, options = {}) {
  if (typeof text !== "string") {
    log("The deck was written, but its text was not returned by the server.", "warn");
    return;
  }
  state.lastDeck = { ...(metadata || {}), deck_text: text, path: path || "NASTRAN deck" };
  state.deckRevision++;
  const cases=state.lastDeck.case_decks||[],select=document.getElementById("deck-case-select");
  document.getElementById("deck-case-control").hidden=!cases.length;
  select.replaceChildren();
  for(const item of cases){const option=document.createElement("option");option.value=String(item.case_id);option.textContent=item.case_id+" · "+item.label+" · "+eng(item.fuel_percent)+"% fuel";select.append(option);}
  select.onchange=()=>showDeckCase(Number(select.value));
  showDeckCase(cases[0]?.case_id);
  document.getElementById("deck-panel").hidden = false;
  refreshDeckMetadata();
  if (options.open !== false) {
    activateWorkspaceTab("deck", { skipDeckLoad: true });
    const panel = document.getElementById("deck-panel");
    if (panel.classList.contains("panel-collapsed")) panel.querySelector(".panel-toggle")?.click();
  }
}

function showDeckCase(id) {
  const deck=state.lastDeck;if(!deck)return;
  const selected=(deck.case_decks||[]).find(item=>Number(item.case_id)===Number(id))||deck;
  state.deckSelectedCase=selected===deck?null:selected.case_id;
  const text=selected.deck_text,path=selected.path;
  document.getElementById("deck-text").textContent=text;
  document.getElementById("deck-path").textContent=path||"NASTRAN deck";
  if(state.deckUrl)URL.revokeObjectURL(state.deckUrl);
  state.deckUrl=URL.createObjectURL(new Blob([text],{type:"text/plain;charset=utf-8"}));
  const download=document.getElementById("deck-download");download.href=state.deckUrl;download.download=(path||"wing.bdf").split(/[\\/]/).pop();
}

function refreshDeckMetadata() {
  const deck = state.lastDeck, host = document.getElementById("deck-metadata"), status = document.getElementById("deck-status");
  if (!deck || !host || !status) return;
  host.textContent = [deck.solution, deck.created_at ? "Created " + new Date(deck.created_at).toLocaleString() : "",
    deck.source, deck.input_path ? "Input: " + deck.input_path : ""].filter(Boolean).join(" · ");
  const importedSnapshot=deck.imported_signature!==undefined||deck.source==="Imported Nastran source";
  let differs = !!state.importedDeck!==importedSnapshot;
  if(state.importedDeck&&importedSnapshot)differs=deck.imported_signature!==state.importedDeck.signature||!WingImportedAnalysis.matches(deck.imported_analysis,state.importedDeck);
  else if (!state.importedDeck&&!importedSnapshot&&deck.model_params) {
    try { differs = formSignature(deck.model_params) !== formSignature(); } catch (_) { differs = true; }
  }
  const pathKey = path => String(path || "").replace(/\\/g, "/").toLowerCase();
  const otherInput = !importedSnapshot&&!!(deck.input_path && state.inputFile && pathKey(deck.input_path) !== pathKey(state.inputFile));
  status.textContent = "Saved deck snapshot" + (differs || otherInput ? " — " + [differs ? importedSnapshot ? "source deck differs or its identity cannot be verified" : "current model parameters differ" : "", otherInput ? "created from a different input file" : ""].filter(Boolean).join("; ") + "." : ". Later parameter edits do not change this text.");
  status.classList.toggle("deck-stale", differs || otherInput);
}

async function loadLastDeck() {
  if (state.deckLoadPromise) return state.deckLoadPromise;
  const revision = state.deckRevision;
  state.deckLoadPromise = Promise.resolve().then(async () => {
    try {
      const response = await fetch("/api/last_deck", { cache: "no-store" });
      if (!response.ok) throw new Error(await readError(response));
      const payload = await response.json();
      // A completed Write/Run response received while this GET was pending
      // takes precedence over the older snapshot response.
      if (revision !== state.deckRevision) return;
      if (payload.available && payload.deck) showDeck(payload.deck.deck_text, payload.deck.path, payload.deck, { open: false });
    } catch (error) {
      if (!state.lastDeck) {
        const status = document.getElementById("deck-empty-status");
        if (status) status.textContent = "The last saved deck could not be loaded: " + error.message + ". Open the Deck tab to retry.";
      }
    } finally { state.deckLoadPromise = null; }
  });
  return state.deckLoadPromise;
}

function resultTable(value) {
  if (!value || typeof value !== "object") return esc(String(value));
  let rows = "", nested = "";
  for (const [key, item] of Object.entries(value)) {
    if (item && typeof item === "object" && !Array.isArray(item)) {
      nested += "<details open><summary>" + esc(key.replace(/_/g, " ")) + "</summary>" + resultTable(item) + "</details>";
    } else {
      const identifier = /\bIDs?\b|(?:^|_)id(?:$|_)/i.test(key);
      const valueLabel = value => typeof value === "number" && !identifier ? eng(value,6) : String(value);
      const formatted = Array.isArray(item) ? item.map(valueLabel).join(", ") : valueLabel(item);
      rows += "<tr><td>" + esc(key.replace(/_/g, " ")) + "</td><td>" + esc(formatted) + "</td></tr>";
    }
  }
  return (rows ? "<table>" + rows + "</table>" : "") + nested;
}

function showElement(eid) {
  const element = state.elements.get(eid);
  if (!element) return;
  state.selectedElement = eid;
  state.selectedCoordinate = null;
  state.selectedNode = null;
  const g = element.group;
  const kind = g.card_types?.[eid] || (g.kind === "quad" ? "CQUAD4" : g.kind === "tria" ? "CTRIA3" : g.kind === "rbe3" ? "RBE3" : "CBAR");
  let html = resultTable({ "Element ID": eid, Type: kind, Group: g.name,
    "Property ID": g.pid === undefined ? "—" : g.pid,
    "GRID IDs": Array.from(element.nodes, (i) => state.nodeIds[i]) });
  if(element.leadingEdgeFallback) html+='<p class="rib-fallback-warning" role="note">Leading-edge rib '+esc(String(element.leadingEdgeFallback.rib))+': flight direction fallback. '+esc(element.leadingEdgeFallback.reason)+'</p>';
  const properties = { ...(element.properties || g.properties || {}) };
  if (properties.section) {
    properties.section = { ...properties.section };
    // The render polygon duplicates the physical section dimensions and is
    // implementation data rather than a useful picked-element property.
    delete properties.section.polygon_yz_m;
  }
  html += "<details open><summary>Properties (SI)</summary>" + resultTable(properties) + "</details>";
  if(g.kind==="bar"){
    const displaySection=WingSections.displaySection(g.properties?.section,/C(?:ON)?ROD/.test(g.name));
    if(displaySection?.equivalent)html+='<p class="pick-note">'+esc(displaySection.display_note)+'</p>';
  }
  if(state.propertyDisplay?.enabled){
    const c=state.propertyDisplay.contour(),value=c.byId.get(eid),label=c.categories?.find(category=>category.value===value)?.label;
    html+='<details open><summary>Displayed property</summary><p>'+esc(c.name)+': '+esc(label??(Number.isFinite(value)?eng(value,6)+' '+c.unit:'Not applicable / unavailable'))+'</p></details>';
  }
  const panel=state.panelIndex?.byElement.get(eid);
  if(panel)html+='<details open><summary>Stiffened panel</summary>'+resultTable({Panel:panel.label,ID:panel.id,Skin:panel.skin,"Rib bay":panel.rib_bay,"Shell PID":panel.shell_pid,"Stringer PID":panel.stringer_pid,"Shell elements":panel.shell_eids.length,"Normal stringer bars":panel.stringer_eids.length,"Start":panel.start_kind,"End":panel.end_kind})+'</details>';
  if(state.sensitivityMap){
    const contour=state.sensitivityMap.contour,affected=contour.byId.has(eid),effect=contour.effect;
    const row=contour.rowsById?.get(eid);
    const detail=contour.kind==="sensitivity_field"?(row?WingSensitivityResults.propertyLabel(row)+": "+eng(contour.byId.get(eid),6)+" "+contour.unit+". Derivative belongs to the attached property; shared elements repeat its value.":"No unambiguous derivative for the selected property family."):
      affected?WingSensitivityResults.propertyLabel(contour.row)+": "+eng(effect.changePercent,4)+"% property change predicts "+eng(effect.deltaResponse,6)+" "+effect.responseUnit+" change in the selected response. This shared effect is not an element-local derivative.":"This element is not governed by the selected property.";
    html+='<details open><summary>Sensitivity</summary><p class="pick-note">'+esc(contour.caseLabel)+"</p><p>"+esc(detail)+"</p></details>";
  }
  if (g.orient && g.kind === "bar") {
    const orient = asF32(g.orient), index = Array.from(groupIds(g)).indexOf(eid);
    html += resultTable({ "Orientation vector": Array.from(orient.slice(3 * index, 3 * index + 3)) });
  }
  const results = state.results && state.results.matches ? (state.results.elementResults || {})[String(eid)] : null;
  if (results) {
    html += "<details open><summary>Element results (SI)</summary><p class=\"pick-note\">" + esc(resultCaseLabel()) + "</p>" + resultTable(results) + "</details>";
  } else {
    html += '<p class="pick-note">No element stress/force results available for this element.</p>';
  }
  const shape = activeShape();
  if (shape) {
    const displacements = {};
    for (const i of element.nodes) displacements["GRID " + state.nodeIds[i]] = Array.from(shape.shape.slice(3 * i, 3 * i + 3), x => eng(x, 5)).join(", ");
    html += "<details><summary>Nodal translations x, y, z (" + (state.activeMode >= 0 ? "normalized mode" : "m") + ")</summary>" + resultTable(displacements) + "</details>";
  }
  document.getElementById("pick-content").innerHTML = html;
  document.getElementById("pick-card").hidden = false;
  updateSelection();
}

function updateSelection(positions) {
  state.geometryTools?.refreshSelection(positions);
  if (state.annotations) state.annotations.invalidate();
  if (state.selectedNode !== null && state.baseline) {
    const index = state.selectedNode, dp = positions || currentPositions();
    if (!state.selectionMesh || !state.selectionMesh.metadata?.nodeSelection) {
      if (state.selectionMesh) state.selectionMesh.dispose(false, true);
      state.selectionMesh = BABYLON.MeshBuilder.CreateSphere("picked-node", { diameter: 1, segments: 12 }, state.scene);
      const material = new BABYLON.StandardMaterial("picked-node-material", state.scene);
      material.diffuseColor = color3("#ffe478"); material.emissiveColor = color3("#ffe478");
      state.selectionMesh.material = material; state.selectionMesh.metadata = { nodeSelection: true };
      state.selectionMesh.isPickable = false; state.selectionMesh.renderingGroupId = 2;
    }
    state.selectionMesh.position.copyFrom(vec(dp, index));
    state.selectionMesh.scaling.setAll(Math.max(nodeRadius() * 2.8, state.diag * .006));
    state.selectionMesh.setEnabled(visibleNodeIndices().has(index));
    return;
  }
  const element = state.elements.get(state.selectedElement);
  if (!element || !state.baseline) return;
  const dp = positions || currentPositions();
  const nodes = element.nodes;
  const pairs = [];
  if (element.group.kind === "rbe3" || element.group.kind === "connection") {
    for (let i = 1; i < nodes.length; i++) pairs.push(nodes[0], nodes[i]);
  } else {
    for (let i = 0; i < (nodes.length === 2 ? 1 : nodes.length); i++) pairs.push(nodes[i], nodes[(i + 1) % nodes.length]);
  }
  if (!state.selectionMesh || state.selectionMesh.metadata !== state.selectedElement) {
    if (state.selectionMesh) state.selectionMesh.dispose(false, true);
    state.selectionMesh = lineMesh("picked-element", dp, new Int32Array(pairs), "#ffffff", 1, false);
    if (!state.selectionMesh) return;
    state.selectionMesh.metadata = state.selectedElement;
    state.selectionMesh.renderingGroupId = 2;
  } else {
    const points = new Float32Array(pairs.length * 3);
    pairs.forEach((node, i) => points.set(dp.subarray(3 * node, 3 * node + 3), 3 * i));
    state.selectionMesh.updateVerticesData(BABYLON.VertexBuffer.PositionKind, points, true);
  }
  const layer = state.layers.get(element.group.name);
  state.selectionMesh.position.copyFromFloats(...(state.panelExplosion?.offsetElement(element.id)||[0,0,0]));
  state.selectionMesh.setEnabled(!layer || layer.visible);
}

function inspectionMatches(group, filter = document.getElementById("inspect-entity")?.value || "all") {
  if (filter === "all") return true;
  if (filter === "shells") return group.kind === "quad" || group.kind === "tria";
  if (filter === "stringer") return group.kind === "bar" && group.name.startsWith("STRINGER");
  if (filter === "cap") return group.kind === "bar" && group.name === "SPAR_CAPS";
  return group.kind === filter;
}

function showCoordinate(cid){
  const frame=state.data?.coordinate_systems?.systems?.find(frame=>frame.id===cid);if(!frame)return false;
  clearInspection();state.selectedCoordinate=cid;
  document.getElementById('pick-content').innerHTML=resultTable({'Coordinate ID':cid,Type:WingModelEntities.typeLabel(frame.type),'Source card':frame.card,
    'Origin (global BASIC)':frame.origin,'Defining x axis (BASIC)':frame.x,'Defining y axis (BASIC)':frame.y,'Defining z axis (BASIC)':frame.z})+
    '<details open><summary>Source definition</summary>'+resultTable(frame.properties||{})+'</details><p class="pick-note">'+esc(state.data.coordinate_systems.note||'')+'</p>';
  document.getElementById('pick-card').hidden=false;state.annotations?.invalidate();return true;
}

function modelVectorAt(values, index) {
  return [values[3 * index + 2], values[3 * index], values[3 * index + 1]];
}

function visibleNodeIndices() {
  const nodes = new Set();
  for (const element of state.elements.values()) if (state.layers.get(element.group.name)?.visible)
    for (const node of element.nodes) nodes.add(node);
  for (const marker of state.markers) if (state.layers.get(marker.kind)?.visible) nodes.add(marker.node);
  if(state.layers.get("SPC")?.visible)for(const node of state.supportGlyphs?.nodes || [])nodes.add(node);
  if (state.layers.get("NODES")?.visible) for (let i = 0; i < state.data.nodes.n_structural; i++) nodes.add(i);
  return nodes;
}

function inspectionDepthTest() {
  if (typeof WingAnnotations === "undefined") return () => false;
  const width = state.engine.getRenderWidth(), height = state.engine.getRenderHeight();
  const viewport = state.camera.viewport.toGlobal(width, height), transform = state.scene.getTransformMatrix();
  let index;
  return (point, kind, id) => {
    if (!index) index = WingAnnotations.buildOcclusionIndex(BABYLON, WingAnnotations.opaqueOccluders(state.scene),
      state.camera, transform, viewport, width, height, width, height, state.diag);
    const p = BABYLON.Vector3.Project(new BABYLON.Vector3(...point), BABYLON.Matrix.IdentityReadOnly, transform, viewport);
    return index.isOccluded({ point, kind, id }, p);
  };
}

function showNode(index) {
  if (!state.baseline || index < 0 || index >= state.nodeIds.length) return false;
  state.selectedElement = null; state.selectedNode = index;state.selectedCoordinate=null;
  const connected = Array.from(state.elements, ([id, e]) => e.nodes.includes(index) ? id : null).filter(id => id !== null);
  const supported = asI32(state.data.spc.nodes).includes(index);
  let html = resultTable({ "Node ID": state.nodeIds[index], Type: "GRID",
    [state.importedDeck ? "Coordinates x, y, z (source units)" : "Coordinates x, y, z (m)"]: modelVectorAt(state.baseline, index),
    "SPC components": supported ? String(state.data.spc.node_components?.[Array.from(asI32(state.data.spc.nodes)).indexOf(index)] || state.data.spc.components || "123").split("").join(", ") : "None",
    "Connected element IDs": connected });
  if(state.importedDeck&&supported){const assignment=state.data.spc.assignments?.find(row=>row.node===index);if(assignment)html+='<details open><summary>Boundary conditions · subcase '+esc(String(state.activeCase))+'</summary>'+resultTable({
    'SPC set':state.data.spc.selected_spc_id??'None','Source sets':assignment.source_sets||[],
    'GRID displacement coordinates (CD)':assignment.coordinate_id??0,'Prescribed values by DOF':assignment.values||{},'Source constraints':assignment.sources||[],
  })+'</details>';}
  const applied = WingGeometryExport.loadsByNode(appliedResultLoads()?.stations).get(index);
  if(applied){
    const values={"Applied force Fx, Fy, Fz (N, global)":applied.force,"Applied moment Mx, My, Mz (Nm, global)":applied.moment};
    if(applied.source_moments_Nm)values["Moment sources (Nm, global)"]=applied.source_moments_Nm;
    if(applied.source_forces_N)values["Force sources (N, global)"]=applied.source_forces_N;
    html+="<details open><summary>Applied loads</summary>"+resultTable(values)+"</details>";
  }
  const shape = activeShape();
  if (shape) {
    const unit = state.activeMode >= 0 ? "normalized mode" : "m";
    const values = { ["Translation x, y, z (" + unit + ")"]: Array.from(shape.shape.slice(3 * index, 3 * index + 3)) };
    if (shape.rotation) values["Rotation x, y, z (" + (state.activeMode >= 0 ? "normalized mode" : "rad") + ")"] = modelVectorAt(shape.rotation, index);
    const reactions = state.activeMode < 0 ? state.results?.reactions : null;
    const reactionIndex = supported && reactions ? reactions.nodes.indexOf(index) : -1;
    if (reactionIndex >= 0) {
      values["Support force Fx, Fy, Fz (N, global)"] = Array.from(reactions.forces.slice(3 * reactionIndex, 3 * reactionIndex + 3));
      if (reactions.moments) values["Support moment Mx, My, Mz (N m, global)"] = Array.from(reactions.moments.slice(3 * reactionIndex, 3 * reactionIndex + 3));
    }
    html += "<details open><summary>Nodal results</summary><p class=\"pick-note\">" + esc(resultCaseLabel()) + "</p>" + resultTable(values) + "</details>";
  } else html += '<p class="pick-note">No matching nodal results are available.</p>';
  document.getElementById("pick-content").innerHTML = html;
  document.getElementById("pick-card").hidden = false;
  updateSelection(); return true;
}

function clearInspection() {
  state.selectedElement = null; state.selectedNode = null;state.selectedCoordinate=null;
  if (state.selectionMesh) state.selectionMesh.dispose(false, true);
  state.selectionMesh = null;
  document.getElementById("pick-card").hidden = true;
  document.getElementById("inspect-status").textContent = "Left-click a matching visible entity, or enter its ID.";
  state.annotations?.invalidate();
  state.geometryTools?.refreshSelection();
}

function inspectFilterChanged() {
  const filter = document.getElementById("inspect-entity")?.value || "all";
  const element = state.elements.get(state.selectedElement);
  if (state.selectedCoordinate!=null&&filter!=="coordinate" || state.selectedNode !== null && filter !== "nodes" || element && !inspectionMatches(element.group, filter)) {
    clearInspection();
  }
  document.getElementById("inspect-status").textContent = "Left-click a matching visible entity, or enter its ID. Hidden entities can be inspected by ID.";
  state.viewportTools?.syncInspection?.();
}

function inspectById() {
  const id = Number(document.getElementById("inspect-id").value), filter = document.getElementById("inspect-entity").value;
  let found = false;
  if (Number.isInteger(id) && (id > 0 || filter==='coordinate'&&id===0)) {
    if (filter === 'coordinate') found=showCoordinate(id);
    else if (filter === "nodes") found = showNode(state.nodeIds ? state.nodeIds.indexOf(id) : -1);
    else { const element = state.elements.get(id); if (element && inspectionMatches(element.group, filter)) { showElement(id); found = true; } }
  }
  document.getElementById("inspect-status").textContent = found ? "Inspecting " + (filter === "nodes" ? "GRID " : filter==='coordinate'?'coordinate ':'element ') + id : "No matching entity with that ID in the current model.";
}

function pickNode(x, y) {
  const positions = currentPositions(); if (!positions) return null;
  const viewport = state.camera.viewport.toGlobal(state.engine.getRenderWidth(), state.engine.getRenderHeight());
  const transform = state.scene.getTransformMatrix(), scaling = state.engine.getHardwareScalingLevel();
  const candidates = [], occluded = inspectionDepthTest();
  for (const index of visibleNodeIndices()) {
    const point = vec(positions, index), p = BABYLON.Vector3.Project(point, BABYLON.Matrix.IdentityReadOnly, transform, viewport);
    const distance = (p.x - x / scaling) ** 2 + (p.y - y / scaling) ** 2;
    if (p.z >= 0 && p.z <= 1 && distance <= (14 / scaling) ** 2) candidates.push({ index, point: point.asArray(), distance, depth: p.z });
  }
  candidates.sort((a,b) => Math.abs(a.distance-b.distance) < .01 ? a.depth-b.depth : a.distance-b.distance);
  const hit = candidates.find(c => !occluded(c.point, "node", state.nodeIds[c.index]));
  if (!hit) return null;
  showNode(hit.index); expandPanel("pick-card"); return state.nodeIds[hit.index];
}

function pickElement(x, y) {
  if (document.getElementById("inspect-entity")?.value === "nodes") return pickNode(x, y);
  if(document.getElementById('inspect-entity')?.value==='coordinate'){
    const pick=state.scene.pick(x,y,mesh=>mesh.isEnabled()&&mesh.isPickable&&mesh.metadata?.coordinateIds);
    const cid=WingModelEntities.pickedCoordinateId(pick);if(cid===undefined)return null;
    showCoordinate(cid);expandPanel('pick-card');return cid;
  }
  const eligible = (mesh) => mesh.isEnabled() && mesh.isPickable && mesh.metadata?.feGroup && inspectionMatches(mesh.metadata.feGroup);
  const foreground = !!document.getElementById("show-bars-through")?.checked;
  const occluded = inspectionDepthTest();
  // Give visible coplanar bars a pick target on their skin edge. Hidden bars
  // are rejected unless the user explicitly enabled their through view.
  let pick = state.scene.pick(x, y, (mesh) => eligible(mesh) && isForegroundBar(mesh.metadata.feGroup));
  if (pick?.hit && pick.pickedPoint && !foreground) {
    if (occluded(pick.pickedPoint.asArray(), "element", WingModelEntities.pickedElementId(pick))) pick = null;
  }
  if (!pick || !pick.hit) pick = state.scene.pick(x, y, eligible);
  if (!pick || !pick.hit) return null;
  const mesh = pick.pickedMesh;
  const metadata = mesh.metadata;
  const eid = WingModelEntities.pickedElementId(pick);
  if (pick.pickedPoint && !(foreground && isForegroundBar(metadata.feGroup)) &&
      occluded(pick.pickedPoint.asArray(), "element", eid)) return null;
  if (eid !== undefined) {
    showElement(eid); expandPanel("pick-card");
    const card = document.getElementById("pick-card");
    if (card.scrollIntoView) card.scrollIntoView({ block: "nearest" });
  }
  return eid;
}

function centerOnNode(x, y) {
  const positions = currentPositions();
  if (!positions) return null;
  const viewport = state.camera.viewport.toGlobal(state.engine.getRenderWidth(), state.engine.getRenderHeight());
  const transform = state.scene.getTransformMatrix();
  // Work in rendered pixels, accounting for high-DPI hardware scaling.
  const scaling = state.engine.getHardwareScalingLevel();
  const px = x / scaling, py = y / scaling;
  const tolerance = 14 / scaling;
  let best = -1, distance = tolerance * tolerance, depth = Infinity;
  for (let i = 0; i < positions.length / 3; i++) {
    const p = BABYLON.Vector3.Project(vec(positions, i), BABYLON.Matrix.IdentityReadOnly, transform, viewport);
    if (p.z < 0 || p.z > 1) continue;
    const d = (p.x - px) ** 2 + (p.y - py) ** 2;
    if (d < distance - 0.01 || (Math.abs(d - distance) < 0.01 && p.z < depth)) {
      best = i; distance = d; depth = p.z;
    }
  }
  if (best >= 0) {
    centerCamera(vec(positions, best));
    log("Centered on GRID " + state.nodeIds[best]);
    return state.nodeIds[best];
  }
  return null;
}

function centerCamera(point) {
  if (typeof WingViewportTools !== "undefined") WingViewportTools.center(state.camera, point);
  else { const {alpha,beta,radius}=state.camera;state.camera.setTarget(point,false,true,true);Object.assign(state.camera,{alpha,beta,radius}); }
  state.annotations?.invalidate();markStudyViewModified();
}

function centerOnSurface(x,y) {
  const pick=state.scene.pick(x,y,mesh=>mesh.isEnabled()&&mesh.isVisible&&mesh.isPickable&&!mesh.metadata?.wingViewHelper);
  if (!pick?.hit||!pick.pickedPoint) return false;
  centerCamera(pick.pickedPoint);return true;
}

function installPicking(canvas) {
  let down = null;
  canvas.addEventListener("pointerdown", (event) => {
    if(event.isPrimary===false){down=null;return;}
    if (state.reference && state.reference.isInteracting()) { down = null; return; }
    if (event.button === 0 || event.button === 1) {
      const c=state.camera;WingViewportTools.stopMotion(c);
      down = { x:event.clientX,y:event.clientY,button:event.button,id:event.pointerId,alpha:c.alpha,beta:c.beta,radius:c.radius,target:c.target.clone() };
    }
    if (event.button === 1) event.preventDefault();
  },true);
  canvas.addEventListener("pointermove",event=>{
    if(down&&down.id===event.pointerId&&Math.hypot(event.clientX-down.x,event.clientY-down.y)>=5)down.dragged=true;
  },true);
  canvas.addEventListener("pointerup", (event) => {
    if (state.reference && state.reference.isInteracting()) { down = null; return; }
    if (!down || down.button !== event.button || down.id !== event.pointerId) { down = null; return; }
    const click = !down.dragged && Math.hypot(event.clientX - down.x, event.clientY - down.y) < 5;
    const start=down;
    down = null;
    if (!click) return;
    // A sub-threshold move is a click, not an orbit. Restore its initial
    // frame even in Inspect/Measure, and discard residual orbit inertia.
    WingViewportTools.stopMotion(state.camera);
    state.camera.setTarget(start.target,false,true,true);
    Object.assign(state.camera,{alpha:start.alpha,beta:start.beta,radius:start.radius});
    state.camera.getViewMatrix(true);
    const rect = canvas.getBoundingClientRect();
    const x = event.clientX - rect.left, y = event.clientY - rect.top;
    if (event.button === 1) { event.preventDefault(); centerOnNode(x, y); }
    else if (state.geometryTools?.active) state.geometryTools.pick(x, y);
    else if (state.data && workspaceUI.activeTab === "inspect") pickElement(x, y);
    else centerOnSurface(x,y);
  });
  canvas.addEventListener("pointercancel", () => { down = null; });
  canvas.addEventListener("auxclick", (event) => { if (event.button === 1) event.preventDefault(); });
}

/* --- wiring -------------------------------------------------------------- */

installPanels();
document.getElementById("show-panels").onchange=event=>{setPanelDisplay(event.target.checked);markStudyViewModified();};
installWorkspaceNavigation();
installPaneResize();
document.getElementById("btn-study-notes").onclick=()=>{activateWorkspaceTab("summary");document.getElementById("study-note").focus();document.getElementById("study-notes-panel").scrollIntoView({block:"nearest"});};
document.getElementById("study-note").addEventListener("input",markStudyModified);
for (const eventName of ["input","change"]) document.addEventListener(eventName,event=>{
  const id=event.target?.id || "";
  if (event.target?.disabled) return;
  if ((typeof WingWorkspace!=="undefined" && WingWorkspace.CONTROL_IDS.includes(id)) || id.startsWith("layer-") || id==="planform-input-method" || id.startsWith("planform-dimension-")) markStudyViewModified();
  if (id==="planform-input-method" || id.startsWith("planform-dimension-")) updateAnalysisValidity();
});
document.addEventListener("click",event=>{if(event.target?.closest?.("#lock-planform,#lock-mesh"))markStudyViewModified();});
document.addEventListener("svgviewchange", () => markStudyViewModified());
document.getElementById("btn-max-drawing").onclick = () => {
  setWorkspaceMaximized(workspaceUI.maximizedTab === workspaceUI.activeTab ? null : workspaceUI.activeTab);
  markStudyViewModified();
};
document.getElementById("btn-open-plan-view").onclick = () => { installDimensionedPlanView(); state.planView?.open(); };
document.getElementById("btn-quick-help").onclick = () => openHelp("workflow");
document.getElementById("btn-close-help").onclick = () => {
  const dialog = document.getElementById("help-dialog");
  if (dialog.close) dialog.close(); else dialog.hidden = true;
};
document.getElementById("help-dialog").onclick = (event) => {
  if (event.target === document.getElementById("help-dialog")) document.getElementById("btn-close-help").click();
};
document.getElementById("btn-max-log").onclick = () => {
  expandPanel("log-wrap");
  setLogMaximized(!document.getElementById("log-wrap").classList.contains("maximized"));
};
document.getElementById("btn-max-deck").onclick = () => {
  expandPanel("deck-panel");
  setWorkspaceMaximized(workspaceUI.maximizedTab === "deck" ? null : "deck");
};
document.getElementById("btn-max-loadplots").onclick = () => setWorkspaceMaximized(workspaceUI.maximizedTab === "loadplots" ? null : "loadplots");
document.getElementById("btn-help-loadplots").onclick = () => openHelp("Load plots");
document.getElementById("show-fuel-tank").onchange = event => setLayerVisible("FUEL_TANK", event.target.checked);
document.getElementById("btn-isolate-fuel").onclick = isolateFuelTank;
document.getElementById("show-vlm-panel-forces").onchange = event => setLayerVisible("VLM_FORCES", event.target.checked);
document.getElementById("vlm-force-scale").oninput = rebuildVlmForceArrows;
for (const [id, factor] of [["smaller", .5], ["larger", 2]]) document.getElementById("btn-vlm-force-" + id).onclick = () => {
  const input = document.getElementById("vlm-force-scale"), current = Number(input.value);
  input.value = Number(Math.min(100, Math.max(.01, (Number.isFinite(current) && current > 0 ? current : 1) * factor)).toPrecision(6));
  rebuildVlmForceArrows();
};
document.getElementById("btn-close-deck").onclick = () => {
  document.getElementById("deck-panel").hidden = true;
  activateWorkspaceTab(workspaceUI.previousTab === "deck" ? "analysis" : workspaceUI.previousTab);
};
document.getElementById("surface-mode").onchange = () => {
  if (document.getElementById("surface-mode").value === "solid") document.getElementById("show-bars-through").checked = false;
  applySurfaceMode();
};
document.getElementById("show-bars-through").onchange = applyBarDepthPolicy;
document.getElementById("surface-translucency").oninput = ()=>{applySurfaceMode();markStudyViewModified();};
document.getElementById("show-aero-overlay").onchange = (event) => setLayerVisible("AERO_SURFACE", event.target.checked);
document.getElementById("aero-deformed-style").onchange = () => {
  setLayerVisible("AERO_SURFACE",true);
  applyAeroOverlayStyles();syncAeroOverlayControl();state.annotations?.invalidate();markStudyViewModified();
};
document.getElementById("show-shell-axes").onchange = (event) => setLayerVisible("SHELL_AXES", event.target.checked);
document.getElementById("show-bar-axes").onchange = (event) => setLayerVisible("BAR_AXES", event.target.checked);
document.getElementById("background-color").oninput = (event) => applyBackgroundColor(event.target.value);
function setStudyInformation(open,focus=false){
  const panel=document.getElementById("study-information"),button=document.getElementById("btn-study-information");
  panel.hidden=!open;button.setAttribute("aria-expanded",String(open));
  if(focus)(open?document.getElementById("btn-close-study-information"):button).focus();
}
document.getElementById("btn-study-information").onclick=()=>setStudyInformation(document.getElementById("study-information").hidden,true);
document.getElementById("btn-close-study-information").onclick=()=>setStudyInformation(false,true);
document.addEventListener("pointerdown",event=>{if(!event.target.closest?.("#study-information,#btn-study-information"))setStudyInformation(false);});
document.addEventListener("keydown",event=>{if(event.key==="Escape"&&!document.getElementById("study-information").hidden){event.preventDefault();setStudyInformation(false,true);}});
document.getElementById("inspect-entity").onchange = inspectFilterChanged;
document.getElementById("btn-inspect-id").onclick = inspectById;
document.getElementById("inspect-id").addEventListener("keydown", event => { if (event.key === "Enter") inspectById(); });
document.getElementById("vlm-case-select").onchange = (event) => {selectLoadCase(event.target.value,{preserveSensitivity:true});activateWorkspaceTab("vlm");};
for (const [id, field] of [["mesh", "none"], ["pressure", "pressure"], ["cp", "cp"], ["hide", "hide"]])
  document.getElementById("btn-vlm-" + id).onclick = () => setVlmView(field);
document.getElementById("vlm-show-forces").onchange = (event) => setLayerVisible("AERO_LOADS", event.target.checked);
document.getElementById("vlm-show-moments").onchange = (event) => setLayerVisible("AERO_MOMENTS", event.target.checked);
document.getElementById("beam-style").onchange = applyBeamStyle;
document.getElementById("shell-geometry").onchange = ()=>{applyShellGeometry();markStudyViewModified();};
document.getElementById("load-case-select").onchange = (e) => selectLoadCase(e.target.value);
document.getElementById("result-case-select").onchange = (e) => selectLoadCase(e.target.value);
document.getElementById("result-analysis-select").onchange = (e) => selectResultAnalysis(e.target.value);
document.getElementById("compare-results").onchange = () => { rebuildComparisonOverlay(); applyDeformation(); updateScaleText(); };
document.getElementById("vlm-field").onchange = () => {
  if (state.vlm) setLayerVisible("VLM_MESH", true);
  applyVlmContour();
};
document.getElementById("node-radius").oninput = updateMarkerRadii;
document.getElementById("marker-radius").oninput = updateMarkerRadii;
document.getElementById("entities-show-all").onclick = () => setModelEntitiesVisible(Array.from(state.layers.keys()), true);
document.getElementById("entities-hide-all").onclick = () => setModelEntitiesVisible(Array.from(state.layers.keys()), false);
document.getElementById("show-ground-plane").onchange = syncViewPlanes;
document.getElementById("show-rib-datums").onchange = () => syncRibDatums();
document.getElementById("rib-datum-size").oninput = () => syncRibDatums();
document.getElementById("show-symmetry-plane").onchange = syncViewPlanes;
for (const id of ["ground-plane-z", "ground-grid-spacing"]) {
  document.getElementById(id).oninput = () => syncViewPlanes();
  document.getElementById(id).onchange = () => syncViewPlanes(true);
}
document.getElementById("show-undeformed").onchange = syncResultOverlays;
document.getElementById("show-reference-aero").onchange = syncResultOverlays;
document.getElementById("show-deformed-aero").onchange = event => setLayerVisible("AERO_SURFACE",event.target.checked);

document.getElementById("btn-create").onclick = createFEM;
document.getElementById("auto-mesh").onchange = autoMeshChanged;
document.getElementById("btn-jfem").onclick = runJfem;
for(const id of ["show-fuel-inertia","show-fuel-cg","fuel-inertia-scale"]){
  document.getElementById(id).addEventListener("change",()=>{refreshFuelMassProperties();syncLayerGroupControls();markStudyViewModified();});
}
document.getElementById("fuel-mass-show").onclick=()=>{document.getElementById("show-fuel-inertia").checked=true;refreshFuelMassProperties();syncLayerGroupControls();markStudyViewModified();};
document.getElementById("fuel-mass-hide").onclick=()=>{document.getElementById("show-fuel-inertia").checked=false;refreshFuelMassProperties();syncLayerGroupControls();markStudyViewModified();};
document.getElementById("fuel-mass-report").onclick=()=>activateWorkspaceTab("weights");
document.getElementById("btn-stop-jfem").onclick = stopJfem;
document.getElementById("btn-nastran").onclick = writeNastran;
document.getElementById("btn-save").onclick = saveInput;
document.getElementById("btn-reload").onclick = reloadInput;
if (typeof WingGeometryExport !== "undefined") {
  document.getElementById("export-stl").onclick = () => exportGeometry("stl");
  document.getElementById("export-glb").onclick = () => exportGeometry("glb");
  document.getElementById("export-help").onclick = geometryExportHelp;
}
if (typeof WingWorkspace !== "undefined") {
  if (typeof WingRecentStudies !== "undefined") state.recentStudies = WingRecentStudies.create({
    document,
    onOpen:(file,context={})=>loadModelDefinition(file,{recent:true,recentId:context.id,handle:context.source==="snapshot" ? null : context.handle || null}),
    onBrowse:()=>{if(workspaceOperationAvailable())document.getElementById("model-file").click();},
    onError:message=>log(typeof message === "string" ? message : message.message,"warn"),
    onRecorded:info=>{if(info?.id)state.studyRecentId=info.id;},
  });
  document.getElementById("btn-save-model").onclick = ()=>saveModelDefinition();
  document.getElementById("btn-save-model-as").onclick = ()=>saveModelDefinition({saveAs:true});
  document.getElementById("btn-load-model").onclick = () => {
    if (!workspaceOperationAvailable()) return;
    if (state.recentStudies) state.recentStudies.open();
    else document.getElementById("model-file").click();
  };
  document.getElementById("model-file").onchange = async (event) => {
    const file = event.target.files[0]; event.target.value = "";
    const complete=state.startupFileComplete;state.startupFileComplete=null;
    const loaded=await loadModelDefinition(file);complete?.(loaded===true);
  };
  document.getElementById("model-file").addEventListener("cancel",()=>{state.startupChoiceCancelled=true;state.startupFileComplete?.(false);state.startupFileComplete=null;});
  document.getElementById("btn-save-toml").onclick=saveTomlAs;
  document.getElementById("btn-view-toml").onclick=showTomlPreview;
  document.getElementById("btn-load-toml").onclick=()=>{if(workspaceOperationAvailable())document.getElementById("toml-file").click();};
  document.getElementById("toml-file").onchange=async event=>{const file=event.target.files[0];event.target.value="";await loadTomlDefinition(file);};
  document.getElementById("btn-new-study").onclick=newStudy;
  state.nastranImport=WingNastranImport.create({onImport:loadNastranSource,pickFile:async({path})=>{
    const response=await fetch("/api/import_nastran/pick",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({path})});
    if(!response.ok)throw Error(await readError(response));return response.json();
  },prepareImporter:async start=>{
    const response=await fetch("/api/import_nastran/prepare",{method:start?"POST":"GET",cache:"no-store"});
    if(!response.ok)throw Error(await readError(response));const data=await response.json();
    if(data.stage&&data.stage!==state.importerPreparationStage){state.importerPreparationStage=data.stage;log("Importer preparation +"+Number(data.seconds||0).toFixed(2)+" s: "+data.stage);}
    return data;
  }});
  document.getElementById("btn-read-nastran").onclick=()=>state.nastranImport.open();
}
document.getElementById("btn-clear-results").onclick = clearResults;
document.getElementById("btn-mode-prev").onclick = () => stepMode(-1);
document.getElementById("btn-mode-next").onclick = () => stepMode(1);

document.getElementById("deform-scale").oninput = () => {
  state.realScale = false;
  updateScaleText();
  applyDeformation();
};
document.getElementById("btn-real-scale").onclick = () => setRealScale(true);
document.getElementById("btn-auto-scale").onclick = () => { document.getElementById("deform-scale").value = "0"; setRealScale(false); };
document.getElementById("result-palette").title="Color scale for FE results. Sensitivity and aerodynamic results have independent palette buttons on their legends.";
document.getElementById("result-palette").onchange = event => WingLegends.setPalette("fe",event.target.value);
WingLegends.configure({getPalette:scope=>scope==="sensitivity"?"coolwarm":scope==="properties"?"viridis":"spectrum",
  onLimitsChange:()=>{applyContour();applyVlmContour();},
  setPalette:(value,scope)=>{if(scope==="fe")document.getElementById("result-palette").value=value;if(scope==="vlm")applyVlmContour();else applyContour();},onChange:markStudyViewModified,
  palettes:Array.from(document.getElementById("result-palette").options).map(option=>({value:option.value,label:option.textContent,
    gradient:"linear-gradient(90deg,"+COLOR_SCALES[option.value].map(([t,c])=>"rgb("+c.map(v=>Math.round(v*255)).join(",")+") "+(100*t)+"%").join(",")+")"}))});
document.getElementById("show-support-forces").onchange = event => setLayerVisible("SUPPORT_FORCES", event.target.checked);
document.getElementById("show-support-force-values").onchange=()=>{state.annotations?.invalidate();markStudyViewModified();};
document.getElementById("support-force-scale").oninput = () => { rebuildSupportForces(); buildLayerPanel(); };
document.getElementById("animate").onchange = () => {
  state.phase = Math.PI / 2;
  applyDeformation();
  if(state.propertyDisplay?.enabled)applyContour();
};
document.getElementById("contour-select").onchange = (e) => {
  state.propertyDisplay?.setEnabled(false);
  clearSensitivityMap();
  state.contourIdx = parseInt(e.target.value, 10);
  const selected=contourOptions()[state.contourIdx];
  state.contourPreference=selected ? {kind:selected.kind,name:selected.name} : null;
  applyContour();
};

window.addEventListener("keydown", (e) => {
  if (state.workspaceBusy || !state.autoMeshReady) return;
  if (document.querySelector("dialog[open]")) return;
  if (["INPUT","SELECT","TEXTAREA"].includes(e.target.tagName) || e.target.isContentEditable) return;
  if (e.key === "f") fitView();
  if (e.key === "g") createFEM();
  if (e.key === "j") runJfem();
  if (e.key === "ArrowDown" || e.key === "]") stepMode(1);
  if (e.key === "ArrowUp" || e.key === "[") stepMode(-1);
});

function showStartupStudyNotice(notice) {
  if(!notice?.message)return;
  let panel=document.getElementById("startup-study-notice");
  if(!panel){panel=document.createElement("div");panel.id="startup-study-notice";panel.className="startup-study-notice";panel.setAttribute("role","status");document.body.append(panel);}
  panel.replaceChildren(document.createTextNode(notice.message));panel.dataset.status=notice.status;
  const close=document.createElement("button");close.type="button";close.textContent="×";close.setAttribute("aria-label","Dismiss Study restore notice");close.onclick=()=>panel.remove();panel.append(close);
  if(notice.status!=="loading")log(notice.message,notice.status==="failed"?"err":"warn");
}

(async function start() {
  const startup = activity()?.startup;
  try {
  await paintActivity();
  if (typeof BABYLON === "undefined") {
    throw new Error("Babylon.js did not load from web/vendor/babylon.js");
  }
  if (typeof MessagePack === "undefined") {
    throw new Error("the MsgPack decoder did not load from web/vendor/msgpack.min.js");
  }
  activity()?.update(startup, {detail:"Initializing the 3D viewport…"});
  await paintActivity(); initScene();
  log("Babylon.js " + BABYLON.Engine.Version + " ready");
  await loadInput({deferModel:true,deferReferences:true});
  activity()?.end(startup);if(activity())activity().startup=null;
  meshStatus("Choose a Study to start", "pending");
  let loaded=false,choiceMessage="";
  while(!loaded){
    let openRequest;
    const choice=await WingStartupStudy.choose({recentStudies:state.recentStudies,message:choiceMessage,onChoose:value=>{
      // Keep the native file dialog inside the originating user gesture.
      state.startupChoiceCancelled=false;
      if(value==="open")openRequest=new Promise(resolve=>{state.startupFileComplete=resolve;document.getElementById("model-file").click();});
      if(value==="nastran")openRequest=state.nastranImport.open();
    }});
    choiceMessage="";
    if(choice==="new")loaded=await newStudy()===true;
    else if(choice==="open")loaded=await openRequest;
    else if(choice==="nastran"){loaded=await openRequest;if(!loaded)state.startupChoiceCancelled=true;}
    else {
      const restored=await state.recentStudies?.restoreLatest({automatic:false,retry:true,onNotice:showStartupStudyNotice});
      loaded=restored?.status==="restored";
      if(!loaded)choiceMessage=restored?.message || "The last Study is unavailable. Choose another file or start a new Study.";
    }
    if(!loaded&&!state.startupChoiceCancelled&&!choiceMessage)choiceMessage=document.getElementById("model-error-text")?.textContent || "The Study could not be loaded. Choose another file or start a new Study.";
  }
  state.autoMeshReady=true;
  log("Study loaded; WingFEGen is ready.", "good");
  probeJfem();
  loadLastDeck();
  } catch (e) {
    log("Startup failed: " + e.message, "err");
    meshStatus("Startup failed — see Log, then refresh to retry", "invalid");
  } finally {
    activity()?.end(startup);
    if (activity()) activity().startup = null;
  }
})();
