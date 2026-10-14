"use strict";
const assert = require("node:assert/strict"), fs = require("node:fs"), path = require("node:path");
const V = require("../web/dimensioned_plan_view.js"), P = require("../web/planform_view.js"), S = require("../web/spar_view.js");
const out = process.argv[2] ? path.resolve(process.argv[2]) : null;
const base = { "planform.area": 32, "planform.aspect_ratio": 8, "planform.taper_ratio": .5, "planform.sweep": 10,
  "planform.sweep_ref_xc": .25, "planform.root_ref_x": 1, "planform.root_ref_y": 2, "planform.root_ref_z": 3,
  "planform.dihedral": 0, "planform.twist_tip": 0, "planform.twist_axis_xc": .25,
  "planform.leading_edge_points": [], "planform.trailing_edge_points": [], "box.front_spar_xc": .2, "box.rear_spar_xc": .55,
  "box.front_spar_points": [], "box.rear_spar_points": [], "box.stringer_angle": 0, "box.end_eta": .75, "box.rib_pitch": .6,
  "leading_edge.enabled": false, "leading_edge.start_rib": 1, "leading_edge.end_rib": 0, "leading_edge.disabled_bays": "" };
let numeric = 0; const checks = [];
const near = (actual, expected, label = "coordinate") => { assert(Math.abs(actual - expected) < 2e-11 * Math.max(1, Math.abs(expected)), `${label}: ${actual} != ${expected}`); numeric++; };
const data = V.derive(base); assert(data.valid, data.error); assert.equal(data.physical.bayCount, 10); assert.equal(data.ribs.length, 11);
for (let i = 0; i < data.ribs.length; i++) {
  const rib = data.ribs[i], eta = .75 * i / 10, chord = (8 / 3) * (1 - eta / 2);
  near(rib.eta, eta); assert.equal(rib.number, i + 1);
  for (const [name, xc] of [["front", .2], ["rear", .55]]) {
    near(rib[name][0], 1 + eta * 8 * Math.tan(Math.PI / 18) + (xc - .25) * chord);
    near(rib[name][1], 2 + 8 * eta); near(rib[name][2], 3);
  }
}
checks.push("Physical ribs have independent expected positions, identifiers and counts");
for (const [pitch, count] of [[6 / 2.5, 2], [6 / 3.5, 4]]) assert.equal(V.derive({ ...base, "box.rib_pitch": pitch }).physical.bayCount, count);
assert.equal(V.derive({ ...base, "mesh.elements_per_rib_bay": 17, "mesh.elements_between_stringers": 9 }).ribs.length, 11);
assert.equal(V.derive({ ...base, "planform.dihedral": 30 }).physical.bayCount, Math.round(6 / Math.cos(Math.PI / 6) / .6));
checks.push("Physical bay rounding is ties-to-even and independent of shell subdivisions");
const bentParams = { ...base, "planform.leading_edge_points": [{ eta: .4, xc: -.12 }], "planform.trailing_edge_points": [{ eta: .6, xc: 1.13 }],
  "box.front_spar_points": [{ eta: .3, xc: .24 }], "box.rear_spar_points": [{ eta: .65, xc: .64, stringer_angle: 5 }],
  "leading_edge.enabled": true, "leading_edge.start_rib": 2, "leading_edge.end_rib": 10, "leading_edge.disabled_bays": "3,5-6" };
