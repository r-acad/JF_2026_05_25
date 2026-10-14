"use strict";
const assert = require("node:assert/strict"), fs = require("node:fs"), path = require("node:path");
const Fuel = require("../web/fuel_tank_view.js"), Spar = require("../web/spar_view.js");
const base = {"planform.area":16,"planform.aspect_ratio":4,"planform.taper_ratio":1,
 "planform.sweep":0,"planform.sweep_ref_xc":.25,"planform.root_ref_x":0,"planform.root_ref_y":0,"planform.root_ref_z":0,
 "planform.dihedral":0,"planform.twist_tip":0,"planform.twist_axis_xc":.25,
 "planform.leading_edge_points":[],"planform.trailing_edge_points":[],
 "box.front_spar_xc":.2,"box.rear_spar_xc":.65,"box.front_spar_points":[],"box.rear_spar_points":[],
 "box.end_eta":1,"box.rib_pitch":.5,"fuel.enabled":true,"fuel.start_rib":1,"fuel.end_rib":0};
const checks = [], test = (name, fn) => { fn(); checks.push({name, passed:true}); };
test("Root-to-box-end default tank uses physical rib numbers", () => {
 const d=Fuel.derive(base); assert(d.valid); assert.equal(d.ribCount,9); assert.equal(d.ribs.length,9);
 assert.deepEqual([d.selection.first,d.selection.last,d.selection.etaStart,d.selection.etaEnd,d.selection.spanMetres],[1,9,0,1,4]);
 assert.equal(d.selection.bays,8); assert.equal(d.selection.polygon.length,4);
 assert.match(Fuel.drawing(d),/ftv-tank/); assert.match(Fuel.drawing(d),/R 9/);
});
test("Changing tank bounds immediately changes the selected polygon", () => {
 const d=Fuel.derive({...base,"fuel.start_rib":3,"fuel.end_rib":6}); assert(d.valid);
 assert.deepEqual([d.selection.etaStart,d.selection.etaEnd,d.selection.spanMetres],[.25,.625,1.5]);
 assert.deepEqual(d.ribs.filter(r=>r.boundary).map(r=>r.index),[3,6]);
 assert(d.selection.polygon.every(p=>p[1]>=1&&p[1]<=2.5));
});
test("End ETA and tie-to-even physical rib pitch match the backend", () => {
 assert.equal(Fuel.derive({...base,"box.rib_pitch":1.6}).ribCount,3);
 assert.equal(Fuel.derive({...base,"box.rib_pitch":4/3.5}).ribCount,5);
 const d=Fuel.derive({...base,"box.end_eta":.5}); assert.equal(d.ribCount,5); assert.equal(d.selection.etaEnd,.5); assert.equal(d.selection.spanMetres,2);
 assert(Fuel.derive({...base,"planform.dihedral":60}).ribCount>9);
});
test("Spar perturbations retain every kink inside tank boundaries", () => {
 const params={...base,"box.front_spar_points":[{eta:.4,dxc:.05}],"box.rear_spar_points":[{eta:.7,dxc:.1,stringer_angle:4}]};
 const copy=JSON.stringify(params),d=Fuel.derive(params),s=Spar.derive(params); assert(d.valid);
 assert.equal(d.selection.polygon.length,8); assert.equal(JSON.stringify(params),copy);
 for(const p of d.selection.polygon){const eta=p[1]/d.geometry.semispan;assert([0,1].some(edge=>Math.abs(Spar.sample(s,edge,eta).position[0]-p[0])<1e-12));}
});
test("Malformed range is retained without stale tank fill or clamping", () => {
 for(const edit of [{"fuel.start_rib":NaN},{"fuel.end_rib":NaN},{"fuel.start_rib":4,"fuel.end_rib":4},{"fuel.start_rib":0},{"fuel.end_rib":10},{"fuel.start_rib":1.5}]){
  const d=Fuel.derive({...base,...edit});assert(!d.valid);assert(d.drawable);assert.equal(d.selection,null);assert.equal(d.ribs.length,9);assert.match(d.error,/Choose tank ribs within 1–9/);assert(!Fuel.drawing(d).includes('class="ftv-tank'));
 }
});
test("Malformed wing or crossing spars give preview feedback", () => {
 const incomplete=Fuel.derive({...base,"planform.area":NaN});assert(!incomplete.valid);assert(!incomplete.drawable);assert.equal(Fuel.drawing(incomplete),"");
 const crossing=Fuel.derive({...base,"box.front_spar_points":[{eta:.5,dxc:.6}]});assert(!crossing.valid);assert(crossing.drawable);assert.equal(crossing.selection,null);assert.match(crossing.error,/spars must remain inside/);
 const badPoints=Fuel.derive({...base,"box.front_spar_points":[{eta:.5,dxc:NaN}]});assert(!badPoints.valid);assert.match(badPoints.error,/finite dxc/);
});
test("Tank-off extent is retained and unrelated drafts do not block it", () => {
 const params={...base,"fuel.enabled":false,"leading_edge.disabled_bays":"2,,4","leading_edge.enabled":true,"box.stringer_angle":NaN,"box.rear_spar_points":[{eta:.5,dxc:0,stringer_angle:NaN}],"material.E":NaN};
 const d=Fuel.derive(params);assert(d.valid);assert.equal(d.enabled,false);assert.match(Fuel.drawing(d),/ftv-tank-off/);
 assert(Number.isNaN(params["box.rear_spar_points"][0].stringer_angle));
});
test("Large rib counts sample only drawing lines and preserve exact tank bounds", () => {
 const d=Fuel.derive({...base,"box.rib_pitch":.0001,"fuel.start_rib":163,"fuel.end_rib":12003});
 assert(d.valid);assert.equal(d.ribCount,40001);assert(d.ribs.length<110);assert(d.sampledRibs);assert(d.ribs.some(r=>r.index===163));assert(d.ribs.some(r=>r.index===12003));assert.equal(d.selection.etaStart,162/40000);
 assert(!/NaN|Infinity|undefined/.test(Fuel.drawing(d)));
});
test("Translated, swept and tapered drawing remains finite", () => {
 const d=Fuel.derive({...base,"planform.root_ref_x":-8,"planform.root_ref_y":17,"planform.root_ref_z":2,"planform.sweep":-24,"planform.taper_ratio":.4,"planform.twist_tip":35,"fuel.start_rib":2,"fuel.end_rib":6});
 assert(d.valid);assert(d.selection.polygon.every(p=>p.every(Number.isFinite)));assert(!/NaN|Infinity|undefined/.test(Fuel.drawing(d)));
});
test("Dry bays split the fuel footprint into exact physical wet regions", () => {
 const d=Fuel.derive({...base,"fuel.disabled_bays":"2,4-5,4"});assert(d.valid);assert.deepEqual(d.disabled,[2,4,5]);assert.equal(d.selection.bays,5);
 assert.deepEqual(d.selection.regions.map(r=>[r.first,r.last]),[[1,2],[3,4],[6,9]]);assert.deepEqual(d.selection.dryRegions.map(r=>[r.first,r.last]),[[2,3],[4,6]]);
 assert.equal((Fuel.drawing(d).match(/class="ftv-tank"/g)||[]).length,3);assert.equal((Fuel.drawing(d).match(/class="ftv-dry"/g)||[]).length,2);
 for(const r of d.selection.regions)assert(r.polygon.every(p=>p[1]>=(r.first-1)*.5-1e-9&&p[1]<=(r.last-1)*.5+1e-9));
});
test("All-dry tanks remain valid and draw no stale wet fill", () => {
 const d=Fuel.derive({...base,"fuel.disabled_bays":"1-8"});assert(d.valid);assert.equal(d.selection.bays,0);assert.equal(d.selection.regions.length,0);assert.equal(d.selection.dryRegions.length,1);
 assert.equal((Fuel.drawing(d).match(/class="ftv-tank"/g)||[]).length,0);assert.match(Fuel.drawing(d),/Dry 1–8/);
});
test("Outside-range exclusions are retained and invalid IDs remain repairable", () => {
 const d=Fuel.derive({...base,"fuel.start_rib":3,"fuel.end_rib":7,"fuel.disabled_bays":"1,4,8"});assert(d.valid);assert.deepEqual(d.selection.dryBays,[4]);assert.deepEqual(d.selection.ignored,[1,8]);assert.equal(d.selection.bays,3);
 for(const value of ["9","0","2-1","2,,4"]){const bad=Fuel.derive({...base,"fuel.disabled_bays":value});assert(!bad.valid);assert(bad.drawable);assert.equal(bad.selection,null);assert(bad.error);}
 assert(Fuel.derive({...base,"fuel.enabled":false,"fuel.disabled_bays":"9"}).valid);
});
test("Angled master ribs define the wet/dry region boundaries", () => {
 const d=Fuel.derive({...base,"ribs.masters":[{eta:.5,mode:"rear_spar_angle",angle:82,pitch:.5}],"fuel.disabled_bays":"4"});assert(d.valid,d.error);
 const region=d.selection.regions[0],rib=d.ribs.find(r=>r.index===region.last);assert(Math.abs(rib.frontEta-rib.eta)>1e-5);
 assert(region.polygon.some(p=>Math.hypot(p[0]-rib.front[0],p[1]-rib.front[1])<1e-8));assert(region.polygon.some(p=>Math.hypot(p[0]-rib.rear[0],p[1]-rib.rear[1])<1e-8));
});
test("Untwisted tank boundaries ignore generated twisted rib projections", () => {
 const Ribs=require("../web/rib_layout.js"),reference=Ribs.derive(base);
 const generated={ribs:reference.ribs.map(r=>({number:r.number,eta:r.eta,front_eta:r.frontEta+.04,front:r.front.map((v,i)=>v+(i===0?.1:0)),rear:r.rear,upper:[r.front,r.rear],lower:[r.front,r.rear]}))};
 assert(Ribs.derive({...base,_rib_geometry:generated}).generated);
 const d=Fuel.derive({...base,_rib_geometry:generated});assert(d.valid,d.error);
 assert.deepEqual(d.selection, Fuel.derive(base).selection);
 assert.deepEqual(d.ribs, Fuel.derive(base).ribs);
});
if(process.argv[2]){fs.mkdirSync(process.argv[2],{recursive:true});fs.writeFileSync(path.join(process.argv[2],"geometry_summary.json"),JSON.stringify({passed:true,checks},null,2));}
console.log(`Fuel tank preview: ${checks.length} geometry/validation groups passed.`);
