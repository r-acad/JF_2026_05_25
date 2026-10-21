'use strict';
// Portable lifecycle checks; renderer_compatibility_browser_test.cjs checks
// visible pixels and GPU resource lifetime using the actual bundled engine.
const assert=require('node:assert/strict'),T=require('../web/transparency.js');
class Observable{constructor(){this.items=[];}add(fn){this.items.push(fn);return fn;}remove(fn){this.items=this.items.filter(x=>x!==fn);}notify(){for(const fn of this.items)fn();}}
class LinesMesh{}
const B={Constants:{ALWAYS:519},LinesMesh};
function fixture(supported=true){
 const engine={webGLVersion:supported?2:1,getCaps:()=>({drawBuffersExtension:true,textureFloatRender:true,textureHalfFloatRender:true,textureFloatLinearFiltering:true,blendFloat:true}),depth:515,write:true,alpha:0,
  getDepthFunction(){return this.depth;},getDepthWrite(){return this.write;},getAlphaMode(){return this.alpha;},setDepthFunction(v){this.depth=v;},setDepthWrite(v){this.write=v;},setAlphaMode(v){this.alpha=v;}};
 const scene={getEngine:()=>engine,depthPeelingRenderer:{passCount:0},useOrderIndependentTransparency:false,meshes:[],onBeforeActiveMeshesEvaluationObservable:new Observable(),onAfterRenderObservable:new Observable(),resetCachedMaterial(){}};
 const mesh=(group=0)=>{const m={renderingGroupId:group,isDisposed:()=>false,isEnabled:()=>true,isVisible:true,visibility:1,material:{alpha:1,depthFunction:0,disableDepthWrite:false,separateCullingPass:true,needAlphaBlendingForMesh:()=>false},subMeshes:[{render(){}}]};scene.meshes.push(m);return m;};
 return{engine,scene,mesh};
}
{
 const f=fixture(false);let warnings=0;const t=T.create({BABYLON:B,scene:f.scene,onUnsupported:()=>warnings++}),mesh=f.mesh(3);
 assert(!t.setEnabled(true));assert(!t.setEnabled(true));f.scene.onBeforeActiveMeshesEvaluationObservable.notify();
 assert.equal(warnings,1);assert.equal(mesh.renderingGroupId,3);assert(!f.scene.useOrderIndependentTransparency);t.dispose();
}
{
 const f=fixture(),a=f.mesh(1),b=f.mesh(3);let through=[];
 const t=T.create({BABYLON:B,scene:f.scene,throughMeshes:()=>through});assert(t.setEnabled(true));f.scene.onBeforeActiveMeshesEvaluationObservable.notify();
 assert.equal(a.renderingGroupId,0);assert.equal(b.renderingGroupId,0);assert.equal(a.material.separateCullingPass,false);
 const added=f.mesh(2);b.renderingGroupId=1;f.scene.onBeforeActiveMeshesEvaluationObservable.notify();
 assert.equal(added.renderingGroupId,0);assert.equal(b.renderingGroupId,0);
 let rendered=0;through=[b];b.subMeshes=[{render(){rendered++;assert.equal(b.material.depthFunction,519);assert(b.material.disableDepthWrite);f.engine.depth=519;f.engine.write=false;}}];
 f.scene.onAfterRenderObservable.notify();assert.equal(rendered,1);assert.equal(b.material.depthFunction,0);assert.equal(b.material.disableDepthWrite,false);assert.equal(f.engine.depth,515);assert(f.engine.write);
 b.isEnabled=()=>false;f.scene.onAfterRenderObservable.notify();assert.equal(rendered,1);b.isEnabled=()=>true;
 b.subMeshes=[{render(){throw Error('Draw failure');}}];assert.throws(()=>f.scene.onAfterRenderObservable.notify(),/Draw failure/);assert.equal(b.material.depthFunction,0);assert.equal(b.material.disableDepthWrite,false);assert.equal(f.engine.depth,515);assert(f.engine.write);
 t.setEnabled(false);assert.equal(a.renderingGroupId,1);assert.equal(b.renderingGroupId,1);assert.equal(added.renderingGroupId,2);assert(a.material.separateCullingPass&&b.material.separateCullingPass);
 t.setEnabled(true);f.scene.onBeforeActiveMeshesEvaluationObservable.notify();t.dispose();assert.equal(a.renderingGroupId,1);assert.equal(f.scene.onAfterRenderObservable.items.length,0);assert.equal(f.scene.onBeforeActiveMeshesEvaluationObservable.items.length,0);
}
{
 const f=fixture(),calls={all:0,prepass:0,cached:0,prepassUpdate:0,fallback:0},context={},oldContext={};
 const a=f.mesh(3),b=f.mesh(0);for(const mesh of [a,b]){
  mesh._markSubMeshesAsDirty=()=>{};mesh.material._materialContext=context;
  mesh.subMeshes=[{getMaterial:()=>mesh.material,_drawWrappers:[{materialContext:context,defines:{markAllAsDirty(){calls.all++;},markAsPrePassDirty(){calls.prepass++;}}},
   {materialContext:oldContext,defines:{markAllAsDirty(){throw Error('Stale material wrapper changed');},markAsPrePassDirty(){throw Error('Stale prepass wrapper changed');}}}]}];
 }
 b.material._blockDirtyMechanism=true;
 f.scene._forceBlockMaterialDirtyMechanism=value=>f.scene.blockMaterialDirtyMechanism=value;
 f.scene.markAllMaterialsAsDirty=()=>calls.fallback++;
 f.scene.resetCachedMaterial=()=>calls.cached++;
 const originalPrepass=()=>calls.fallback++;
 f.scene.prePassRenderer={markAsDirty(){calls.prepassUpdate++;},_markAllMaterialsAsPrePassDirty:originalPrepass};
 const originalGlobal=f.scene.markAllMaterialsAsDirty;
 const engineAPI={...B,AbstractMesh:{prototype:{_markSubMeshesAsDirty(){}}},Material:{AllDirtyFlag:127}};
 const t=T.create({BABYLON:engineAPI,scene:f.scene});
 f.scene.markAllMaterialsAsDirty(127);assert.equal(calls.all,1);assert.equal(calls.fallback,0);
 f.scene.markAllMaterialsAsDirty(32);f.scene.markAllMaterialsAsDirty(127,()=>true);assert.equal(calls.fallback,2);
 let nested=false;
 T.batchMaterials(f.scene,()=>{assert(f.scene.blockMaterialDirtyMechanism);T.batchMaterials(f.scene,()=>{nested=true;});assert.equal(calls.all,1);});
 assert(nested);assert.equal(calls.all,2);assert(!f.scene.blockMaterialDirtyMechanism);
 assert.throws(()=>T.batchMaterials(f.scene,()=>{throw Error('Mode failure');}),/Mode failure/);assert(!f.scene.blockMaterialDirtyMechanism);assert.equal(calls.all,3);
 assert(t.setEnabled(true));f.scene.prePassRenderer._markAllMaterialsAsPrePassDirty();assert.equal(calls.prepass,1);
 f.scene.blockMaterialDirtyMechanism=true;f.scene.markAllMaterialsAsDirty(127);f.scene.prePassRenderer._markAllMaterialsAsPrePassDirty();const before=calls.all;
 T.batchMaterials(f.scene,()=>{});assert(f.scene.blockMaterialDirtyMechanism);assert.equal(calls.all,before);assert.equal(calls.prepass,1);
 f.scene.blockMaterialDirtyMechanism=false;t.dispose();assert.equal(f.scene.markAllMaterialsAsDirty,originalGlobal);assert.equal(f.scene.prePassRenderer._markAllMaterialsAsPrePassDirty,originalPrepass);
}
{
 for(const caps of [{blendFloat:false,textureFloatLinearFiltering:true},{blendFloat:true,textureFloatLinearFiltering:false}]){
  const f=fixture();f.engine.isWebGPU=true;f.engine.getCaps=()=>caps;const t=T.create({BABYLON:B,scene:f.scene});assert.equal(t.supported,false);assert.equal(t.setEnabled(true),false);t.dispose();
 }
 const f=fixture(),calls={draws:0,flushes:0},equations=[];f.engine.isWebGPU=true;f.engine.getCaps=()=>({blendFloat:true,textureFloatLinearFiltering:true});f.engine._alphaEquation=[3];
 const equation=function(value,target=0){equations.push({value,cached:this._alphaEquation[target]});this._alphaEquation[target]=value;};f.engine.setAlphaEquation=equation;
 f.engine.flushFramebuffer=()=>{assert.equal(calls.draws%3,1);calls.flushes++;};
 const draw=function(){calls.draws++;};const render=function(fail=false){for(let i=0;i<3;i++){f.engine.setAlphaEquation(3);this._renderSubMeshes();if(fail)throw Error('Peel failure');}};
 f.scene.depthPeelingRenderer={passCount:0,render,_renderSubMeshes:draw};const t=T.create({BABYLON:B,scene:f.scene});t.setEnabled(true);
 f.scene.depthPeelingRenderer.render();f.scene.depthPeelingRenderer.render();assert.equal(calls.draws,6);assert.equal(calls.flushes,2);assert(equations.every(e=>e.cached===-1));assert.equal(f.engine.setAlphaEquation,equation);
 assert.throws(()=>f.scene.depthPeelingRenderer.render(true),/Peel failure/);assert.equal(f.engine.setAlphaEquation,equation);t.dispose();assert.equal(f.scene.depthPeelingRenderer.render,render);assert.equal(f.scene.depthPeelingRenderer._renderSubMeshes,draw);
}
console.log('Transparency capabilities, full-float WebGPU one-submit lifecycle and equation restoration, grouping, linear invalidation and overlay state passed.');
