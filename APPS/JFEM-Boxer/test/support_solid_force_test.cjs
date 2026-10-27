'use strict';
const assert=require('node:assert/strict'),Loads=require('../web/load_glyphs.js'),Support=require('../web/support_glyphs.js');
let count=0;
for(let axis=0;axis<3;axis++)for(const sign of [-1,1]){
 const vector=[0,0,0];vector[axis]=sign*5;
 const glyph=Loads.components(vector,{diag:10,scale:.2})[0],arrow=Support.forceArrow(glyph,{diameter:.04,diag:10});
 assert.equal(arrow.stemDiameter,.04);assert.equal(arrow.length,1);assert.deepEqual(Array.from(arrow.positions.slice(0,3)),glyph.vertices[1]);assert.equal(arrow.labelVertex,0);
 assert(arrow.positions.every(Number.isFinite));assert.equal(arrow.indices.length%3,0);
 const edges=new Map(),p=arrow.positions;let volume=0;
 const vertex=i=>Array.from(p.slice(3*i,3*i+3)),key=v=>v.map(x=>x.toFixed(8)).join(',');
 for(let i=0;i<p.length/3;i+=3){const a=vertex(i),b=vertex(i+1),c=vertex(i+2);volume+=(a[0]*(b[1]*c[2]-b[2]*c[1])+a[1]*(b[2]*c[0]-b[0]*c[2])+a[2]*(b[0]*c[1]-b[1]*c[0]))/6;for(const [x,y]of[[a,b],[b,c],[c,a]]){const edge=[key(x),key(y)].sort().join('|');edges.set(edge,(edges.get(edge)||0)+1);}}
 assert(volume>0);assert([...edges.values()].every(n=>n===2),'Every solid boundary edge must have exactly two owners');
 const bounds=[0,1,2].map(j=>{const values=Array.from(p).filter((_,i)=>i%3===j);return[Math.min(...values),Math.max(...values)];});
 assert.equal(bounds[axis][sign>0?0:1],0);assert.equal(bounds[axis][sign>0?1:0],sign);
 const thick=Support.forceArrow(glyph,{diameter:.08,diag:10});assert.equal(thick.stemDiameter,.08);assert.equal(thick.length,1);count++;
}
const tiny=Loads.components([1e-9,0,0],{diag:10,scale:1})[0],auto=Support.forceArrow(tiny,{diag:10});assert(auto.stemDiameter<=.08*auto.length);assert(auto.positions.every(Number.isFinite));
for(const diameter of [-1,NaN,Infinity])assert.throws(()=>Support.forceArrow(tiny,{diameter}));
console.log(`Solid reaction arrows: ${count} signed axes plus automatic sizing, watertight topology and invalid-input checks passed.`);
