'use strict';
const assert=require('node:assert/strict'),D=require('../web/vlm_deformation.js');
const close=(a,b,tol=1e-11)=>{assert.equal(a.length,b.length);a.forEach((v,i)=>assert(Math.abs(v-b[i])<tol,`${v} != ${b[i]}`));};
// Viewer YZX positions; angles and force vectors remain FE XYZ.
const base=Float32Array.of(0,0,0,10,0,0),stations=[{node_index:0,gid:10},{node_index:1,gid:20}],points=Float32Array.of(5,0,2,12,0,2),bindings=D.attach(points,stations,base);
assert.deepEqual(bindings[0].anchors.map(a=>a.w),[.5,.5]);assert.deepEqual(bindings[1].anchors.map(a=>a.w),[1]);
const shifted=Float32Array.of(1,2,3,11,2,3);close(D.point(bindings[0],base,shifted),[6,2,5]);close(D.point(bindings[1],base,shifted),[13,2,5]);
const theta=Float32Array.of(0,0,.1,0,0,.1),pose=D.point(bindings[0],base,base,theta,2);close(pose,[5.4,0,2],1e-7);
const angle=.25,followers=new Map([[10,[0,angle,0]],[20,[0,angle,0]]]);
close(D.force([0,0,100],bindings[0],{scale:.4,followers}),[40*Math.sin(angle),0,40*Math.cos(angle)]);
close(D.force([0,0,100],bindings[0],{scale:.4,followers,linear:true}),[40*angle,0,40]);
close(D.force([0,0,100],bindings[0],{scale:.4}),[0,0,40]);
followers.set(20,[0,-angle,0]);close(D.force([0,0,100],bindings[0],{followers}),[0,0,100*Math.cos(angle)]);
// Large rotations stay norm-preserving; terminal station handles unboxed tip.
const f=[2,-3,5],r=D.rotate(f,[.2,-1.2,2.3]);assert(Math.abs(Math.hypot(...f)-Math.hypot(...r))<1e-12);
close(D.force([0,0,100],bindings[1],{followers}),[-100*Math.sin(angle),0,100*Math.cos(angle)]);
assert.deepEqual(D.attach(points,[],base).map(b=>D.point(b,base,shifted)),[[5,0,2],[12,0,2]]);
// Slanted rib reference centers need not lie at eta * semispan. Force transfer
// uses the backend's station/panel eta, independently of those physical origins.
const oblique=D.attach(Float32Array.of(5,0,2),[{...stations[0],eta:0},{...stations[1],eta:1}],Float32Array.of(0,0,0,8,0,0),{etas:[.5]});
assert.deepEqual(oblique[0].anchors.map(a=>a.w),[.5,.5]);
console.log('VLM deformation: 11 checks passed (rib/eta weights, rigid translation, display rotation, SOL101/106 force laws, fixed loads, terminal wing and empty anchors).');
