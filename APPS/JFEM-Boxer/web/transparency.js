/* Depth peeling orders fragments within batched FE meshes, not mesh centers.
 * Babylon 9's OIT compositor supports a single rendering group: each later
 * group would replace the preceding transparent color. Keep normal geometry
 * together and redraw explicit opaque/x-ray helpers after composition.
 */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingTransparency=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 function invalidateMaterialDraws(scene,dirty=defines=>defines.markAllAsDirty()){
  for(const mesh of scene.meshes)for(const sub of mesh.subMeshes||[]){
   const material=sub.getMaterial()||(scene._hasDefaultMaterial?scene.defaultMaterial:null);
   if(!material||material._blockDirtyMechanism)continue;
   for(const draw of sub._drawWrappers||[])if(draw?.defines?.markAllAsDirty&&draw.materialContext===material._materialContext)dirty(draw.defines);
  }
  scene.resetCachedMaterial();
 }
 function linearGlobalInvalidation(scene,B){
  const original=scene.markAllMaterialsAsDirty;
  if(typeof original!=="function"||typeof B.AbstractMesh?.prototype?._markSubMeshesAsDirty!=="function")return()=>{};
  // Keep other full-scene operations (including the end of mesh construction)
  // linear as well. Narrower or filtered calls retain the engine implementation. This is scene-local;
  // no vendor source or global Babylon prototypes are modified.
  function markAll(flags,predicate){
   if(flags!==B.Material.AllDirtyFlag||predicate)return original.call(this,flags,predicate);
   if(!this.blockMaterialDirtyMechanism)invalidateMaterialDraws(this);
  }
  scene.markAllMaterialsAsDirty=markAll;
  return()=>{if(scene.markAllMaterialsAsDirty===markAll)scene.markAllMaterialsAsDirty=original;};
 }
 // Babylon 9's material invalidation visits every scene mesh for each
 // material. A global OIT switch followed by hundreds of alpha changes
 // therefore costs materials * meshes, even though geometry is unchanged.
 // Use the bundled engine's batch guard and invalidate each existing draw
 // wrapper once. This retains cached shader effects, instances, contours and
 // all render-pass wrappers (including depth peeling), without rebuilding
 // any mesh. Fall back to ordinary setters on an unsupported engine version.
 function batchMaterials(scene,update){
  if(!scene||scene.blockMaterialDirtyMechanism||typeof scene._forceBlockMaterialDirtyMechanism!=="function"||
    !scene.meshes.every(mesh=>typeof mesh._markSubMeshesAsDirty==="function"))return update();
  scene._forceBlockMaterialDirtyMechanism(true);
  try{return update();}
  finally{
   scene._forceBlockMaterialDirtyMechanism(false);
   invalidateMaterialDraws(scene);scene.prePassRenderer?.markAsDirty();
  }
 }
 function create({BABYLON:B=globalThis.BABYLON,scene,throughMeshes=()=>[],onUnsupported=()=>{}}){
  const engine=scene.getEngine(),caps=engine.getCaps(),groups=new Map();
  const restoreInvalidation=linearGlobalInvalidation(scene,B);
  const depthRenderers=new Map();
  function prepareDepthRenderer(){
   const renderer=scene.depthPeelingRenderer;
   if(!engine.isWebGPU||depthRenderers.has(renderer)||typeof renderer.render!=="function"||
     typeof renderer._renderSubMeshes!=="function"||typeof engine.flushFramebuffer!=="function")return;
   const originalRender=renderer.render,originalDraw=renderer._renderSubMeshes;
   let firstDepthPass=false;
   function draw(...args){
    const result=originalDraw.apply(this,args);
    if(firstDepthPass){
     firstDepthPass=false;
     // Submit the initial RG32F min/max-depth pass before its texture is sampled
     // by the first peel. Merely ending its render pass is insufficient on the
     // supported WebGPU path. This queues GPU work once per frame: no readback,
     // CPU wait or per-element submission is involved. Preserve full precision;
     // rounding depth to half float merges adjacent thin FE skins into bands.
     engine.flushFramebuffer();
    }
    return result;
   }
   function render(...args){
    const originalEquation=engine.setAlphaEquation;
    function equation(value,target=0){
     // Babylon's alpha mode setter can reset the actual equation to ADD while
     // leaving its MAX cache unchanged. Reapply equations during peeling only.
     if(engine._alphaEquation)engine._alphaEquation[target]=-1;
     return originalEquation.call(this,value,target);
    }
    firstDepthPass=true;engine.setAlphaEquation=equation;
    try{return originalRender.apply(this,args);}
    finally{firstDepthPass=false;if(engine.setAlphaEquation===equation)engine.setAlphaEquation=originalEquation;}
   }
   renderer.render=render;renderer._renderSubMeshes=draw;
   depthRenderers.set(renderer,{originalRender,originalDraw,render,draw});
  }
  const prepasses=new Map();
  function preparePrePass(){
   const renderer=scene.prePassRenderer;
   if(!renderer||prepasses.has(renderer)||typeof renderer._markAllMaterialsAsPrePassDirty!=="function"||
     typeof B.AbstractMesh?.prototype?._markSubMeshesAsDirty!=="function")return;
   // Babylon's prepass uses its own material loop rather than the scene
   // helper. Only dirty the prepass flag once per material draw wrapper.
   const original=renderer._markAllMaterialsAsPrePassDirty;
   const mark=()=>{if(!scene.blockMaterialDirtyMechanism)invalidateMaterialDraws(scene,defines=>defines.markAsPrePassDirty());};
   renderer._markAllMaterialsAsPrePassDirty=mark;prepasses.set(renderer,{original,mark});
  }
  let culling=new WeakSet();
  const supported=!!(engine.isWebGPU?(caps.textureFloatLinearFiltering&&caps.blendFloat):
    (engine.webGLVersion>=2&&caps.drawBuffersExtension&&caps.textureFloatRender&&caps.textureHalfFloatRender&&caps.textureFloatLinearFiltering&&caps.blendFloat));
  let enabled=false,warned=false;
  function restoreGroups(){
   for(const [mesh,group]of groups)if(!mesh.isDisposed())mesh.renderingGroupId=group;groups.clear();
   for(const material of scene.materials||scene.meshes.map(mesh=>mesh.material))if(material&&culling.has(material))material.separateCullingPass=true;
   culling=new WeakSet();
  }
  function setEnabled(value){
   if(value&&!supported&&!warned){warned=true;onUnsupported();}
   const next=!!value&&supported;if(next===enabled)return enabled;
   batchMaterials(scene,()=>{
    enabled=next;scene.useOrderIndependentTransparency=next;
    // Five dual passes retain up to ten depth layers. This bounds the cost for
    // large imported decks; deeper interiors may be omitted at grazing views.
    if(next){scene.depthPeelingRenderer.passCount=5;prepareDepthRenderer();preparePrePass();}else restoreGroups();
   });
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
   const through=new Set(throughMeshes()),overlays=new Set([...through].map(mesh=>mesh._wingScreenStroke||mesh));
   for(const mesh of scene.meshes)if(mesh.material?.depthFunction===B.Constants.ALWAYS)overlays.add(mesh._wingScreenStroke||mesh);
   if(!overlays.size)return;
   const depthFunction=engine.getDepthFunction(),depthWrite=engine.getDepthWrite(),alpha=engine.getAlphaMode();
   try{
    for(const mesh of overlays){
     const material=mesh.material;
     if(mesh.isDisposed()||!mesh.isEnabled()||!mesh.isVisible||mesh.visibility<=0||!material||material.alpha===0)continue;
     // Custom translucent triangle shaders require their own composition.
     // Current explicit FE overlays are opaque geometry or LinesMesh.
     const blending=material.needAlphaBlendingForMesh(mesh);
     if(blending&&!(mesh instanceof B.LinesMesh)&&!mesh.metadata?.wingStrokeSource)continue;
     const originalDepth=material.depthFunction,originalWrite=material.disableDepthWrite;
     try{
      material.depthFunction=B.Constants.ALWAYS;material.disableDepthWrite=true;
      scene.resetCachedMaterial();
      for(const subMesh of mesh.subMeshes||[])subMesh.render(blending);
     }finally{material.depthFunction=originalDepth;material.disableDepthWrite=originalWrite;}
    }
   }finally{engine.setDepthFunction(depthFunction);engine.setDepthWrite(depthWrite);engine.setAlphaMode(alpha);scene.resetCachedMaterial();}
  });
  function dispose(){setEnabled(false);restoreInvalidation();for(const[renderer,{original,mark}]of prepasses)if(renderer._markAllMaterialsAsPrePassDirty===mark)renderer._markAllMaterialsAsPrePassDirty=original;prepasses.clear();for(const[renderer,{originalRender,originalDraw,render,draw}]of depthRenderers){if(renderer.render===render)renderer.render=originalRender;if(renderer._renderSubMeshes===draw)renderer._renderSubMeshes=originalDraw;}depthRenderers.clear();scene.onBeforeActiveMeshesEvaluationObservable.remove(before);scene.onAfterRenderObservable.remove(after);}
  return{setEnabled,dispose,supported,get enabled(){return enabled;}};
 }
 return{create,batchMaterials};
});
