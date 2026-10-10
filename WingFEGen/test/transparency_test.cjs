'use strict';
// Portable lifecycle checks; exact rendered colors are covered privately in
// translucency_browser_test.cjs using the actual bundled Babylon engine.
const assert=require('node:assert/strict'),T=require('../web/transparency.js');
class Observable{constructor(){this.items=[];}add(fn){this.items.push(fn);return fn;}remove(fn){this.items=this.items.filter(x=>x!==fn);}notify(){for(const fn of this.items)fn();}}
class LinesMesh{}
const B={Constants:{ALWAYS:519},LinesMesh};
function fixture(supported=true){
 const engine={webGLVersion:supported?2:1,getCaps:()=>({drawBuffersExtension:true,textureFloatRender:true,textureHalfFloatRender:true,blendFloat:true}),depth:515,write:true,alpha:0,
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
console.log('Transparency capability fallback, mode/group lifecycle and exception-safe overlay state passed.');
