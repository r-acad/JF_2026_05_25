/* Smooth the final FE image, including the depth-peeling compositor. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingLineQuality=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 function create({BABYLON:B=globalThis.BABYLON,scene,camera}){
  const engine=scene.getEngine(),caps=engine.getCaps();
  let disposed=false;
  // Keep the existing canvas resolution. Native LinesMesh is one physical
  // pixel wide: supersampling makes it thinner and fainter on high-DPI screens,
  // while multiplying the memory occupied by depth-peeling render targets.
  // A dedicated FXAA pass leaves exposure, material colors and lighting alone.
  // Canvas MSAA is bypassed by camera postprocessing; preserve four samples on
  // its scene input where supported. OIT's min/max depth targets stay untouched.
  const fxaa=new B.FxaaPostProcess('boxer-line-antialias',1,camera,B.Texture.BILINEAR_SAMPLINGMODE,engine,false,B.Constants.TEXTURETYPE_UNSIGNED_BYTE);
  fxaa.samples=Math.min(4,Math.max(1,caps.maxMSAASamples||1));
  const sceneObserver=scene.onDisposeObservable.add(()=>dispose());
  function dispose(){
   if(disposed)return;disposed=true;
   scene.onDisposeObservable.remove(sceneObserver);fxaa.dispose(camera);
  }
  return {fxaa,dispose,get samples(){return fxaa.samples;}};
 }
 return {create};
});