const bent = V.derive(bentParams); assert(bent.valid, bent.error);
const independent = S.derive(bentParams);
for (const rib of bent.ribs) for (let edge = 0; edge < 2; edge++) S.sample(independent, edge, rib.eta).position.forEach((v, j) => near(rib[edge ? "rear" : "front"][j], v));
assert.deepEqual(bent.ribs.filter(r => r.noseActive).map(r => r.number), [2, 3, 4, 5, 7, 8, 9, 10]);
checks.push("Curved spar references and leading-edge rib extensions follow active physical bays and pylon gaps");
const defaults = V.validateState(), unmirrored = { ...defaults, mirror: false };
assert.equal(defaults.mirror, false); assert.equal(defaults.theme, "dark");
assert.equal(V.validateState({ mirror: true }).mirror, true);
assert.equal(V.validateState({ theme: "white" }).theme, "white");
assert.throws(() => V.validateState({ theme: "blue" }));
for (const mirror of [true, false]) {
  const transform = V.projection(bent.planform, mirror);
  const polygon = bent.planform.right.map(point => transform.map(point).join(",")).join(" ");
  assert(P.drawing(bent.planform, { mirror }).includes(`points="${polygon}" class="pf-wing"`));
  const generated = V.overlay(bent, { ...defaults, mirror });
  assert.equal((generated.match(/data-rib=/g) || []).length, 11);
  assert.equal((generated.match(/data-spar=/g) || []).length, 2);
  assert.equal((generated.match(/data-mirror-rib=/g) || []).length, mirror ? 10 : 0);
  assert(!/NaN|Infinity/.test(generated));
}
assert.equal((V.overlay(bent, { ...unmirrored, showRibs: false }).match(/data-rib=/g) || []).length, 0);
assert.equal((V.overlay(bent, { ...unmirrored, showSpars: false }).match(/data-spar=/g) || []).length, 0);
assert(!V.overlay(bent, { ...unmirrored, showRibLabels: false }).includes('class="dpv-rib-label"'));
checks.push("Dimension and overlay transforms coincide in mirrored and half-wing views; visibility toggles work");
const moved = V.derive({ ...bentParams, "planform.root_ref_x": 10001, "planform.root_ref_y": -800, "planform.root_ref_z": 91 });
for (let i = 0; i < bent.ribs.length; i++) { near(moved.ribs[i].front[0] - bent.ribs[i].front[0], 10000); near(moved.ribs[i].front[1] - bent.ribs[i].front[1], -802); near(moved.ribs[i].front[2] - bent.ribs[i].front[2], 88); }
const dense = V.derive({ ...base, "box.rib_pitch": .0003 }); assert(dense.valid,dense.error); assert(dense.sampledRibs); assert(dense.ribs.length <= 502); assert.equal(dense.ribs.at(-1).number, dense.physical.ribCount);
assert(V.derive({ ...base, "box.front_spar_points": [{ eta: .4, xc: .8 }] }).drawable);
assert.equal(V.derive({ ...base, "planform.area": 0 }).drawable, false);
checks.push("Root offsets, bounded dense previews and invalid geometry are handled without corrupting numbering");
const png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=";
const state = { ...defaults, image: { name: "reference.png", dataUrl: png, width: 1, height: 1 }, transform: { x: -55, y: 112, scale: .125 }, opacity: .4 };
assert.deepEqual(V.validateState(JSON.parse(JSON.stringify(state))), state);
const copy = V.validateState(state); copy.transform.x = 999; assert.equal(state.transform.x, -55);
assert.deepEqual(V.validateState(null), defaults); assert.deepEqual(V.validateState({ mirror: false }), { ...defaults, mirror: false });
for (const bad of [[], 5, { version: 2 }, { unknown: true }, { mirror: "false" }, { showSpars: 0 }, { opacity: 1.1 }, { transform: { x: NaN } }, { transform: { y: 1e8 } }, { transform: { scale: 0 } }, { transform: { rotation: 30 } }, { image: { ...state.image, extra: true } },
  { image: { ...state.image, width: 1.5 } }, { image: { ...state.image, height: 40000 } }, { image: { ...state.image, width: 32768, height: 32768 } },
  { image: { ...state.image, dataUrl: "https://example.com/image.png" } }, { image: { ...state.image, dataUrl: "data:image/svg+xml;base64,PHN2Zy8+" } },
  { image: { ...state.image, dataUrl: "data:image/png;base64,AAAA" } }, { image: { ...state.image, dataUrl: "data:image/png;base64," + "A".repeat(12000000) } }]) assert.throws(() => V.validateState(bad));
