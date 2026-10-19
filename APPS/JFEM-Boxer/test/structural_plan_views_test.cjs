"use strict";
const assert=require('node:assert/strict');
const Spar=require('../web/spar_view.js'),Ribs=require('../web/rib_layout.js'),Stringers=require('../web/stringer_layout.js'),Planform=require('../web/planform_view.js');
const base={'planform.area':48,'planform.aspect_ratio':3,'planform.taper_ratio':1,'planform.sweep':0,'planform.sweep_ref_xc':0,'planform.root_ref_x':0,'planform.root_ref_y':0,'planform.root_ref_z':0,'planform.dihedral':0,'planform.twist_tip':0,'planform.twist_axis_xc':.25,'planform.leading_edge_points':[],'planform.trailing_edge_points':[],'box.front_spar_xc':.2,'box.rear_spar_xc':.8,'box.front_spar_points':[],'box.rear_spar_points':[],'box.stringer_angle':0,'box.stringer_pitch':.4,'box.end_eta':1,'box.rib_pitch':1,'ribs.masters':[],'mesh.stringer_runout_ratio':.75};
const near=(a,b)=>assert(Math.abs(a-b)<1e-10*Math.max(1,Math.abs(b)),`${a} != ${b}`),checks=[];
let data=Stringers.derive(base);assert(data.valid,data.error);assert.equal(data.pathCount,5);assert.equal(data.paths.length,5);assert(!data.generated);assert.equal(data.ribs.length,7);
for(let i=0;i<5;i++){const path=data.paths[i];assert.equal(path.index,i+1);assert.equal(path.side,'reference');assert.equal(path.runout,null);near(path.points[0][0],1.2+.4*i);near(path.points.at(-1)[0],1.2+.4*i);near(path.points[0][1],0);near(path.points.at(-1)[1],6);}
checks.push('Rectangular box: five independent expected stringer positions, exact pitch, and unchanged physical rib identities');
const swept=Stringers.derive({...base,'planform.sweep':30,'planform.root_ref_x':10,'planform.root_ref_y':-2,'planform.root_ref_z':3,'planform.dihedral':10});assert(swept.valid,swept.error);
for(let i=0;i<5;i++){near(swept.paths[i].points[0][0],11.2+.4*i);near(swept.paths[i].points.at(-1)[0],11.2+.4*i+6*Math.tan(Math.PI/6));near(swept.paths[i].points.at(-1)[1],4);near(swept.paths[i].points.at(-1)[2],3+6*Math.tan(Math.PI/18));}
checks.push('Reference paths follow sweep, dihedral and translated FE coordinates without moving the model definition');
const angle=Stringers.derive({...base,'box.stringer_angle':10});assert(angle.valid,angle.error);assert(angle.paths.at(-1).runout);near(angle.paths.at(-1).runout.eta,.1/(6*Math.tan(Math.PI/18)));near(angle.paths.at(-1).runout.points[0][0],2.9);near(angle.paths.at(-1).runout.points[1][0],3.2);
checks.push('Angled stringers stop at the first independent projected run-out clearance and connect to the correct spar');
const kinkParams={...base,'box.rear_spar_points':[{eta:.5,dxc:0,stringer_angle:5},{eta:1,dxc:0,stringer_angle:-5}]},kink=Stringers.derive(kinkParams);assert(kink.valid,kink.error);
near(kink.paths[0].points[1][0],1.2+3*Math.tan(Math.PI/36));near(kink.paths[0].points.at(-1)[0],1.2);
assert.equal(kink.paths[0].points[1][1],3);assert.equal(JSON.stringify(kinkParams['box.rear_spar_points']),JSON.stringify([{eta:.5,dxc:0,stringer_angle:5},{eta:1,dxc:0,stringer_angle:-5}]));
checks.push('Piecewise angles preserve continuous kink positions and input identity');
const dense=Stringers.derive({...base,'box.stringer_pitch':.00001});assert(dense.valid,dense.error);assert(dense.sampled);assert.equal(dense.paths.length,400);assert.equal(dense.paths[0].index,1);assert.equal(dense.paths.at(-1).index,dense.pathCount);assert(dense.pathCount>200000);
for(const pitch of [0,-1,NaN])assert.equal(Stringers.derive({...base,'box.stringer_pitch':pitch}).valid,false);
for(const ratio of [0,2,NaN])assert.equal(Stringers.derive({...base,'mesh.stringer_runout_ratio':ratio}).valid,false);
assert.equal(Stringers.drawing(Stringers.derive({...base,'planform.area':0})), '');
assert(!/NaN|Infinity/.test(Stringers.drawing(Stringers.derive({...base,'box.stringer_angle':90}))));
checks.push('Dense previews are bounded and evenly sampled without capping physical model counts; invalid drafts never produce nonfinite SVG');
const generated={xyz:new Float32Array([1,0,.1,1.1,3,.2,1.2,6,.3,1,0,-.1,1.1,3,-.2,1.2,6,-.3]),annotations:{stringers:[{index:1,side:'upper',label:'U1',nodes:[0,1,2]},{index:1,side:'lower',label:'L1',nodes:[3,4,5]}]}},actual=Stringers.derive(base,{generated});
assert(actual.valid,actual.error);assert(actual.generated);assert.equal(actual.pathCount,2);assert.equal(actual.paths[0].points.length,3);near(actual.paths[1].points[2][2],-.30000001192092896);
assert.equal(Stringers.derive(base,{generated:{...generated,xyz:[0,1,2]}}).valid,false);
const xml=Stringers.drawing(Stringers.derive(base,{generated:{...generated,annotations:{stringers:[{index:1,side:'upper',label:'<script>x</script>',nodes:[0,1,2]}]}}}));assert(!xml.includes('<script>'));assert(xml.includes('&lt;script&gt;'));
checks.push('Current generated upper/lower paths retain every source node; invalid indices reject and labels are escaped');
const p=Spar.derive(base),transform=Planform.editorTransform(p),context=Spar.referenceDrawing(p,{transform}),ribs=Ribs.drawing(Ribs.derive(base)),strings=Stringers.drawing(data);
assert(ribs.includes(context),'Ribs must use the exact same plan outline, spars and box-end context as Spars');
for(const cls of ['sf-surface','pf-base','sf-box','sf-front','sf-rear','sf-extension','pf-box-end','pf-editor-axis']){assert(context.includes(cls));assert(strings.includes(cls));}
assert(ribs.includes('data-rib-part="anchor"'));assert(ribs.includes('Master ribs and interpolated physical ribs'));assert(strings.includes('data-stringer="reference-1"'));
assert(!/NaN|Infinity/.test(ribs+strings));checks.push('Spars, Ribs and Stringers use one shared geometry context; editable rib anchors remain available');
console.log(JSON.stringify({passed:true,groups:checks.length,checks},null,2));
module.exports={base};
