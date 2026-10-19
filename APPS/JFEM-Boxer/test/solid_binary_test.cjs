'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),Binary=require('../../jfem_binary.js'),Disk=require('../web/disk_results.js'),Surface=require('../web/solid_boundary.js');
function fixture(preload=false){
 const pieces=[],u=x=>{const b=Buffer.alloc(4);b.writeUInt32LE(x);pieces.push(b);},i=x=>{const b=Buffer.alloc(4);b.writeInt32LE(x);pieces.push(b);},f=x=>{const b=Buffer.alloc(4);b.writeFloatLE(x);pieces.push(b);},d=x=>{const b=Buffer.alloc(8);b.writeDoubleLE(x);pieces.push(b);};
 pieces.push(Buffer.from('JFEM'));u(preload?7:6);for(const v of [14,0,0,0,0,1,0,0,0,2,0,0])u(v);
 for(let n=1;n<=14;n++){i(n);f(n);f(n%3);f(n%5);}
 for(const[eid,nodes]of [[20,Array.from({length:10},(_,i)=>i+1)],[21,[11,12,13,14]]]){i(eid);i(7);u(nodes.length);nodes.forEach(i);}
 u(1);for(let n=0;n<14*6;n++)f(.001*n);f(12);f(34);u(0);u(0);u(0);
 if(preload){pieces.push(Buffer.from('EVAL'));u(1);d(2.5);pieces.push(Buffer.from('STAT'));for(let n=0;n<14*6;n++)f(.002*n);}
 return Buffer.concat(pieces);
}
const decode=v=>{assert.equal(v.BYTES_PER_ELEMENT,1,'Use canonical binary blobs for existing Boxer decoding');return new Int32Array(v.buffer,v.byteOffset,v.byteLength/4);};
let checks=0;
for(const preload of [false,true]){const p=Binary.parse(fixture(preload));assert.equal(p.version,preload?7:6);assert.deepEqual(p.tetras.map(e=>e.nodes.length),[10,4]);assert.deepEqual(p.subcases[0].solidResults,Float32Array.from([12,34]));assert.equal(!!p.staticData,preload);const ready=Disk.prepare(p,{kind:preload?'buckling':'static'});assert.equal(ready.mesh.solid_boundary.triangles.count,20);assert.equal(ready.mesh.solid_boundary.elements[0].nodes.length,10);checks++;}
const shared=Surface.prepare([{eid:1,pid:1,type:'CTETRA',nodes:[0,1,2,3]},{eid:2,pid:2,type:'CTETRA',nodes:[0,2,1,4]}],5);assert.equal(shared.triangles.count,6);assert.equal(shared.topology_counts.internal_faces,1);checks++;
const mismatched=Surface.prepare([{eid:1,pid:1,type:'CTETRA',nodes:[0,1,2,3,5,6,7,8,9,10]},{eid:2,pid:1,type:'CTETRA',nodes:[0,2,1,4,11,12,13,14,15,16]}],17);assert.equal(mismatched.triangles.count,32);checks++;
const tetra=Surface.prepare([{eid:99,pid:2,type:'CTETRA',nodes:[0,1,2,3,4,5,6,7,8,9]}],10);assert.equal(tetra.triangles.count,16);assert.equal(tetra.edges.count,12);assert.deepEqual([...new Set(decode(tetra.triangles.conn))].sort((a,b)=>a-b),Array.from({length:10},(_,i)=>i));const groups=Surface.groups(tetra,decode);assert.equal(groups.length,1);assert.equal(decode(groups[0].edge_conn).length,24);assert.equal(groups[0].elements[0].eid,99);assert(decode(groups[0].eids).every(e=>e===99));checks++;
assert.throws(()=>Surface.prepare([{eid:3,pid:1,type:'CTETRA',nodes:[0,0,1,2]}],3));checks++;
if(process.argv[2]){const p=Binary.parse(fs.readFileSync(process.argv[2]));assert(p.tetras.some(e=>e.nodes.length===10));const ready=Disk.prepare(p,{kind:p.eigenvalues?'frequency':'static'});assert.equal(ready.mesh.solid_boundary.elements.length,p.nSolids);assert.equal(ready.mesh.solid_boundary.elements.filter(e=>e.nodes.length===10).length,p.tetras.length);checks++;console.log(JSON.stringify({artifact:process.argv[2],version:p.version,nodes:p.nNodes,solids:p.nSolids,tetra10:p.tetras.length,externalTriangles:ready.mesh.solid_boundary.triangles.count}));}
console.log(JSON.stringify({passed:true,checks,scope:'JFEM v6/v7 full quadratic connectivity, native field framing and original-element exterior topology'}));
module.exports={fixture};
