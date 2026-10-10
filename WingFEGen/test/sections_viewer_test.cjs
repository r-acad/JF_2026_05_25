/* Physical bar geometry, real Babylon picking, deformation and contour checks. */
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const BABYLON = require("../web/vendor/babylon.js");
const WingSections = require("../web/sections.js");
const close = (a, b, tolerance = 2e-8) => assert.ok(Math.abs(a - b) < tolerance, `${a} != ${b}`);
const b = 0.03, h = 0.032, tf = 0.002, tw = 0.002;
const d = (b * tf * tf / 2 + tw * (h - tf) * (tf + (h - tf) / 2)) / (b * tf + tw * (h - tf));
const section = {
  type: "PBARL", shape: "T", dimensions_m: [b, h, tf, tw], offset_y_m: -d,
  polygon_yz_m: [[d,-b/2], [d,b/2], [d-tf,b/2], [d-tf,tw/2],
    [d-h,tw/2], [d-h,-tw/2], [d-tf,-tw/2], [d-tf,-b/2]],
};
const positions = new Float32Array([0,0,0, 2,0,0, 0,-0.1,0, 2,-0.1,0]);
const conn = new Int32Array([0,1,2,3]), orient = new Float32Array([0,1,0, 0,-1,0]);
const geometry = WingSections.geometry(positions, conn, orient, section);
// A modal eigenvector has arbitrary normalization. A tiny nonzero rotation
// becomes finite under display magnification and must not be mistaken for a
// zero-length beam direction (the former implementation threw here).
const tinyRotation = WingSections.rotate([0, 1, 0], [1e-16, 0, 0], 1e16);
close(tinyRotation[0], 0); close(tinyRotation[1], Math.cos(1)); close(tinyRotation[2], Math.sin(1));
const modalRotations = new Float32Array(positions.length); modalRotations[3] = 1e-16;
assert.doesNotThrow(() => WingSections.update(geometry, positions, modalRotations, 1e16));
assert(geometry.positions.every(Number.isFinite));
const coincidentDisplay = positions.slice(); coincidentDisplay.set(coincidentDisplay.slice(0, 3), 3);
assert.doesNotThrow(() => WingSections.update(geometry, coincidentDisplay, modalRotations, 1e16));
assert(geometry.positions.every(Number.isFinite), "exaggerated coincident ends use their undeformed frame");
assert.throws(() => WingSections.frame([0,0,0], [0,0,0], [0,1,0]), /Degenerate/,
  "an actually invalid undeformed bar is still rejected");
WingSections.update(geometry, positions);
assert.equal(geometry.verticesPerElement, 84, "concave T has 6 cap triangles per end and 16 side triangles");
function bounds(data, e) {
  const stride = data.verticesPerElement, values = [[],[],[]];
  for (let i = e * stride; i < (e + 1) * stride; i++) {
    for (let c = 0; c < 3; c++) values[c].push(data.positions[3 * i + c]);
  }
  return { min: values.map((v) => Math.min(...v)), max: values.map((v) => Math.max(...v)) };
}
const upper = bounds(geometry, 0), lower = bounds(geometry, 1);
close(upper.min[1], -h); close(upper.max[1], 0);
close(lower.min[1], -0.1); close(lower.max[1], -0.1 + h);
close(upper.max[2] - upper.min[2], b); close(lower.max[2] - lower.min[2], b);
function signedVolume(data, e) {
  const p = data.positions, n = data.verticesPerElement;
  let v = 0;
  for (let t = e * n * 3; t < (e + 1) * n * 3; t += 9) {
    v += (p[t] * (p[t+4]*p[t+8]-p[t+5]*p[t+7]) +
      p[t+1] * (p[t+5]*p[t+6]-p[t+3]*p[t+8]) +
      p[t+2] * (p[t+3]*p[t+7]-p[t+4]*p[t+6])) / 6;
  }
  return v;
}
for (let e = 0; e < 2; e++) close(signedVolume(geometry, e), 2 * (b * tf + tw * (h - tf)), 2e-9);

