'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const B=require('../web/vendor/babylon.js'),scope={};scope.globalThis=scope;
vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../web/fe_edit_viewport.js'),'utf8'),scope);
const engine=new B.NullEngine(),scene=new B.Scene(engine),baseline=Float32Array.from([0,0,0, 0,0,2, 1,0,2]);
const state={baseline,nodeIds:Int32Array.from([10,20,30]),elements:new Map([[7,{nodes:[0,1,2],group:{kind:'tria'}}]]),diag:3};
const source=Array.from(baseline),overlay=scope.WingFEEditViewport.create({BABYLON:B,scene,read:()=>state});
try{
 const plane={point:[2,3,4],normal:[1,2,3],side_length:8};
 overlay.show({plane,selected_element_ids:[7],candidate_groups:[{nodes:[10,20],retained_node:10}]});
 const fill=scene.getMeshByName('fe-cut-plane-fill-0'),vertices=fill.getVerticesData(B.VertexBuffer.PositionKind),native=[];
 assert(fill&&!fill.isPickable&&fill.material.alpha<.2);
 for(let i=0;i<vertices.length;i+=3){const p=[vertices[i+2],vertices[i],vertices[i+1]];native.push(p);assert(Math.abs(p.reduce((n,x,k)=>n+(x-plane.point[k])*plane.normal[k],0))<1e-5);}
 for(let i=0;i<4;i++)assert(Math.abs(Math.hypot(...native[i].map((x,k)=>x-native[(i+1)%4][k]))-8)<1e-5);
 assert(scene.getMeshByName('fe-selected-elements'));
 assert.deepEqual(scene.getMeshByName('fe-equivalence-node-20').position.asArray(),[0,0,2]);
 assert(scene.meshes.every(m=>m.metadata.feEditOverlay&&!m.isPickable));
 assert.deepEqual(Array.from(baseline),source);
 overlay.show({plane,cut_segments:[[[2,0,0],[2,1,0]]],second_cut_segments:[[[3,0,0],[3,1,0]]],show_parts:true,parts:[{id:'part-7',element_ids:[7]}]});
 const cut=scene.getMeshByName('fe-cut-intersection');
 assert.deepEqual(Array.from(cut.getVerticesData(B.VertexBuffer.PositionKind)),[0,0,2,1,0,2]);
 assert.equal(cut.material.depthFunction,B.Constants.ALWAYS);assert.equal(cut.renderingGroupId,3);assert(!cut.isPickable);
 assert(scene.getMeshByName('fe-cut-intersection-second'));assert(scene.getMeshByName('fe-part-fill-part-7').material.alpha<1);
 assert.equal(scene.getMeshByName('fe-cut-plane-fill-0').material.transparencyMode,B.Material.MATERIAL_ALPHABLEND);
 overlay.showPickedNodes([{id:10,xyz:[1,2,3]},{id:20,xyz:[4,5,6]}]);
 assert.deepEqual(scene.getMeshByName('fe-picked-grid-10').position.asArray(),[2,3,1]);
 assert(scene.getMeshByName('fe-picked-grid-10').material.alpha<1);assert(scene.getMeshByName('fe-picked-translation-vector'));
 overlay.show({plane});assert(scene.getMeshByName('fe-picked-grid-10'),'Plane updates preserve picked endpoints');
 overlay.show({clear:true});assert.equal(scene.meshes.length,0);
 overlay.show({plane:{point:[0,0,0],normal:[1,0,0],side_length:2}});
 assert.equal(scene.meshes.length,2);overlay.show({plane:{point:[0,0,0],normal:[0,1,0],side_length:4}});assert.equal(scene.meshes.length,2);
 overlay.dispose();assert.equal(scene.meshes.length,0);
 console.log('FE edit viewport: plane geometry, native axes, selection, candidate highlighting, nonmutation and disposal pass.');
}finally{scene.dispose();engine.dispose();}
