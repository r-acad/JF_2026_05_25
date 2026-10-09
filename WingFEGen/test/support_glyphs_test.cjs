"use strict";
const fs=require("node:fs"),path=require("node:path"),assert=require("node:assert/strict"),G=require("../web/support_glyphs.js"),B=require("../web/vendor/babylon.js");
const out=process.argv[2]?path.resolve(process.argv[2]):null,checks=[];let comparisons=0;
const near=(actual,expected)=>{assert(Math.abs(actual-expected)<3e-6*Math.max(1,Math.abs(expected)),`${actual} != ${expected}`);comparisons++;};
const bytes=values=>new Uint8Array(Int32Array.from(values).buffer);
const data={nodes:{count:4,ids:bytes([101,202,303,404])},spc:{nodes:bytes([0,1,2,3]),components:"mixed",node_components:["14","25","36","123456"],assignments:[{node:0,components:"123"}]}};
const positions=Float32Array.from([10,20,30,40,50,60,70,80,90,100,110,120]),original=Buffer.from(positions.buffer).toString("hex");
const layout=G.layout(data,.2);assert.deepEqual(layout.nodes,[0,1,2,3]);assert.deepEqual(layout.counts,{byDof:{1:2,2:2,3:2,4:2,5:2,6:2},translations:6,rotations:6,total:12,nodes:4});
for(const record of layout.records){assert.equal(record.grid,[101,202,303,404][record.node]);assert.equal(record.color,G.COLORS[(record.dof-1)%3]);assert.equal(record.shape,record.dof<4?"cone":"box-outline");for(let axis=0;axis<3;axis++)near(record.centerOffset[axis],axis===(record.dof-1)%3?(record.dof<4?-.2:.1):0);}
checks.push("Exact per-node DOF masks take precedence over assignments; all six DOFs have correct FE offsets, global-axis colors and grid IDs");
const fallback=G.layout({nodes:{count:3,ids:[8,9,10]},spc:{nodes:[0,1,1,2],assignments:[{node:0,components:"16"},{node:1,components:"2"},{node:1,components:"5"},{node:2,components:""}]}});
assert.deepEqual(fallback.records.map(r=>[r.node,r.dof]),[[0,1],[0,6],[1,2],[1,5]]);assert.equal(fallback.counts.nodes,2);
assert.equal(G.layout({spc:{nodes:[0,1],components:"123"}}).counts.total,6);
assert.deepEqual(G.layout({nodes:{count:1},spc:{assignments:[{node:0,components:"45"}]}}).records.map(r=>r.dof),[4,5]);
assert.equal(G.layout({nodes:{count:2},spc:{nodes:[-1,2,Infinity],components:"123"}}).counts.total,0);assert.equal(G.layout(null).counts.total,0);
assert.equal(G.layout({spc:{nodes:[0],components:"mixed"}}).counts.total,0,"unknown mixed masks must not invent constraints");
for(const radius of[-1,NaN,Infinity,".01"])assert.throws(()=>G.layout(data,radius),/radius/);
checks.push("Assignment-only and legacy payloads work; duplicates union without duplicate glyphs, invalid node indices and unknown masks do not invent supports");
const engine=new B.NullEngine(),scene=new B.Scene(engine);scene.useRightHandedSystem=true;
const glyphs=G.create({BABYLON:B,scene,data,positions,radius:.2});
try{
 assert.equal(glyphs.meshes.length,6);assert.equal(scene.meshes.length,6);const beforeMeshes=glyphs.meshes.slice(),beforeMaterials=glyphs.meshes.map(m=>m.material);
 for(const mesh of glyphs.meshes){
  assert.equal(mesh.isPickable,false);assert.equal(mesh.renderingGroupId,2);assert.equal(mesh.metadata.supportGlyphs,true);assert.equal(mesh.metadata.records.length,2);assert.equal(mesh.material.alpha,1);assert.equal(mesh.material.depthFunction,B.Constants.LEQUAL);assert.equal(mesh.material.disableDepthWrite,false);assert.equal(mesh.material.transparencyMode,B.Material.MATERIAL_OPAQUE);
  const color=B.Color3.FromHexString(mesh.metadata.color);mesh.material.diffuseColor.asArray().forEach((v,i)=>near(v,color.asArray()[i]));
  const vertices=mesh.getVerticesData(B.VertexBuffer.PositionKind),indices=mesh.getIndices(),nv=vertices.length/6,ni=indices.length/2;
  for(let k=0;k<2;k++){
   const record=mesh.metadata.records[k],node=record.node,originFE=[positions[3*node+2],positions[3*node],positions[3*node+1]],exported=G.triangles(record,originFE,.2);
   for(let j=0;j<3;j++){const axis=[2,0,1][j],values=Array.from({length:nv},(_,i)=>vertices[3*(k*nv+i)+axis]);near(Math.min(...values),originFE[j]-.2+record.centerOffset[j]);near(Math.max(...values),originFE[j]+.2+record.centerOffset[j]);}
   for(let i=0;i<ni;i++)for(let axis=0;axis<3;axis++)near(vertices[3*indices[k*ni+i]+[2,0,1][axis]],exported[3*i+axis]);
  }
 }
 checks.push("Six batched Babylon meshes use normal depth and opaque axis colors; cone apices and cube extents exactly match exported FE triangles");
 const moved=positions.map((v,i)=>v+(i%3+1)*3);glyphs.update({positions:moved,radius:.4});assert.equal(glyphs.radius,.4);assert.deepEqual(glyphs.meshes,beforeMeshes);assert.deepEqual(glyphs.meshes.map(m=>m.material),beforeMaterials);
 for(const mesh of glyphs.meshes){const vertices=mesh.getVerticesData(B.VertexBuffer.PositionKind),nv=vertices.length/(3*mesh.metadata.records.length);for(let k=0;k<mesh.metadata.records.length;k++){const record=mesh.metadata.records[k];near(record.centerOffset[(record.dof-1)%3],record.dof<4?-.4:.2);for(let axis=0;axis<3;axis++){const values=Array.from({length:nv},(_,i)=>vertices[3*(k*nv+i)+axis]),offset=G.toView(record.centerOffset)[axis];near((Math.max(...values)+Math.min(...values))/2,moved[3*record.node+axis]+offset);}if(record.dof<4){const apex=Array.from(vertices.slice(3*k*nv,3*k*nv+3));apex.forEach((value,j)=>near(value,moved[3*record.node+j]));}}}
 for(const mesh of glyphs.meshes)mesh.setEnabled(false);glyphs.update({radius:.1});assert(glyphs.meshes.every(m=>!m.isEnabled()));
 glyphs.update({radius:0});for(const mesh of glyphs.meshes){const vertices=mesh.getVerticesData(B.VertexBuffer.PositionKind),nv=vertices.length/(3*mesh.metadata.records.length);for(let i=0;i<vertices.length;i++)near(vertices[i],moved[3*mesh.metadata.records[Math.floor(i/(3*nv))].node+i%3]);}
 assert.equal(Buffer.from(positions.buffer).toString("hex"),original);assert.throws(()=>glyphs.update({positions:[0,0,0]}),/supported node/);assert.equal(glyphs.radius,0);
 checks.push("Deformation and radius changes update buffers in place, keep offsets globally aligned, preserve hidden state, allow zero radius and never mutate input coordinates");
 // Rotation outlines retain open faces around the node and cone apex.
 for(const record of glyphs.records.filter(r=>r.dof>3)){const vertices=G.triangles(record,[0,0,0],1),axis=(record.dof-1)%3;for(let i=0;i<vertices.length;i+=3){let edgeCoordinates=0;for(let j=0;j<3;j++)if(Math.abs(vertices[i+j]-(j===axis?.5:0))>=.85999)edgeCoordinates++;assert(edgeCoordinates>=2);}}
 checks.push("Rotation boxes retain solid edge rods with open faces around the translation cone apex");
 glyphs.dispose();glyphs.dispose();assert.equal(scene.meshes.length,0);assert.equal(scene.materials.length,0);assert.throws(()=>glyphs.update(),/disposed/);
 const rotatedData={nodes:{count:1,ids:[707]},spc:{nodes:[0],node_components:['14'],assignments:[{node:0,components:'14',coordinate_id:21,axes:[[0,1,0],[-1,0,0],[0,0,1]]}]}};
 const rotated=G.create({BABYLON:B,scene,data:rotatedData,positions:new Float32Array(3),radius:.2});
 for(const mesh of rotated.meshes){const record=mesh.metadata.records[0],xyz=G.triangles(record,[0,0,0],.2),vertices=mesh.getVerticesData(B.VertexBuffer.PositionKind),indices=mesh.getIndices();
  for(let i=0;i<indices.length;i++)for(let j=0;j<3;j++)near(vertices[3*indices[i]+[2,0,1][j]],xyz[3*i+j]);
  const y=Array.from({length:xyz.length/3},(_,i)=>xyz[3*i+1]);near(Math.min(...y),record.dof===1?-.4:-.1);near(Math.max(...y),record.dof===1?0:.3);
  near(record.centerOffset[0],0);near(record.centerOffset[1],record.dof===1?-.2:.1);
 }
 rotated.update({radius:.4});for(const record of rotated.records){near(record.centerOffset[0],0);near(record.centerOffset[1],record.dof===1?-.4:.2);}rotated.dispose();
 assert.throws(()=>G.layout({nodes:{count:1},spc:{nodes:[0],node_components:['1'],assignments:[{node:0,components:'1',axes:[[NaN,0,0],[0,1,0],[0,0,1]]}]}}),/displacement axes/);
 assert.equal(G.layout({nodes:{count:1},spc:{nodes:[0],node_components:['1'],assignments:[{node:0,components:'1',coordinate_id:99,axes:null}]}}).counts.total,0,'Unresolved non-BASIC coordinates must not invent global support directions');
 checks.push('Imported GRID displacement coordinates rotate translation cones, rotation boxes, normals and exported triangles; resizing keeps the correct local-axis offsets');
 const denseNodes=Array.from({length:1000},(_,i)=>i),densePositions=new Float32Array(3000),dense=G.create({BABYLON:B,scene,data:{nodes:{count:1000},spc:{nodes:denseNodes,components:"123456"}},positions:densePositions,radius:.01});
 assert.equal(dense.counts.total,6000);assert.equal(scene.meshes.length,6);assert.equal(dense.meshes.length,6);for(let i=0;i<10;i++)dense.update({radius:.01+i*.001});assert.equal(scene.meshes.length,6);assert.equal(scene.materials.length,6);dense.dispose();assert.equal(scene.meshes.length,0);assert.equal(scene.materials.length,0);
 checks.push("6,000 support glyphs use six meshes/materials through repeated updates, with clean idempotent disposal");
}finally{glyphs.dispose();scene.dispose();engine.dispose();}
if(out){fs.mkdirSync(out,{recursive:true});fs.writeFileSync(path.join(out,"summary.json"),JSON.stringify({passed:true,groups:checks.length,numericComparisons:comparisons,checks},null,2));}
console.log(`Support glyphs passed ${checks.length} groups and ${comparisons} numerical comparisons.`);
