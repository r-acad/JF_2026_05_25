'use strict';
const assert=require('node:assert/strict'), E=require('../web/model_entities.js'), B=require('../web/vendor/babylon.js');
const engine=new B.NullEngine(),scene=new B.Scene(engine);
const collection={name:'ENGINE_BEAMS',card:'CBAR',elements:[
 {eid:31,nodes:[1,0],properties:{'Length m':4}}, {eid:32,nodes:[1,2],properties:{'Length m':4}}]};
const state={scene,root:new B.TransformNode('root',scene),deformable:[],elements:new Map(collection.elements.map(e=>[e.eid,{id:e.eid,group:{name:collection.name}}]))};
const near=(a,b)=>a.forEach((v,i)=>assert(Math.abs(v-b[i])<1e-6));
const ends=mesh=>[-.5,.5].map(y=>B.Vector3.TransformCoordinates(new B.Vector3(0,y,0),mesh.computeWorldMatrix(true)).asArray());
try{
 const positions=Float32Array.from([2,-1,-2,2,-1,0,2,-1,2]);
 const meshes=E.engineBeamMeshes(B,{state,positions,collection,diag:10});assert.equal(meshes.length,2);
 meshes.forEach((mesh,i)=>{assert(mesh.engineBeamCylinder&&mesh.isPickable);assert.equal(E.pickedElementId({hit:true,pickedMesh:mesh}),31+i);
   const [a,b]=ends(mesh);near(a,[2,-1,0]);near(b,i?[2,-1,2]:[2,-1,-2]);});
 const moved=Float32Array.from([3,2,0,3,4,0,3,6,0]),explosion={offsetElement:()=>[.1,.2,.3]};
 state.deformable.forEach((r,i)=>{E.updateEngineBeamMesh(B,r,moved,explosion);const[a,b]=ends(r.mesh);near(a,[3.1,4.2,.3]);near(b,i?[3.1,6.2,.3]:[3.1,2.2,.3]);});
 E.updateEngineBeamMesh(B,state.deformable[0],new Float32Array(9));assert(!meshes[0].isVisible);
 E.updateEngineBeamMesh(B,state.deformable[0],positions);assert(meshes[0].isVisible);
 assert.deepEqual(E.engineBeamMeshes(B,{state,positions,collection:{...collection,name:'OTHER'},diag:10}),[]);
 console.log('Engine glyph checks passed: two actual flexible beam halves, CG/endpoint placement, inspection IDs, deformation, explosion and degenerate poses.');
}finally{scene.dispose();engine.dispose();}