const controls = new Map();
const element = () => ({ value: "", checked: false, hidden: true, className: "", innerHTML: "", style: {},
  classList: { add() {}, remove() {} }, appendChild() {}, setAttribute() {}, addEventListener() {} });
const document = { getElementById(id) { if (!controls.has(id)) controls.set(id, element()); return controls.get(id); },
  createElement: element, querySelectorAll: () => [] };
// Legend DOM is covered in the browser suite; this harness tests real section
// meshes and material/contour geometry without mounting the full application.
const WingLegends={resolveLimits:(_key,min,max)=>({min,max}),getPalette:()=>"spectrum",render(){}};
const sandbox = { BABYLON, WingSections, WingLegends, WingColorScales:require('../web/color_scales.js'), document, console, Float32Array, Int32Array, Int16Array, Uint8Array,
  ArrayBuffer, DataView, Map, Set, window: { addEventListener() {} } };
vm.createContext(sandbox);
const source = fs.readFileSync(path.join(__dirname, "../web/app.js"), "utf8");
vm.runInContext(source.slice(0, source.indexOf("/* --- wiring")) + `
globalThis.app = { state, barSectionMesh, lineMesh, applyBeamStyle, setLayerVisible, applyContour,
  pushPositions, pickElement, syncResultOverlays, restoreBaseline, applyDeformation, asF32, asI32, decodeResultCase };
`, sandbox);
const { app } = sandbox, { state } = app;
assert.throws(() => app.asF32([0, 0, 128, 63]), /expected binary 32-bit data/,
  "an unpack/repack byte array must not silently become an empty displacement buffer");
assert.throws(() => app.asI32(new Uint8Array(3)), /expected binary 32-bit data/);
assert.deepEqual(Array.from(app.asF32(new Uint8Array(new Float32Array([1, 2, 3]).buffer))), [1, 2, 3]);
assert.throws(() => app.decodeResultCase({static:{disp:new Uint8Array(new Float32Array([1]).buffer)}}, {node_count:1}, null),
  /expected 3 finite components, received 1/);
state.engine = new BABYLON.NullEngine(); state.scene = new BABYLON.Scene(state.engine);
state.scene.useRightHandedSystem = true;
state.root = new BABYLON.TransformNode("model", state.scene);
state.baseline = positions; state.deformed = positions.slice();
const blob = (Type, values) => new Uint8Array(new Type(values).buffer);
// app.js permutes model coordinates; inverse-cycled vectors give +Y/-Y here.
const group = { name: "STRINGERS", kind: "bar", count: 2, eids: blob(Int32Array, [701,702]),
  orient: blob(Float32Array, [0,0,1, 0,0,-1]), properties: { type: "PBARL", section } };
