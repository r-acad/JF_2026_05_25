'use strict';
// Real Babylon NullEngine overlays plus the actual app preview coordinator.
// No Julia process, solver job, browser GPU or user model is needed.
// node fe_edit_render_performance_test.cjs [PRIVATE_OUTPUT]
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),{performance}=require('node:perf_hooks');
const B=require('../web/vendor/babylon.js');require('../web/fe_edit_viewport.js');
(async()=>{
 const checks=[],engine=new B.NullEngine({renderWidth:800,renderHeight:600}),scene=new B.Scene(engine);let nodeReads=0;
 new B.FreeCamera('test-camera',new B.Vector3(0,0,-5),scene);
 const state={baseline:new Float32Array([0,0,0,1,0,0,1,1,0,0,1,0,2,0,0,3,0,0,3,1,0,2,1,0]),elements:new Map([[1,{nodes:[0,1,2,3],group:{kind:'quad'}}],[2,{nodes:[4,5,6,7],group:{kind:'quad'}}]]),diag:4};
 Object.defineProperty(state,'nodeIds',{get(){nodeReads++;return new Int32Array([1,2,3,4,5,6,7,8]);}});
 const display=global.WingFEEditViewport.create({BABYLON:B,scene,read:()=>state}),parts=[{id:'left',element_ids:[1]},{id:'right',element_ids:[2]}],plane={point:[0,0,0],normal:[1,0,0],side_length:4,tolerance:1e-7};
 const selected={plane,show_plane:true,show_parts:true,parts,selected_element_ids:[2]};
 const started=performance.now();display.show(selected);const part=scene.getMeshByName('fe-part-fill-left'),selection=scene.getMeshByName('fe-selected-part-fill'),glow=scene.effectLayers.find(layer=>layer.name==='fe-part-selection-glow');
 assert(part&&selection&&glow);assert.equal(selection.isPickable,false);assert(selection.material.emissiveColor.r>selection.material.emissiveColor.g&&selection.material.emissiveColor.g>selection.material.emissiveColor.b);assert(display.stats().glowingMeshes>0);if(typeof glow.hasMesh==='function'){assert(glow.hasMesh(selection));assert(!glow.hasMesh(part));}
 const initialCount=scene.meshes.length;
 for(let i=0;i<100;i++)display.show({...selected,selected_element_ids:[2]});
 assert.equal(display.stats().partBuilds,1);assert.equal(display.stats().selectionBuilds,1);assert.equal(display.stats().identicalReuses,100);assert.equal(scene.meshes.length,initialCount);
 for(let i=1;i<=50;i++)display.show({...selected,plane:{...plane,point:[i/100,0,0]},selected_element_ids:[2]});
 assert.equal(display.stats().partBuilds,1);assert.equal(display.stats().selectionBuilds,1);assert.equal(scene.getMeshByName('fe-part-fill-left').uniqueId,part.uniqueId);assert.equal(scene.getMeshByName('fe-selected-part-fill').uniqueId,selection.uniqueId);assert.equal(nodeReads,0,'Ordinary previews must not build a global node lookup');
 checks.push('Amber glow includes only the selected overlay; 100 identical updates and 50 plane updates reuse connected-part/selection meshes without building a node lookup or growing mesh count');
 state.baseline=new Float32Array(state.baseline);display.show(selected);assert(part.isDisposed()&&selection.isDisposed());assert.equal(display.stats().partBuilds,2);assert.equal(display.stats().selectionBuilds,2);assert.equal(scene.effectLayers.filter(layer=>layer.name==='fe-part-selection-glow').length,1);
 const renderStats={...display.stats(),elapsedMs:performance.now()-started,nodeLookupReads:nodeReads};display.show({...selected,ambiguous_node_ids:[1,2]});const ambiguous=scene.getMeshByName('fe-ambiguous-node-1');assert(ambiguous&&ambiguous.renderingGroupId===3&&ambiguous.material.depthFunction===B.Constants.ALWAYS);assert(!ambiguous.isPickable);display.clear();assert.equal(scene.meshes.length,0);assert.equal(scene.effectLayers.length,0);scene.dispose();engine.dispose();checks.push('Replacing the model invalidates cached overlays; ambiguous review nodes receive unpickable magenta markers, and clear leaves no meshes or effect layers');
 const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8'),start=source.indexOf('function showFEEditPreview(spec)'),end=source.indexOf('function pickFEEditPart(',start);assert(start>=0&&end>start);
 const timers=[],fetches=[],draws=[],coordinator={feEditIdentity:{session_id:'session',revision:1},meshIdentity:'mesh-1',feEditViewport:{show:spec=>draws.push(spec)}};
 const sandbox={state:coordinator,AbortController,JSON,Array,log:()=>{},setTimeout:callback=>{timers.push({callback,cancelled:false});return timers.length-1;},clearTimeout:id=>{if(timers[id])timers[id].cancelled=true;},fetch:(_url,options)=>new Promise(resolve=>fetches.push({body:JSON.parse(options.body),resolve}))};vm.createContext(sandbox);vm.runInContext(source.slice(start,end),sandbox);
 const show=spec=>sandbox.showFEEditPreview(spec),base={plane,selection:{kind:'positive'},parts,show_parts:true};
 const runLatest=()=>{const timer=[...timers].reverse().find(timer=>!timer.cancelled&&!timer.started);assert(timer);timer.started=true;return timer.callback();};
 for(let i=0;i<20;i++)show({...base,selected_element_ids:[1]});const first=runLatest();assert.equal(fetches.length,1);show({...base,selected_element_ids:[2]});fetches[0].resolve({ok:true,json:async()=>({cut_segments:[[[0,0,0],[0,1,0]]]})});await first;assert.deepEqual(coordinator.feEditPreviewSpec.selected_element_ids,[2]);
 for(let i=0;i<20;i++)show({...base,selected_element_ids:[i%2+1]});assert.equal(fetches.length,1);assert(coordinator.feEditPreviewMetrics.cacheHits>=20);
 for(let i=0;i<10;i++)show({...base,plane:{...plane,point:[i+1,0,0]}});const old=runLatest();assert.equal(fetches.length,2);coordinator.feEditIdentity={session_id:'session',revision:2};coordinator.meshIdentity='mesh-2';show({...base,plane:{...plane,point:[20,0,0]},selected_element_ids:[2]});const latest=runLatest();assert.equal(fetches.length,3);const finalCuts=[[[20,0,0],[20,1,0]]];fetches[2].resolve({ok:true,json:async()=>({cut_segments:finalCuts})});await latest;fetches[1].resolve({ok:true,json:async()=>({cut_segments:[[[999,0,0],[999,1,0]]]})});await old;assert.deepEqual(coordinator.feEditPreviewSpec.cut_segments,finalCuts);
 show({...base,plane:{...plane,point:[30,0,0]}});show({...base,plane:{...plane,point:[30,0,0]},cut_segments:[]});assert(!timers.some(timer=>!timer.cancelled&&!timer.started));assert.equal(fetches.length,3);show({clear:true});assert.equal(coordinator.feEditPreviewCutData,null);
 checks.push('The actual app coordinator coalesces pending requests, reuses cached contours across part selection, preserves the newest selection, rejects stale model replies and cancels redundant reads when contours are already supplied');
 const report={passed:true,checks,renderStats,previewMetrics:coordinator.feEditPreviewMetrics,actualPreviewRequests:fetches.length};if(process.argv[2]){fs.mkdirSync(process.argv[2],{recursive:true});fs.writeFileSync(path.join(process.argv[2],'fe-edit-render-performance.json'),JSON.stringify(report,null,2));}console.log(JSON.stringify(report));
})().catch(error=>{console.error(error);process.exitCode=1;});
