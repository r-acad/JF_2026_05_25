'use strict';
const assert=require('node:assert/strict'),api=require('../web/rf_panel_render.js');
let groups=0;function test(name,run){run();groups++;console.log('PASS '+name);}
const positions=Float32Array.from([0,0,0,2,0,0,2,1,0,0,1,0]),group={name:'UPPER_SKIN',pid:5000001,kind:'quad',properties:{thickness_m:.2,z0_m:.3}},elements=new Map([[7,{nodes:Int32Array.from([0,1,2,3]),group}]]);
const vertex=(x,y)=>({point:[x,y,0],weights:[(1-x/2)*(1-y),x/2*(1-y),x/2*y,(1-x/2)*y]});
const left={key:'plain:front',fragments:[{eid:7,vertices:[vertex(0,0),vertex(1,0),vertex(1,1),vertex(0,1)]}]},right={key:'stringer:1',fragments:[{eid:7,vertices:[vertex(1,0),vertex(2,0),vertex(2,1),vertex(1,1)]}]};
const contour={failingPartKeys:new Set([right.key]),colorByPart:new Map([[left.key,[0,0,1]],[right.key,[1,0,0]]])};
const options={index:{parts:[left,right]},contour,elements,positions};
test('Passing and failing fractions of the same EID retain separate exact colors and pick owners',()=>{
 const before=positions.slice(),g=api.geometry(options),batch=[...g.groups.values()][0];
 assert.deepEqual(batch.elementIds,[7,7]);assert.deepEqual(batch.partKeys,[left.key,right.key]);assert.deepEqual(batch.faceElements,[0,0,1,1]);
 assert.deepEqual(batch.colors.slice(0,4),[0,0,1,1]);assert.deepEqual(batch.colors.slice(-4),[1,0,0,1]);assert.equal(g.outlines.length/6,7);
 assert.deepEqual(positions,before);assert.deepEqual([...elements.get(7).nodes],[0,1,2,3]);
});
test('RF < 1 removes only the passing half while preserving the neighboring half of the same EID',()=>{
 const g=api.geometry({...options,onlyBelowOne:true}),batch=[...g.groups.values()][0];
 assert.deepEqual(batch.partKeys,[right.key]);assert([...batch.positions].filter((_,i)=>i%3===0).every(x=>x>=1));
 assert.deepEqual([...g.visibleElementIds],[7]);assert.deepEqual([...g.visiblePartKeys],[right.key]);assert.equal(g.outlines.length/6,4);
});
test('Layer and rib/element masks remove complete fragments without changing membership data',()=>{
 assert.equal(api.geometry({...options,visible:()=>false}).groups.size,0);assert.equal(api.geometry({...options,allowed:new Set()}).groups.size,0);
 assert.equal(api.geometry({...options,allowed:new Set([7])}).groups.size,1);assert.equal(left.fragments.length,1);
});
test('A triangulated FE face cancels its display diagonal and selection follows the chosen panel only',()=>{
 const a=vertex(0,0),b=vertex(2,0),c=vertex(2,1),d=vertex(0,1),part={key:'one',fragments:[{eid:7,vertices:[a,b,c]},{eid:7,vertices:[a,c,d]}]},g=api.geometry({...options,index:{parts:[part]},selectedScopeKey:'one',selectedElement:7});
 assert.equal(g.outlines.length/6,4);assert.equal([...g.groups.values()][0].edges.length/6,4);assert.equal(g.selectedOutlines.length/6,4);assert.equal(g.pickedEdges.length/6,4);
 assert.equal(api.geometry({...options,onlyBelowOne:true,selectedScopeKey:left.key,selectedElement:7}).selectedOutlines.length,0);
});
test('Physical thickness and explosion use barycentric displayed coordinates and current section bounds',()=>{
 const g=api.geometry({...options,index:{parts:[left]},thickness:true,explosion:{by:'property',point:(_eid,p)=>p.map((v,i)=>v+[5,6,7][i])}}),batch=[...g.groups.values()][0],z=batch.positions.filter((_,i)=>i%3===2);
 assert(Math.abs(Math.min(...z)-7.3)<1e-12);assert(Math.abs(Math.max(...z)-7.5)<1e-12);assert.equal(batch.indices.length/3,12);
 assert.equal(batch.faceElements.length,12);assert(batch.faceElements.every(v=>v===0));
});
console.log(JSON.stringify({passed:true,groups}));
