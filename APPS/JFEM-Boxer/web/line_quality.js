/* Constant screen-width FE edges. Source LinesMesh geometry remains authoritative
 * for picking, deformation, inspection and export; only its draw is replaced. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingLineQuality=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 const WIDTH=1.35;
 function create({BABYLON:B=globalThis.BABYLON,scene,camera}){
  const engine=scene.getEngine(),caps=engine.getCaps(),records=new Map(),pending=new Set();
  let disposed=false;
  // Retain a defined stroke core with MSAA; smooth the OIT composite last.
  const fxaa=new B.FxaaPostProcess('boxer-line-antialias',1,camera,B.Texture.BILINEAR_SAMPLINGMODE,engine,false,B.Constants.TEXTURETYPE_UNSIGNED_BYTE);
  fxaa.samples=Math.min(4,Math.max(1,caps.maxMSAASamples||1));
  // Preserve edge contrast: Babylon's default subpixel blend is 1.0, which
  // visibly softens dense FE linework. Keep its directional edge smoothing
  // but reduce the flat-area subpixel blend. Vendor shaders remain untouched.
  for(const store of [B.ShaderStore.ShadersStore,B.ShaderStore.ShadersStoreWGSL]){
   if(store?.fxaaPixelShader)store.boxerCrispFxaaPixelShader=store.fxaaPixelShader.replace(/(fxaaQualitySubpix\s*(?::\s*f32)?\s*=\s*)1\.0/,'$1'+'0.35');
  }
  fxaa.updateEffect(null,null,null,undefined,undefined,undefined,'fxaa','boxerCrispFxaa');
  class StrokeMaterial extends B.MaterialPluginBase{
   constructor(material){super(material,'BoxerScreenStroke',200,{});this._enable(true);}
   isCompatible(){return true;}
   getAttributes(attributes){attributes.push('strokeOther','strokeSide');}
   getUniforms(){return{ubo:[{name:'strokeResolution',size:3,type:'vec3'}],vertex:'uniform vec3 strokeResolution;'};}
   bindForSubMesh(buffer){
    const canvas=engine.getRenderingCanvas(),rect=canvas?.getBoundingClientRect?.();
    const width=engine.getRenderWidth(),height=engine.getRenderHeight();
    // CSS-pixel width avoids half-pixel hairlines on high-DPI displays.
    buffer.updateFloat3('strokeResolution',width,height,WIDTH*width/Math.max(1,rect?.width||width));
   }
   getCustomCode(stage,language){
    if(stage!=='vertex')return null;
    if(language===B.ShaderLanguage.WGSL)return{
     CUSTOM_VERTEX_DEFINITIONS:'attribute strokeOther: vec3f;\nattribute strokeSide: f32;',
     CUSTOM_VERTEX_MAIN_END:
      'let strokePoint = scene.viewProjection * finalWorld * vec4f(positionUpdated, 1.0);\n'+
      'let strokeEnd = scene.viewProjection * finalWorld * vec4f(input.strokeOther, 1.0);\n'+
      'let strokeDelta = (strokeEnd.xy / max(0.000001, strokeEnd.w) - strokePoint.xy / max(0.000001, strokePoint.w)) * uniforms.strokeResolution.xy;\n'+
      'let strokeNormal = vec2f(-strokeDelta.y, strokeDelta.x) / max(0.000001, length(strokeDelta));\n'+
      'vertexOutputs.position = vec4f(strokePoint.xy + strokeNormal * input.strokeSide * uniforms.strokeResolution.z / uniforms.strokeResolution.xy * strokePoint.w, strokePoint.zw);'
     };
    return{
     CUSTOM_VERTEX_DEFINITIONS:'attribute vec3 strokeOther;\nattribute float strokeSide;',
     CUSTOM_VERTEX_MAIN_END:
      'vec4 strokePoint = viewProjection * finalWorld * vec4(positionUpdated, 1.0);\n'+
      'vec4 strokeEnd = viewProjection * finalWorld * vec4(strokeOther, 1.0);\n'+
      'vec2 strokeDelta = (strokeEnd.xy / max(0.000001, strokeEnd.w) - strokePoint.xy / max(0.000001, strokePoint.w)) * strokeResolution.xy;\n'+
      'vec2 strokeNormal = vec2(-strokeDelta.y, strokeDelta.x) / max(0.000001, length(strokeDelta));\n'+
      'gl_Position = vec4(strokePoint.xy + strokeNormal * strokeSide * strokeResolution.z / strokeResolution.xy * strokePoint.w, strokePoint.zw);'
     };
   }
  }
  function rebuild(record){
   const source=record.source,points=source.getVerticesData(B.VertexBuffer.PositionKind),indices=source.getIndices();
   if(!points?.length||!indices)return false;
   const count=Math.floor(indices.length/2),topologyChanged=record.count!==count;
   // Animation refills existing typed buffers: no expanded arrays or index
   // lists are allocated per frame while the segment count stays unchanged.
   if(topologyChanged){record.positions=new Float32Array(count*12);record.other=new Float32Array(count*12);record.side=new Float32Array(count*4);record.faces=new Uint32Array(count*6);record.rgba=null;}
   const {positions,other,side,faces}=record;
   const colors=source.useVertexColor?source.getVerticesData(B.VertexBuffer.ColorKind):null;
   const rgba=colors?(record.rgba||(record.rgba=new Float32Array(count*16))):null;
   for(let e=0;e<count;e++){
    const a=indices[2*e],b=indices[2*e+1],v=4*e;
    for(let k=0;k<4;k++){
     const n=k<2?a:b,o=k<2?b:a;
     for(let c=0;c<3;c++){positions[(v+k)*3+c]=points[n*3+c];other[(v+k)*3+c]=points[o*3+c];}
     if(topologyChanged)side[v+k]=k===0||k===3?1:-1;
     if(rgba)for(let c=0;c<4;c++)rgba[(v+k)*4+c]=c===3?colors[n*4+c]:Math.pow(colors[n*4+c],2.2);
    }
    if(topologyChanged)faces.set([v,v+1,v+2,v+2,v+1,v+3],6*e);
   }
   const mesh=record.mesh;
   if(record.count===count){mesh.updateVerticesData(B.VertexBuffer.PositionKind,positions,true);mesh.updateVerticesData('strokeOther',other);if(rgba){if(mesh.isVerticesDataPresent(B.VertexBuffer.ColorKind))mesh.updateVerticesData(B.VertexBuffer.ColorKind,rgba);else mesh.setVerticesData(B.VertexBuffer.ColorKind,rgba,true);}}
   else{mesh.setVerticesData(B.VertexBuffer.PositionKind,positions,true);mesh.setVerticesData('strokeOther',other,true,3);mesh.setVerticesData('strokeSide',side,false,1);mesh.setIndices(faces);if(rgba)mesh.setVerticesData(B.VertexBuffer.ColorKind,rgba,true);record.count=count;}
   if(!rgba&&mesh.isVerticesDataPresent(B.VertexBuffer.ColorKind))mesh.removeVerticesData(B.VertexBuffer.ColorKind);
   mesh.hasVertexAlpha=source.useVertexAlpha&&!!rgba;
   record.hasColors=!!rgba;record.dirty=false;return true;
  }
  function release(source){
   const record=records.get(source);if(!record)return;
   records.delete(source);
   if(source._draw===record.draw)source._draw=record.originalDraw;
   if(source._wingScreenStroke===record.mesh)delete source._wingScreenStroke;
   for(const[name,{original,wrapper}]of record.hooks)if(source[name]===wrapper)source[name]=original;
   source.onDisposeObservable.remove(record.disposeObserver);record.mesh.dispose(false,true);
  }
  function attach(source){
   if(records.has(source)||source.isDisposed()||!source.getTotalVertices())return false;
   const mesh=new B.Mesh(source.name+'-screen-stroke',scene),material=new B.StandardMaterial(mesh.name+'-material',scene);
   mesh.parent=source;mesh.isPickable=false;mesh.doNotSerialize=true;mesh.metadata={wingViewHelper:true,wingStrokeSource:true};
   material.disableLighting=true;material.emissiveColor=B.Color3.White();material.diffuseColor=B.Color3.White();material.specularColor=B.Color3.Black();material.backFaceCulling=false;
   new StrokeMaterial(material);mesh.material=material;
   const record={source,mesh,material,dirty:true,count:-1,hooks:new Map(),originalDraw:source._draw,draw(){return this;}};
   if(!rebuild(record)){mesh.dispose(false,true);return false;}
   // A scene-local hook suppresses only the duplicate native one-pixel raster.
   source._draw=record.draw;source._wingScreenStroke=mesh;
   for(const name of ['setVerticesData','updateVerticesData','updateVerticesDataDirectly','setIndices','updateIndices']){
    const original=source[name];if(typeof original!=='function')continue;
    const wrapper=function(...args){const value=original.apply(this,args);record.dirty=true;return value;};
    record.hooks.set(name,{original,wrapper});source[name]=wrapper;
   }
   record.disposeObserver=source.onDisposeObservable.add(()=>release(source));records.set(source,record);return true;
  }
  const observe=mesh=>{if(mesh instanceof B.LinesMesh)pending.add(mesh);};
  scene.meshes.forEach(observe);
  const newObserver=scene.onNewMeshAddedObservable.add(observe);
  const before=scene.onBeforeActiveMeshesEvaluationObservable.add(()=>{
   // Hidden coordinate/material-axis layers can contain millions of lines;
   // allocate strokes only when that layer is first displayed.
   for(const source of pending){if(source.isDisposed()||source.isVisible&&source.visibility>0&&source.isEnabled()&&attach(source))pending.delete(source);}
   for(const[source,record]of records){
    if(source.isDisposed()){release(source);continue;}
    if(record.dirty&&source.isVisible&&source.visibility>0&&source.isEnabled())rebuild(record);
    const mesh=record.mesh,material=record.material;
    mesh.isVisible=source.isVisible;mesh.visibility=source.visibility;mesh.setEnabled(source.isEnabled()&&record.count>0);mesh.renderingGroupId=source.renderingGroupId;mesh.layerMask=source.layerMask;
    // Native lines emit the selected sRGB color directly. StandardMaterial's
    // output gamma conversion needs linear inputs to preserve that same color.
    if(record.hasColors)material.emissiveColor.set(1,1,1);else source.color.toLinearSpaceToRef(material.emissiveColor);
    material.alpha=source.alpha;
    const original=source.material;
    material.depthFunction=original.depthFunction;material.disableDepthWrite=original.disableDepthWrite;material.zOffset=original.zOffset;material.zOffsetUnits=original.zOffsetUnits;
   }
  });
  const sceneObserver=scene.onDisposeObservable.add(()=>dispose());
  function dispose(){
   if(disposed)return;disposed=true;
   scene.onNewMeshAddedObservable.remove(newObserver);scene.onBeforeActiveMeshesEvaluationObservable.remove(before);scene.onDisposeObservable.remove(sceneObserver);
   for(const source of [...records.keys()])release(source);pending.clear();fxaa.dispose(camera);
  }
  return{fxaa,dispose,get samples(){return fxaa.samples;},get strokes(){return records.size;},width:WIDTH};
 }
 return{create};
});
