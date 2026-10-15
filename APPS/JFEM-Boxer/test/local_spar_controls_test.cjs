"use strict";
const assert=require("node:assert/strict"),S=require("../web/spar_view.js"),R=require("../web/rib_layout.js");
const p={"planform.area":4,"planform.aspect_ratio":4,"planform.taper_ratio":1,"planform.sweep":0,"planform.sweep_ref_xc":.25,"planform.twist_axis_xc":.25,"planform.root_ref_x":0,"planform.root_ref_y":0,"planform.root_ref_z":0,"planform.dihedral":0,"planform.twist_tip":0,"box.end_eta":1,"box.front_spar_xc":.2,"box.rear_spar_xc":.55,"box.rib_pitch":.5,"box.front_spar_points":[{eta:.5,dxc:.04}],"box.rear_spar_points":[],"leading_edge.enabled":true,"leading_edge.rib_orientation":"front_spar_angle","leading_edge.rib_angle":90};
const dot=(a,b)=>a.reduce((sum,x,i)=>sum+x*b[i],0),near=(a,b)=>assert(Math.abs(a-b)<1e-10,`${a} != ${b}`);
const a=R.leading(p),b=R.leading({...p,"leading_edge.rib_kink_side":"outboard"});
for(const data of[a,b])for(const rib of data.ribs.filter(r=>r.number>1&&r.number<5)){
 const side=data===b?"outboard":"inboard",t=R.tangent(data.geometry,0,rib.frontEta,side),direction=rib.leading.map((v,i)=>v-rib.front[i]);near(dot(t,direction.slice(0,2)),0);
}
assert(Math.abs(a.ribs[2].leading[1]-b.ribs[2].leading[1])>.01);
assert.deepEqual(a.ribs[1].leading,b.ribs[1].leading);assert.deepEqual(a.ribs[3].leading,b.ribs[3].leading);
const over=R.leading({...p,"leading_edge.rib_orientations":[{rib:3,mode:"front_spar_angle",angle:90,kink_side:"outboard"}]});assert.deepEqual(over.ribs[2].leading,b.ribs[2].leading);
assert.throws(()=>R.normalizeOrientations([{rib:3,mode:"front_spar_angle",angle:90,kink_side:"middle"}]));
const draft={...p,"box.front_spar_points":[{eta:.53,dxc:.04}]};assert.deepEqual(S.snapPoint(draft,0,0),{eta:.5,rib:3});assert.equal(draft["box.front_spar_points"][0].eta,.53);
const angled={...draft,"ribs.masters":[{eta:.5,mode:"rear_spar_angle",angle:85,pitch:.5}]},snap=S.snapPoint(angled,0,0),layout=R.derive(angled),rib=layout.ribs.find(r=>r.number===snap.rib);
assert.notEqual(snap.eta,rib.eta);const changed={...angled,"box.front_spar_points":[{...draft["box.front_spar_points"][0],eta:snap.eta}]},position=S.sample(S.derive(changed),0,snap.eta).position;
near((position[0]-rib.rear[0])*rib.direction[1]-(position[1]-rib.rear[1])*rib.direction[0],0);
assert.equal(changed["box.front_spar_points"][0].dxc,.04);
const duplicate={...draft,"box.front_spar_points":[{eta:.53,dxc:.04},{eta:.5,dxc:.01}]};assert.notEqual(S.snapPoint(duplicate,0,0).eta,.5);
console.log("Local spar controls: 6 groups passed (local angles, kink choices, overrides, validation, ordinary/angled snap and duplicate avoidance)");