checks.push("Portable image and transform validation accepts round trips and rejects malformed, remote or oversized data");
const legacy = { ...state }; delete legacy.viewport;
assert.deepEqual(V.validateState(legacy).viewport, { x: 0, y: 0, scale: 1 });
const navigated = { ...state, viewport: { x: -31, y: 72, scale: 1.8 } };
assert.deepEqual(V.validateState(JSON.parse(JSON.stringify(navigated))), navigated);
const navigationCopy = V.validateState(navigated); navigationCopy.viewport.x = 999; assert.equal(navigated.viewport.x, -31);
for (const viewport of [null, [], { x: Infinity }, { y: -1e8 }, { scale: 0 }, { scale: 1e5 }, { rotation: 10 }]) assert.throws(() => V.validateState({ ...state, viewport }));
checks.push("Independent common viewport defaults preserve older image alignment and validate new saved navigation state");
const tankParams = { ...base, "fuel.enabled": true, "fuel.start_rib": 3, "fuel.end_rib": 9, "fuel.disabled_bays": "5-6" };
const tank = V.derive(tankParams); assert(tank.valid, tank.error);
assert.deepEqual(tank.fuel.selection.regions.map(r=>[r.first,r.last]), [[3,5],[7,9]]);
assert.deepEqual(tank.fuel.selection.dryRegions.map(r=>[r.first,r.last]), [[5,7]]);
for (const region of [...tank.fuel.selection.regions, ...tank.fuel.selection.dryRegions]) {
  const y0 = 2 + (region.first - 1) * .6, y1 = 2 + (region.last - 1) * .6;
  near(Math.min(...region.polygon.map(p=>p[1])), y0); near(Math.max(...region.polygon.map(p=>p[1])), y1);
}
for (const mirror of [false,true]) {
  const svg = V.overlay(tank,{...defaults,mirror,showSpars:false,showRibs:false});
  assert.equal((svg.match(/data-fuel-region="wet"/g)||[]).length,mirror?4:2);
  assert.equal((svg.match(/data-fuel-region="dry"/g)||[]).length,mirror?2:1);
  assert.equal((svg.match(/data-mirror-fuel=/g)||[]).length,mirror?3:0);
  const map=V.projection(tank.planform,mirror).map;
  for (const region of tank.fuel.selection.regions) {
    const closed=[...region.polygon,region.polygon[0]];
    assert(svg.includes('points="'+closed.map(p=>map(p).join(',')).join(' ')+'" class="dpv-fuel dpv-fuel-wet"'));
    if(mirror)assert(svg.includes('points="'+closed.map(p=>map([p[0],4-p[1],p[2]]).join(',')).join(' ')+'" class="dpv-fuel dpv-fuel-wet dpv-mirrored"'));
  }
}
checks.push("Wet and dry tank outlines use exact selected physical rib bounds and mirror around translated root Y, even with structural layers hidden");
for (const change of [{"fuel.enabled":false},{"fuel.end_rib":999},{"fuel.disabled_bays":"3,,5"}])
  assert(!V.overlay(V.derive({...tankParams,...change}),defaults).includes('data-fuel-region='));
const allDry=V.overlay(V.derive({...tankParams,"fuel.disabled_bays":"3-8"}),defaults);
assert(!allDry.includes('data-fuel-region="wet"'));assert(allDry.includes('data-fuel-region="dry"'));
const off=V.derive({...tankParams,"fuel.enabled":false});assert.equal(off.fuel,null);
checks.push("Absent, malformed and all-dry tanks never retain a stale wet outline");
const summary = { passed: true, groups: checks.length, numericComparisons: numeric, checks };
if (out) { fs.mkdirSync(out, { recursive: true }); fs.writeFileSync(path.join(out, "unit-summary.json"), JSON.stringify(summary, null, 2)); fs.writeFileSync(path.join(out, "geometry-fixtures.json"), JSON.stringify([{ name: "straight", parameters: base }, { name: "perturbed_gaps", parameters: bentParams }], null, 2)); }
console.log(`Dimensioned plan view passed ${checks.length} unit groups and ${numeric} numerical comparisons.`);
