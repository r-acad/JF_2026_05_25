'use strict';
const assert=require('node:assert/strict'),R=require('../web/imported_render.js');
const bytes=a=>new Uint8Array(a.buffer),i32=a=>new Int32Array(a.buffer,a.byteOffset,a.byteLength/4),f32=a=>new Float32Array(a.buffer,a.byteOffset,a.byteLength/4);
const groups=Array.from({length:1200},(_,i)=>({name:'P'+i,pid:i+1,kind:i%2?'tria':'quad',count:1,eids:bytes(Int32Array.of(5000+i)),conn:bytes(Int32Array.from(i%2?[0,1,2]:[0,1,2,3])),orient:bytes(new Float32Array()),properties:{thickness_m:i+.1}}));
const batches=R.batches(groups,i32,f32);assert.equal(batches.length,2);assert.equal(batches.reduce((n,g)=>n+g.count,0),1200);
for(const batch of batches)for(const range of batch.sourceRanges){assert.equal(groups[range.group.pid-1],range.group);assert.equal(i32(batch.eids)[range.start],5000+range.group.pid-1);}
const group=batches[0],indices=Int32Array.from({length:group.count*6},(_,i)=>i),layers=new Map(group.sourceRanges.map(r=>[r.group.name,{visible:true}]));
const mesh={importedRanges:group.sourceRanges.map(r=>({...r})),importedIndicesPerElement:6,getIndices:()=>indices,updateIndices(a){this.updated=a.slice();},setEnabled(v){this.enabled=v;}};
R.sync(mesh,layers);assert(mesh.enabled);assert.deepEqual(mesh.updated,indices);
layers.get(group.sourceRanges[2].group.name).visible=false;R.sync(mesh,layers);assert(mesh.updated.subarray(12,18).every(x=>x===0));assert.deepEqual(mesh.updated.subarray(18),indices.subarray(18));
for(const layer of layers.values())layer.visible=false;R.sync(mesh,layers);assert(!mesh.enabled);
for(const layer of layers.values())layer.visible=true;R.sync(mesh,layers);assert(mesh.enabled);assert.deepEqual(mesh.updated,indices);
assert.equal(R.batches(groups.slice(0,10),i32,f32)[0],groups[0]);
const fields=['eids','conn','orient','centers','x','y','z','lengths'],buffers={};
for(const key of fields)buffers[key]=bytes(key==='eids'?Int32Array.of(42):key==='conn'?Int32Array.of(0,1,2):new Float32Array(key==='orient'?0:key==='lengths'?1:3).fill(.25));
const compact={groups:[{count:1,kind:'tria',binary_offsets:new Array(8).fill(0)}],imported_buffers:buffers};
const material={id:7,E_Pa:71000000000,nu:.3};buffers.materials=[material];compact.groups[0].properties={material:0,face_material:0,plies:[{material:0,thickness_m:.002}]};
R.expand(compact);assert.equal(compact.imported_buffers,undefined);assert.deepEqual(Array.from(i32(compact.groups[0].eids)),[42]);assert.deepEqual(Array.from(i32(compact.groups[0].conn)),[0,1,2]);assert.deepEqual(Array.from(f32(compact.groups[0].axes.x)),[.25,.25,.25]);assert.equal(compact.groups[0].orient.byteLength,0);
assert.equal(compact.groups[0].properties.material,material);assert.equal(compact.groups[0].properties.face_material,material);assert.equal(compact.groups[0].properties.plies[0].material,material);
const remote={imported_deck:{},bbox:{min:[0,0,-999],max:[1,1,1]},nodes:{xyz:bytes(Float32Array.from([0,0,0,1,1,1,0,0,-999]))},groups:[{conn:bytes(Int32Array.of(0,1))}]};
assert.deepEqual(R.bounds(remote),{min:[0,0,0],max:[1,1,1]});assert.equal(R.bounds(remote,true),remote.bbox);assert.equal(f32(remote.nodes.xyz)[8],-999);
const planes=require('../web/view_planes.js').layout({...remote,bbox:R.bounds(remote)},{z:0,spacing:1});assert.equal(planes.root[2],.5);assert(planes.symmetry.every(p=>Math.abs(p[2])<2));
// Real Babylon picking: a degenerate [0,0] pair still hits at vertex zero.
// Hidden first/middle properties must therefore be absent from line indices.
const B=require('../web/vendor/babylon.js'),engine=new B.NullEngine(),scene=new B.Scene(engine);
try{
 const line=new B.LinesMesh('imported-bars',scene,null,undefined,false,false,false),vd=new B.VertexData();
 vd.positions=Float32Array.from([0,0,0,1,0,0,2,0,0,3,0,0,4,0,0,5,0,0]);vd.indices=Int32Array.from([0,1,2,3,4,5]);vd.applyToMesh(line,true);
 line.intersectionThreshold=.02;line.elementIds=Int32Array.from([51,62,73]);line.metadata={feGroup:{kind:'bar'}};
 line.importedRanges=Array.from({length:3},(_,i)=>({group:{name:'B'+i},start:i,count:1}));line.importedIndicesPerElement=2;
 const switches=new Map(line.importedRanges.map(r=>[r.group.name,{visible:true}]));
 const pick=x=>{line.computeWorldMatrix(true);const hit=scene.pickWithRay(new B.Ray(new B.Vector3(x,0,2),new B.Vector3(0,0,-1)));return hit?.hit?line.elementIds[line.metadata.faceElements[hit.faceId]]:null;};
 R.sync(line,switches);assert.equal(pick(.5),51);assert.equal(pick(2.5),62);assert.equal(pick(4.5),73);
 switches.get('B0').visible=false;R.sync(line,switches);assert.equal(pick(0),null);assert.equal(pick(.5),null);assert.equal(pick(2.5),62);assert.equal(pick(4.5),73);
 switches.get('B1').visible=false;R.sync(line,switches);assert.equal(pick(2.5),null);assert.equal(pick(4.5),73);
 switches.get('B2').visible=false;R.sync(line,switches);assert.equal(pick(4.5),null);assert.equal(line.isEnabled(),false);
 for(const item of switches.values())item.visible=true;R.sync(line,switches);
 assert.deepEqual(Array.from(line.getIndices()),[0,1,2,3,4,5]);assert.equal(pick(.5),51);assert.equal(pick(2.5),62);assert.equal(pick(4.5),73);
}finally{engine.dispose();}
console.log('Imported GPU batches: identities, exact hide/show, compact buffers, hidden-bar ray picking and restored EIDs passed.');