const mesh = app.barSectionMesh(group, positions, conn, "#ffdf00", false);
const lines = app.lineMesh("STRINGERS", positions, conn, "#ffdf00", 1, true, true);
lines.barRepresentation = "lines"; lines.hasSectionShape = true; lines.elementIds = new Int32Array([701,702]);
state.barMeshes.push(lines);
state.layers.set("STRINGERS", { meshes: [lines, mesh], visible: true });
assert.equal(mesh.renderingGroupId, 3); assert.equal(mesh.isPickable, true);
const normals = mesh.getVerticesData(BABYLON.VertexBuffer.NormalKind);
close(normals[0], -1); close(normals[1], 0); close(normals[2], 0);
close(normals[9], 1); close(normals[10], 0); close(normals[11], 0);
assert.equal(mesh.metadata.faceElements.length, mesh.getTotalIndices() / 3);
for (let i = 0; i < 28; i++) assert.equal(mesh.metadata.faceElements[i], 0);
for (let i = 28; i < 56; i++) assert.equal(mesh.metadata.faceElements[i], 1);
document.getElementById("beam-style").value = "sections"; app.applyBeamStyle();
assert.equal(mesh.isEnabled(), true); assert.equal(lines.isEnabled(), false);
app.setLayerVisible("STRINGERS", false); assert.equal(mesh.isEnabled(), false); assert.equal(lines.isEnabled(), false);
app.setLayerVisible("STRINGERS", true); assert.equal(mesh.isEnabled(), true); assert.equal(lines.isEnabled(), false);
mesh.computeWorldMatrix(true);
const ray = (y, z) => new BABYLON.Ray(new BABYLON.Vector3(-1, y, z), new BABYLON.Vector3(1, 0, 0), 4);
assert.equal(ray(-0.001, 0.01).intersectsMesh(mesh).hit, true, "ray hits the flange end cap");
assert.equal(ray(-0.02, 0).intersectsMesh(mesh).hit, true, "ray hits the web end cap");
assert.equal(ray(-0.02, 0.01).intersectsMesh(mesh).hit, false, "T recess is empty, not a filled polygon fan");
document.getElementById("beam-style").value = "lines"; app.applyBeamStyle();
assert.equal(mesh.isEnabled(), false); assert.equal(lines.isEnabled(), true);

state.results = { matches: true, modes: [], contours: [{ name: "Bar axial force", unit: "N", min: 10, max: 20,
  location: "element", byId: new Map([[701,10],[702,20]]) }] };
state.contourIdx = 1; app.applyContour();
assert.equal(mesh.material.disableLighting,false,"contoured solid sections retain directional lighting");
assert.equal(mesh.material.twoSidedLighting,false,"closed PBARL solids use their outward normals");
assert.equal(mesh.sideOrientation,BABYLON.Material.CounterClockWiseSideOrientation);
assert(mesh.material.emissiveColor.asArray().every(value=>value<=.06));
let colors = mesh.getVerticesData(BABYLON.VertexBuffer.ColorKind), stride = geometry.verticesPerElement;
for (let v = 1; v < stride; v++) assert.deepEqual(colors.slice(4*v,4*v+4), colors.slice(0,4));
assert.notDeepEqual(colors.slice(0,4), colors.slice(stride*4,stride*4+4), "bar EIDs have separate full-element contours");
assert.deepEqual(Array.from(colors.slice(0,4)), Array.from(lines.getVerticesData(BABYLON.VertexBuffer.ColorKind).slice(0,4)));
state.contourIdx = 0; app.applyContour(); colors = mesh.getVerticesData(BABYLON.VertexBuffer.ColorKind);
close(colors[0], 1); close(colors[1], 223 / 255); close(colors[2], 0);

const before = mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind).slice();
const displaced = positions.slice(); displaced[4] = 0.5;
app.pushPositions(displaced);
const after = mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind);
assert.notDeepEqual(after, before, "physical sections follow deformed bar endpoints");
const expected = WingSections.frame([0,0,0], [2,0.5,0], [0,1,0]);
const data = mesh.sectionGeometry;
const topFlangeIndex = data.template.findIndex(([end,index]) => end === 1 && index === 0);
const tipPoint = Array.from(after.slice(3*topFlangeIndex,3*topFlangeIndex+3));
close(tipPoint[0], 2 + section.polygon_yz_m[0][1] * expected.z[0]);
close(tipPoint[1], 0.5 + section.polygon_yz_m[0][1] * expected.z[1]);
app.restoreBaseline(); assert.deepEqual(mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind), before);

