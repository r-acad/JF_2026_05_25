'use strict';
// Portable engine-level stress regression. Thousands of distinct property
// materials reproduce a large deck without distributing its private model.
const assert=require('node:assert/strict'),B=require('../web/vendor/babylon.js'),T=require('../web/transparency.js');
const results=[];
for(const count of [500,2500,5000]){
 const engine=new B.NullEngine(),scene=new B.Scene(engine),camera=new B.FreeCamera('camera',new B.Vector3(0,0,-10),scene);scene.activeCamera=camera;
 scene.blockMaterialDirtyMechanism=true;
 const meshes=[];for(let i=0;i<count;i++){
  const mesh=B.MeshBuilder.CreatePlane('property-'+i,{size:1},scene),material=new B.StandardMaterial('pid-'+i,scene);
  material.disableLighting=true;material.alpha=1;material.transparencyMode=B.Material.MATERIAL_OPAQUE;mesh.material=material;meshes.push(mesh);
 }
 scene.blockMaterialDirtyMechanism=false;scene.render();
 const original=B.Material.prototype._markAllSubMeshesAsDirty;let visits=0;
 B.Material.prototype._markAllSubMeshesAsDirty=function(...args){if(!this.getScene().blockMaterialDirtyMechanism&&!this._blockDirtyMechanism)visits+=this.getScene().meshes.length;return original.apply(this,args);};
 const edit=alpha=>{scene.markAllMaterialsAsDirty(B.Material.AllDirtyFlag);for(const mesh of meshes){mesh.material.alpha=alpha;mesh.material.transparencyMode=alpha===1?B.Material.MATERIAL_OPAQUE:B.Material.MATERIAL_ALPHABLEND;}};
 try{
  const before=[];for(const alpha of [.55,1]){visits=0;const start=performance.now();edit(alpha);before.push({alpha,ms:performance.now()-start,visits});}
  const controller=T.create({BABYLON:B,scene});
  const after=[];for(const alpha of [.55,1]){visits=0;const start=performance.now();T.batchMaterials(scene,()=>edit(alpha));after.push({alpha,ms:performance.now()-start,visits});assert.equal(visits,0);}
  assert(meshes.every(mesh=>mesh.material.alpha===1&&mesh.material.transparencyMode===B.Material.MATERIAL_OPAQUE));
  assert(before.every(row=>row.visits>=2*count*count),'Stress must reproduce quadratic material invalidation');
  assert(!scene.blockMaterialDirtyMechanism);controller.dispose();results.push({count,before,after});
 }finally{B.Material.prototype._markAllSubMeshesAsDirty=original;scene.dispose();engine.dispose();}
}
console.log(JSON.stringify({passed:true,results},null,2));
