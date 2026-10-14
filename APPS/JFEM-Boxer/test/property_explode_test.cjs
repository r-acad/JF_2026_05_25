'use strict';
const assert=require('node:assert/strict'),P=require('../web/panel_explode.js'),B=require('../web/vendor/babylon.js');
const near=(a,b)=>a.forEach((v,i)=>assert(Math.abs(v-b[i])<2e-6,`${a} != ${b}`));
const positions=Float32Array.from([0,0,0,2,0,0,2,1,0,0,1,0,2,2,0,0,2,0,8,1,0,10,1,0]);
const elements=new Map([[1,{nodes:[0,1,2,3],group:{kind:'quad',pid:10}}],[2,{nodes:[3,2,4,5],group:{kind:'quad',pid:20}}],[3,{nodes:[6,7],group:{kind:'bar',pid:10}}],[4,{nodes:[0,1],group:{kind:'rbe3'}}]]);
const p=P.create(),original=[...positions];p.configure(null,elements,positions);p.restore({by:'property',enabled:true,distance:1.25,origin:'centroid'});
assert(p.active);assert.equal(p.propertyCount,2);assert.deepEqual(p.offsetElement(1),p.offsetElement(3));assert.notDeepEqual(p.offsetElement(1),p.offsetElement(2));assert.deepEqual(p.offsetElement(4),[0,0,0]);assert.equal(p.by,'property');
for(const id of[10,20])assert(Math.abs(Math.hypot(...p.offsetProperty(id))-1.25)<1e-12);
near(p.point(1,[0,0,0]),p.offsetProperty(10));assert.deepEqual([...positions],original);
const engine=new B.NullEngine(),scene=new B.Scene(engine);
try{
 const mesh=new B.Mesh('single-property',scene);mesh.metadata={feGroup:{pid:10}};p.applyMesh(mesh);near(mesh.position.asArray(),p.offsetProperty(10));
 const local=Float32Array.from([...elements.get(1).nodes,...elements.get(2).nodes].flatMap(n=>original.slice(3*n,3*n+3))),physical=local.slice();
 const mixed={elementIds:[1,2],importedRanges:[{group:{pid:10},start:0,count:1},{group:{pid:20},start:1,count:1}]};assert(p.applyVertices(mixed,local));
 for(let i=0;i<8;i++)near(Array.from(local.slice(3*i,3*i+3)),Array.from(physical.slice(3*i,3*i+3)).map((v,a)=>v+p.offsetProperty(i<4?10:20)[a]));
 // Both properties share nodes 2 and 3, but their separate vertex copies
 // move rigidly. No averaging or edits to the physical GRID buffer occur.
 assert.notDeepEqual([...local.slice(6,9)],[...local.slice(15,18)]);assert.deepEqual([...positions],original);
 const saved=p.capture();assert.deepEqual(P.normalize(saved),saved);p.restore({...saved,enabled:false});p.applyMesh(mesh);assert.equal(mesh.position.length(),0);assert.equal(p.applyVertices(mixed,physical),false);assert.deepEqual([...physical],[...Float32Array.from([...elements.get(1).nodes,...elements.get(2).nodes].flatMap(n=>original.slice(3*n,3*n+3)))]);
 p.restore({...saved,origin:'ribbay'});assert.equal(p.hasRibOrigins,false);assert.equal(p.effectiveOrigin,'centroid');near(p.originProperty(10),p.center);
 const ribs={ribs:[{number:1,front:[-1,0,0],rear:[1,0,0]},{number:2,front:[-1,4,0],rear:[1,4,0]},{number:3,front:[-1,10,0],rear:[1,10,0]}]};p.configure(null,elements,positions,ribs);assert.equal(p.hasRibOrigins,true);near(p.originProperty(10),[2,0,0]);near(p.originProperty(20),[2,0,0]);
 p.restore({...saved,origin:'rib'});near(p.originProperty(10),[0,0,0]);near(p.originProperty(20),[0,0,0]);p.restore({...saved,origin:'midspan'});near(p.center,[5,1,0]);
 const overlapping=new Map(elements);overlapping.set(5,{nodes:[0,1,2,3],group:{kind:'quad',pid:30}});p.configure(null,overlapping,positions);assert.notDeepEqual(p.offsetProperty(10),p.offsetProperty(30));
 overlapping.set(6,{nodes:[0,1,2,3],group:{kind:'quad',pid:40}});p.configure(null,overlapping,positions);assert.notDeepEqual(p.offsetProperty(30),p.offsetProperty(40));
 const coincident=new Map([[1,{nodes:[0,1,2,3],group:{kind:'quad',pid:30}}],[2,{nodes:[0,1,2,3],group:{kind:'quad',pid:40}}]]);p.restore({...saved,origin:'centroid'});p.configure(null,coincident,positions);assert.notDeepEqual(p.offsetProperty(30),p.offsetProperty(40));
 p.restore({...saved,distance:0});assert.equal(p.active,false);assert.deepEqual(p.offsetElement(1),[0,0,0]);
 const springs=new Map([[11,{id:11,nodes:[0,1],group:{kind:'spring',card_types:{11:'CELAS1'},properties:{PID:700}}}],[12,{id:12,nodes:[3],group:{kind:'spring',card_types:{12:'CELAS3'},properties:{PID:700}}}],[13,{id:13,nodes:[6,7],group:{kind:'spring',card_types:{13:'CELAS2'},properties:{K:2000}}}]]);
 p.configure(null,springs,positions);p.restore(saved);assert.equal(p.propertyCount,1);assert.deepEqual(p.offsetElement(11),p.offsetElement(12));assert.deepEqual(p.offsetElement(13),[0,0,0]);
 const springVertices=Float32Array.from([0,0,0,2,0,0,0,1,0]),ranges={explodedElementRanges:[{id:11,start:0,count:2},{id:12,start:2,count:1}]};assert(p.applyVertices(ranges,springVertices));near([...springVertices.slice(6,9)],p.offsetElement(12).map((v,a)=>v+[0,1,0][a]));
 for(const bad of [{by:'node'},{distance:-1},{distance:Infinity},{origin:'random'},{enabled:'yes'}])assert.throws(()=>p.restore(bad));
 p.restore();assert.equal(p.by,'panel');assert.deepEqual(p.capture(),{enabled:false,origin:'centroid',distance:1});
 console.log('Property explosion: PID rigidity, shared-node copies, batched buffers, coincident centroids, origins/fallback, legacy persistence and reset passed.');
}finally{scene.dispose();engine.dispose();}
