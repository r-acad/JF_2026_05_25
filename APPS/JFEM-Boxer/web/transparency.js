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
  // The bundled WebGPU depth peeler's full-float path can lose transparent
  // fragments between its depth and colour passes. Use its existing paired
  // half-float texture / depth-rounding path explicitly, without changing the
  // GPU's actual texture-filtering capabilities or other scene textures.
  // Half-float depth quantizes nearby fragments just as Babylon's fallback
  // for GPUs without float-linear filtering does; the ten-layer limit remains.
  const halfDepth=!!(engine.isWebGPU&&B.MaterialPluginBase&&B.ThinTexture),depthRenderers=new Map(),depthPlugins=new Set();
  const previousHalfDepth=scene._boxerHalfFloatOITDepth;
  let halfMaterialObserver=null,halfFrameObserver=null;
  if(halfDepth){
   scene._boxerHalfFloatOITDepth=true;
   class HalfDepthPlugin extends B.MaterialPluginBase{
    constructor(material){super(material,'BoxerHalfFloatOITDepth',200,{BOXER_OIT_HALF_DEPTH:false},true,true);this.doNotSerialize=true;}
    getClassName(){return 'BoxerHalfFloatOITDepth';}
    isCompatible(){return true;}
    prepareDefines(defines){const next=!!this._material.getScene()._boxerHalfFloatOITDepth;if(defines.BOXER_OIT_HALF_DEPTH!==next){defines.BOXER_OIT_HALF_DEPTH=next;defines.markAsUnprocessed();}}
    getCustomCode(kind){return kind==='fragment'?{CUSTOM_FRAGMENT_DEFINITIONS:'#if defined(BOXER_OIT_HALF_DEPTH) && defined(ORDER_INDEPENDENT_TRANSPARENCY) && !defined(ORDER_INDEPENDENT_TRANSPARENCY_16BITS)\n#define ORDER_INDEPENDENT_TRANSPARENCY_16BITS\n#endif'}:null;}
   }
   const pending=new Set(),installed=new WeakMap();
   function installDepthMaterials(){for(const material of pending){
    if(!installed.has(material)&&(material instanceof B.StandardMaterial||material instanceof B.PBRBaseMaterial)){
     const plugin=material.pluginManager?.getPlugin('BoxerHalfFloatOITDepth')||new HalfDepthPlugin(material);installed.set(material,plugin);depthPlugins.add(plugin);
    }
   }pending.clear();}
   function queueMaterial(material){pending.add(material);material.onDisposeObservable.addOnce(()=>{pending.delete(material);depthPlugins.delete(installed.get(material));});}
   for(const material of scene.materials||[])queueMaterial(material);
   halfMaterialObserver=scene.onNewMaterialAddedObservable.add(queueMaterial);
   halfFrameObserver=scene.onBeforeRenderObservable.add(installDepthMaterials);installDepthMaterials();
  }
  function prepareDepthTextures(){
   const renderer=scene.depthPeelingRenderer;
   if(!halfDepth||depthRenderers.has(renderer))return;
   const original=renderer._createTextures;
   const originalType=renderer._depthMrts[0].textures[0].getInternalTexture().type;
   function replaceDepthTextures(type=B.Constants.TEXTURETYPE_HALF_FLOAT){
    for(let i=0;i<2;i++){
     const target=renderer._depthMrts[i],old=target?.textures[0]?.getInternalTexture();
     if(!old||old.type===type)continue;
     const texture=engine._createInternalTexture(target.getSize(),{format:B.Constants.TEXTUREFORMAT_RG,type,samplingMode:B.Constants.TEXTURE_NEAREST_SAMPLINGMODE,label:'Boxer OIT depth'},false);
     // ThinTexture wraps the same reference; release the old allocation once.
     target.setInternalTexture(texture,0,false);renderer._thinTextures[3*i].dispose();renderer._thinTextures[3*i]=new B.ThinTexture(texture);
    }
   }
   const create=function(...args){const result=original.apply(this,args);replaceDepthTextures();return result;};
   renderer._createTextures=create;depthRenderers.set(renderer,{original,create,restore:()=>replaceDepthTextures(originalType)});replaceDepthTextures();
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
   batchMaterials(scene,()=>{
    enabled=next;scene.useOrderIndependentTransparency=next;
    // Five dual passes retain up to ten depth layers. This bounds the cost for
    // large imported decks; deeper interiors may be omitted at grazing views.
    if(next){scene.depthPeelingRenderer.passCount=5;prepareDepthTextures();preparePrePass();}else restoreGroups();
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
  function dispose(){setEnabled(false);restoreInvalidation();for(const[renderer,{original,mark}]of prepasses)if(renderer._markAllMaterialsAsPrePassDirty===mark)renderer._markAllMaterialsAsPrePassDirty=original;prepasses.clear();for(const[renderer,{original,create,restore}]of depthRenderers)if(renderer._createTextures===create){renderer._createTextures=original;restore();}depthRenderers.clear();if(halfMaterialObserver)scene.onNewMaterialAddedObservable.remove(halfMaterialObserver);if(halfFrameObserver)scene.onBeforeRenderObservable.remove(halfFrameObserver);if(halfDepth){if(previousHalfDepth===undefined)delete scene._boxerHalfFloatOITDepth;else scene._boxerHalfFloatOITDepth=previousHalfDepth;}for(const plugin of depthPlugins)plugin.markAllDefinesAsDirty();depthPlugins.clear();scene.onBeforeActiveMeshesEvaluationObservable.remove(before);scene.onAfterRenderObservable.remove(after);}
  return{setEnabled,dispose,supported,get enabled(){return enabled;}};
 }
 return{create,batchMaterials};
});