// Pure torsion leaves GRID locations fixed but rotates the T independently
// at its two ends; the skin-to-centroid offset must turn with the section.
const rotations = new Float32Array(positions.length);
rotations[3] = Math.PI / 2;
WingSections.updateMesh(BABYLON, mesh, positions, rotations, 1);
const twisted = mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind);
assert.ok(twisted.every(Number.isFinite));
for (let v = 0; v < data.template.length; v++) {
  const [end] = data.template[v];
  close(twisted[3*v], before[3*v]);
  if (end === 0) {
    close(twisted[3*v+1], before[3*v+1]); close(twisted[3*v+2], before[3*v+2]);
  } else {
    close(twisted[3*v+1], -before[3*v+2]); close(twisted[3*v+2], before[3*v+1]);
  }
}
const twistedBounds = mesh.getBoundingInfo().boundingBox;
assert.ok(twistedBounds.minimum.z < -0.03, "bounds expand to include the rotated web");
mesh.computeWorldMatrix(true);
assert.equal(new BABYLON.Ray(new BABYLON.Vector3(3, 0, -0.025), new BABYLON.Vector3(-1, 0, 0), 4).intersectsMesh(mesh).hit,
  true, "picking detects deformed section outside its original bounding box");
WingSections.updateMesh(BABYLON, mesh, positions, rotations, 0);
assert.deepEqual(mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind), before, "rotation scale zero restores the reference section");
const bodyRotation = Math.PI / 6, cosine = Math.cos(bodyRotation), sine = Math.sin(bodyRotation);
const rotatedPositions = positions.slice(), bodyRotations = new Float32Array(positions.length);
for (let node = 0; node < positions.length / 3; node++) {
  rotatedPositions[3*node] = cosine * positions[3*node] - sine * positions[3*node+1];
  rotatedPositions[3*node+1] = sine * positions[3*node] + cosine * positions[3*node+1];
  bodyRotations[3*node+2] = bodyRotation;
}
WingSections.updateMesh(BABYLON, mesh, rotatedPositions, bodyRotations, 1);
const rigid = mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind);
for (let v = 0; v < before.length / 3; v++) {
  close(rigid[3*v], cosine*before[3*v] - sine*before[3*v+1], 2e-7);
  close(rigid[3*v+1], sine*before[3*v] + cosine*before[3*v+1], 2e-7);
  close(rigid[3*v+2], before[3*v+2], 2e-7);
}

// The UI's normalized deformation remains meaningful when translations are
// identically zero: physical nodal rotations use the displayed scale factor.
state.results.static = { disp: new Float32Array(positions.length), rotation: rotations, maxDisp: 0 };
document.getElementById("deform-scale").value = "0";
app.applyDeformation();
assert.notDeepEqual(mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind), before);
document.getElementById("animate").checked = true; state.phase = 0;
app.applyDeformation();
assert.deepEqual(mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind), before, "animated zero phase resets translation and torsion together");
document.getElementById("animate").checked = false;
state.results.static = null;

const reference = app.barSectionMesh(group, positions, conn, "#c5d1df", true);
state.layers.set("UNDEFORMED", { visible: true, meshes: [reference] });
document.getElementById("beam-style").value = "sections"; app.applyBeamStyle();
assert.equal(reference.isEnabled(), true); assert.equal(reference.isPickable, false);
app.pushPositions(displaced);
assert.deepEqual(reference.getVerticesData(BABYLON.VertexBuffer.PositionKind), before, "undeformed section overlay remains at the reference shape");

const square = { type: "PBARL", shape: "BAR", offset_y_m: -0.01,
  polygon_yz_m: [[-0.01,-0.01], [0.01,-0.01], [0.01,0.01], [-0.01,0.01]] };
const squareGeometry = WingSections.geometry(positions, conn, orient, square);
assert.equal(squareGeometry.verticesPerElement, 36);
const squareBounds = bounds(squareGeometry, 0);
close(squareBounds.max[1], 0); close(squareBounds.min[1], -0.02);
close(squareBounds.max[2] - squareBounds.min[2], 0.02);
close(signedVolume(squareGeometry, 0), 2 * 0.02 ** 2);
state.engine.dispose();
console.log("Section viewer checks passed: T/square dimensions and orientation, cap triangulation, deformed picking/bounds, layer/style switches, full-element contours, independent end torsion/animation, deformation and undeformed overlay.");
