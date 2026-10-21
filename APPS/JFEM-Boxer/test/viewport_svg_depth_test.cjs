'use strict';
// SVG painter order and hidden-line removal must agree with both depth ranges.
const assert=require('node:assert/strict');
const B=require('../web/vendor/babylon.js'),SVG=require('../web/viewport_svg.js');
const G=require('../web/support_glyphs.js'),R=require('../web/rib_datums.js');
(async()=>{
 for(const halfZ of [false,true])for(const reversed of [false,true]){
  const engine=new B.NullEngine({renderWidth:800,renderHeight:600});
  engine._isNDCHalfZRange=halfZ;engine.useReverseDepthBuffer=reversed;
  const scene=new B.Scene(engine),camera=new B.FreeCamera('camera',new B.Vector3(0,0,-5),scene);
  camera.setTarget(B.Vector3.Zero());camera.minZ=.01;camera.maxZ=100;
  const surface=(name,z)=>{const mesh=B.MeshBuilder.CreatePlane(name,{size:3},scene);mesh.position.z=z;
   mesh.material=new B.StandardMaterial(name,scene);mesh.material.backFaceCulling=false;return mesh;};
  surface('near-surface',0);surface('far-surface',2);
  B.MeshBuilder.CreateLines('hidden-line',{points:[new B.Vector3(-.5,0,3),new B.Vector3(.5,0,3)]},scene);
  B.MeshBuilder.CreateLines('visible-line',{points:[new B.Vector3(-.5,0,-1),new B.Vector3(.5,0,-1)]},scene);
  scene.render();
  assert.equal(scene.pick(400,300,mesh=>mesh.name.endsWith('-surface')).pickedMesh?.name,'near-surface','Picking retains the front surface');
  const {text,stats}=await SVG.exportScene(scene,camera,engine,{BABYLON:B});
  assert(text.indexOf('data-mesh="far-surface"')<text.indexOf('data-mesh="near-surface"'),'Far surfaces precede near surfaces');
  assert(text.includes('data-mesh="visible-line"'),'Line in front remains visible');
  assert(!text.includes('data-mesh="hidden-line"'),'Line behind opaque surfaces is hidden');
  assert(stats.polygons>=4);
  const glyphs=G.create({BABYLON:B,scene,data:{nodes:{count:1},spc:{nodes:[0],components:'123456'}},positions:new Float32Array(3),radius:.1});
  const datums=R.create({BABYLON:B,scene});datums.update({annotations:{ribs:[{datum_origin:[0,0,0]}]}});
  const expected=reversed?B.Constants.GEQUAL:B.Constants.LEQUAL;
  assert([...glyphs.meshes,...Object.values(datums.meshes)].every(mesh=>mesh.material.depthFunction===expected),'Constraint glyphs and datums use the camera depth convention');
  glyphs.dispose();datums.dispose();scene.dispose();engine.dispose();
 }
 console.log('SVG depth: forward/reversed projection, both clip ranges, surface order and hidden lines passed.');
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
