'use strict';
const assert=require('node:assert/strict'),G=require('../web/load_glyphs.js');
const near=(a,b)=>assert(Math.abs(a-b)<1e-11*Math.max(1,Math.abs(b)),`${a} != ${b}`);
let checks=0;
for(const vector of [[12,-24,36],[-12,24,-36],[0,0,0],[0,-.00003,0]]){
 const forces=G.components(vector,{scale:.002,diag:4}),moments=G.components(vector,{kind:'moment',diag:4,peak:36});
 assert.equal(forces.length,vector.filter(v=>v!==0).length);assert.equal(moments.length,forces.length);
 const sum=[0,0,0];
 for(const g of forces){assert.equal(g.color,G.COLORS[g.component]);near(g.vertices[1][g.component],g.value*.002);assert(g.vertices[1].every((v,k)=>k===g.component||v===0));g.vector.forEach((v,k)=>sum[k]+=v);assert.equal(g.vertices.length,6);checks++;}
 sum.forEach((v,k)=>near(v,vector[k]));
 for(const g of moments){assert.equal(g.vertices.length,52);assert(g.vertices.every(p=>p[g.component]===0));const[a,b]=g.vertices;const cross=[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];assert(cross[g.component]*g.value>0);near(Math.hypot(...a),4*(.008+.022*Math.abs(g.value)/36));checks++;}
}
const scaled=G.components([0,-8,0],{kind:'moment',diag:2,peak:8,multiplier:2})[0];near(scaled.radius,.12);
assert.throws(()=>G.components([1,0,0],{scale:Infinity}),/finite/);assert.equal(G.components([0,NaN,0]).length,0);
console.log(`Load component geometry: ${checks+3} checks passed (sign, axis color, force length, moment plane/handedness/radius, zero components)`);
