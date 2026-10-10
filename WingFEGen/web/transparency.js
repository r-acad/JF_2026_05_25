/* Depth peeling orders fragments within batched FE meshes, not mesh centers.
 * Babylon 9's OIT compositor supports a single rendering group: each later
 * group would replace the preceding transparent color. Keep normal geometry
 * together and redraw explicit opaque/x-ray helpers after composition.
 */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingTransparency=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 function create({BABYLON:B=globalThis.BABYLON,scene,throughMeshes=()=>[],onUnsupported=()=>{}}){
  const engine=scene.getEngine(),caps=engine.getCaps(),groups=new Map();
  let culling=new WeakSet();
  const supported=!!(engine.isWebGPU||(engine.webGLVersion>=2&&caps.drawBuffersExtension&&caps.textureFloatRender&&caps.textureHalfFloatRender&&caps.blendFloat));
  let enabled=false,warned=false;
  function restoreGroups(){
   for(const [mesh,group]of groups)if(!mesh.isDisposed())mesh.renderingGroupId=group;groups.clear();
   for(const material of scene.materials||scene.meshes.map(mesh=>mesh.material))if(material&&culling.has(material))material.separateCullingPass=true;
   culling=new WeakSet();
  }
  function setEnabled(value){
   if(value&&!supported&&!warned){warned=true;onUnsupported();}
   const next=!!value&&supported;if(next===enabled)return enabled;
   enabled=next;scene.useOrderIndependentTransparency=next;
   // Five dual passes retain up to ten depth layers. This bounds the cost for
   // large imported decks; deeper interiors may be omitted at grazing views.
   if(next)scene.depthPeelingRenderer.passCount=5;else restoreGroups();
   return enabled;
  }
  const before=scene.onBeforeActiveMeshesEvaluationObservable.add(()=>{
   if(!enabled)return;
   for(const mesh of scene.meshes){
    if(mesh.renderingGroupId!==0){groups.set(mesh,mesh.renderingGroupId);mesh.renderingGroupId=0;}
    // Peeling handles both sides at their actual depth. A separate culling
    // pass duplicates work and defeats two-sided lighting on midsurfaces.
    if(mesh.material?.separateCullingPass){culling.add(mesh.material);mesh.material.separateCullingPass=false;}
   }
   for(const mesh of groups.keys())if(mesh.isDisposed())groups.delete(mesh);
  });
  const after=scene.onAfterRenderObservable.add(()=>{
   if(!enabled)return;
   const through=new Set(throughMeshes()),overlays=new Set(through);
   for(const mesh of scene.meshes)if(mesh.material?.depthFunction===B.Constants.ALWAYS)overlays.add(mesh);
   if(!overlays.size)return;
   const depthFunction=engine.getDepthFunction(),depthWrite=engine.getDepthWrite(),alpha=engine.getAlphaMode();
   try{
    for(const mesh of overlays){
     const material=mesh.material;
     if(mesh.isDisposed()||!mesh.isEnabled()||!mesh.isVisible||mesh.visibility<=0||!material||material.alpha===0)continue;
     // Custom translucent triangle shaders require their own composition.
     // Current explicit FE overlays are opaque geometry or LinesMesh.
     const blending=material.needAlphaBlendingForMesh(mesh);
     if(blending&&!(mesh instanceof B.LinesMesh))continue;
     const originalDepth=material.depthFunction,originalWrite=material.disableDepthWrite;
     try{
      material.depthFunction=B.Constants.ALWAYS;material.disableDepthWrite=true;
      scene.resetCachedMaterial();
      for(const subMesh of mesh.subMeshes||[])subMesh.render(blending);
     }finally{material.depthFunction=originalDepth;material.disableDepthWrite=originalWrite;}
    }
   }finally{engine.setDepthFunction(depthFunction);engine.setDepthWrite(depthWrite);engine.setAlphaMode(alpha);scene.resetCachedMaterial();}
  });
  function dispose(){setEnabled(false);scene.onBeforeActiveMeshesEvaluationObservable.remove(before);scene.onAfterRenderObservable.remove(after);}
  return{setEnabled,dispose,supported,get enabled(){return enabled;}};
 }
 return{create};
});
