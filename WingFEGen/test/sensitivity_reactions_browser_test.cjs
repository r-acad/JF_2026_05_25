'use strict';
// Actual retained reactions exported by sensitivity_baseline_reactions_test.jl.
// node this-file <evidence-dir> [playwright-module] [fixture-dir]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]||'playwright'),web=path.resolve(__dirname,'../web'),out=path.resolve(process.argv[2]);
const fixture=process.argv[4]?path.resolve(process.argv[4]):out;fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 let page=await browser.newPage({viewport:{width:1500,height:1050}}),nonlinearEvidence=null;const checks=[],errors=[];
 try{
  const loadApp=async()=>{
  page.on('pageerror',error=>errors.push(error.stack));
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43962/**',route=>{const pathname=new URL(route.request().url()).pathname;return pathname==='/index.html'?route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')}):route.fulfill({path:path.join(web,pathname)});});
  await page.goto('http://127.0.0.1:43962/index.html');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:app.slice(0,app.indexOf('(async function start()'))});
  await page.evaluate(()=>{window.reactionControls=()=>Object.fromEntries(['show-support-forces','results-show-support-forces','show-support-force-values','results-show-support-force-values'].map(id=>{const input=document.getElementById(id);return[id,{checked:input.checked,disabled:input.disabled,hidden:input.closest('label').hidden}];}));});
  };await loadApp();
  const initial=await page.evaluate(async({model,ordinary,baseline,schema})=>{
   initScene();state.engine.stopRenderLoop();state.schema=schema.schema;
   state.data=MessagePack.decode(Uint8Array.from(model));state.values=state.data.model_params;
   const payload=MessagePack.decode(Uint8Array.from(ordinary));
   state.importedDeck={...state.data.imported_deck,source:{...state.data.model_source,analysis:payload.imported_analysis}};
   state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;
   buildForm(state.schema,state.values);buildModel(state.data);state.modelDirty=false;state.modelSignature=formSignature();state.jobSignature=state.modelSignature;state.activeCase=17;
   window.requests=[];window.fetch=async url=>{requests.push(String(url));return{ok:true,arrayBuffer:async()=>Uint8Array.from(String(url).includes('/sensitivity/baseline')?baseline:ordinary).buffer};};
   window.emptyControls=reactionControls();window.emptyNote=document.getElementById('results-support-force-note').textContent;
   await loadJfemResults();setBusy(false);document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;
   activateWorkspaceTab('results');document.getElementById('animate').checked=false;
   window.reactionState=()=>{const layer=state.layers.get('SUPPORT_FORCES');return{case:state.activeCase,mode:state.activeMode,variant:state.results.variantId,disabled:document.getElementById('show-support-forces').disabled,scaleDisabled:document.getElementById('support-force-scale').disabled,visible:!!layer?.visible,glyphs:(layer?.meshes||[]).reduce((n,m)=>n+m.metadata.glyphs.length,0),forces:Array.from(state.results.reactions?.forces||[]),note:document.getElementById('support-force-note').textContent};};
   return reactionState();
  },{model:[...fs.readFileSync(path.join(fixture,'model.msgpack'))],ordinary:[...fs.readFileSync(path.join(fixture,'ordinary_results.msgpack'))],baseline:[...fs.readFileSync(path.join(fixture,'baseline_results.msgpack'))],schema:JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'))});
  assert.equal(initial.disabled,false);assert(initial.visible&&initial.glyphs>0&&initial.forces.length>0);
  const empty=await page.evaluate(()=>({controls:emptyControls,note:emptyNote}));assert(empty.controls['show-support-forces'].disabled&&empty.controls['results-show-support-forces'].disabled);assert.match(empty.note,/No constraint reactions/);
  assert(await page.locator('#results-show-support-forces').isVisible());
  await page.locator('#results-show-support-forces').uncheck();
  assert.deepEqual(await page.evaluate(()=>({tab:workspaceUI.activeTab,visible:reactionState().visible,canonical:document.getElementById('show-support-forces').checked})),{tab:'results',visible:false,canonical:false});
  assert(!(await page.locator('#results-show-support-force-values').isVisible()));
  await page.locator('#results-show-support-forces').check();await page.locator('#results-show-support-force-values').check();
  assert(await page.evaluate(()=>document.getElementById('show-support-force-values').checked));
  const displaySaved=await page.evaluate(()=>{setLayerVisible('SUPPORT_FORCES',false);const saved=WingWorkspace.captureView(document,state,workspaceUI);setLayerVisible('SUPPORT_FORCES',true);document.getElementById('show-support-force-values').checked=false;restoreWorkspaceView(saved);return{controls:reactionControls(),visible:state.layers.get('SUPPORT_FORCES').visible,tab:workspaceUI.activeTab};});
  for(const id of ['show-support-forces','results-show-support-forces'])assert.equal(displaySaved.controls[id].checked,false);
  for(const id of ['show-support-force-values','results-show-support-force-values'])assert(displaySaved.controls[id].checked&&displaySaved.controls[id].hidden);
  assert(!displaySaved.visible&&displaySaved.tab==='results');await page.locator('#results-show-support-forces').check();
  await page.evaluate(async()=>{state.engine.resize();await state.scene.whenReadyAsync();state.scene.render();await new Promise(requestAnimationFrame);state.scene.render();state.annotations.render(true);});
  await page.screenshot({path:path.join(out,'fe-results-reaction-controls.png')});
  checks.push('FE Results directly toggles vectors without navigation; labels are independent, hidden with vectors, synchronized and restored from existing Study controls');
  await page.evaluate(()=>activateWorkspaceTab('displayloads'));
  assert.equal(await page.locator('#layer-SUPPORT_FORCES').count(),0);assert(await page.locator('#support-force-scale').isVisible());
  assert(await page.locator('#show-support-forces').isVisible());await page.locator('#show-support-force-values').uncheck();assert(!(await page.evaluate(()=>document.getElementById('results-show-support-force-values').checked)));
  await page.locator('#show-support-forces').uncheck();assert.equal(await page.evaluate(()=>reactionState().visible),false);
  assert(!(await page.evaluate(()=>document.getElementById('results-show-support-forces').checked)));assert(!(await page.locator('#show-support-force-values').isVisible()));
  await page.locator('#show-support-forces').check();assert.equal(await page.evaluate(()=>reactionState().visible),true);
  const independent=await page.evaluate(()=>{setModelEntitiesVisible(state.layerGroupControls.get('loads')?.names||[],false);return reactionState().visible;});assert(independent);
  checks.push('Original static subcase displays its actual recovered forces and moments');
  const loaded=await page.evaluate(async()=>{await showSensitivityBaseline({}, {run_id:'sensitivity_retained_105'});return{...reactionState(),variants:[...currentResultVariants().keys()]};});
  assert.equal(loaded.variant,'sensitivity_sensitivity_retained_105_sol105');assert.equal(loaded.mode,0);assert(loaded.disabled);
  assert(loaded.variants.includes('sol101'));assert(loaded.variants.includes('sensitivity_sensitivity_retained_105_sol101'));
  assert.match(loaded.note,/arbitrary normalization/);
  const modeControls=await page.evaluate(()=>reactionControls());assert(modeControls['results-show-support-forces'].disabled&&modeControls['results-show-support-force-values'].hidden);
  checks.push('Loading a sensitivity baseline adds separate preload and buckling variants without replacing ordinary results; eigenmodes never display physical reactions');
  const physical=await page.evaluate(()=>{selectResultAnalysis('sensitivity_sensitivity_retained_105_sol101');return reactionState();});
  assert.equal(physical.mode,-1);assert.equal(physical.disabled,false);assert.equal(physical.scaleDisabled,false);assert(physical.visible&&physical.glyphs>0);assert.deepEqual(physical.forces,initial.forces);
  assert(!(await page.evaluate(()=>document.getElementById('results-show-support-forces').disabled)));
  checks.push('Sensitivity SOL101 preload exposes the unchanged retained reactions with its own persistent variant ID');
  const pose=await page.evaluate(()=>{
   state.realScale=true;document.getElementById('deform-scale').value='2';applyDeformation();
   let error=0;for(const entry of state.deformable.filter(row=>row.mesh.metadata?.glyphs&&row.mesh.name.startsWith('SUPPORT_'))){const buffer=entry.mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind);for(let i=0;i<entry.map.length;i++)for(let j=0;j<3;j++)error=Math.max(error,Math.abs(buffer[3*i+j]-currentPositions()[3*entry.map[i]+j]-entry.offsets[3*i+j]));}
   document.getElementById('support-force-scale').value='2';document.getElementById('support-force-scale').dispatchEvent(new Event('input'));
   const after=reactionState();return{error,after};
  });assert(pose.error<1e-6);assert.deepEqual(pose.after.forces,initial.forces);
  await page.evaluate(()=>{const control=document.getElementById('show-support-forces');control.checked=false;control.dispatchEvent(new Event('change'));});
  assert.equal(await page.evaluate(()=>reactionState().visible),false);
  await page.evaluate(()=>{const control=document.getElementById('show-support-forces');control.checked=true;control.dispatchEvent(new Event('change'));});
  assert.equal(await page.evaluate(()=>reactionState().visible),true);
  checks.push('Reaction arrows follow displayed node positions; glyph scaling and visibility controls leave physical reaction values unchanged');
  const shape=await page.evaluate(()=>{selectResultAnalysis('sensitivity_sensitivity_retained_105_sol105');selectMode(-1);return reactionState();});
  assert.equal(shape.disabled,false);assert.deepEqual(shape.forces,initial.forces);
  await page.evaluate(()=>activateWorkspaceTab('displayloads'));assert(await page.locator('#show-support-forces').isVisible());
  // Studies persist the analysis variant, not an individual eigenmode/static-shape row.
  const restored=await page.evaluate(()=>{selectResultAnalysis('sensitivity_sensitivity_retained_105_sol101');const saved=WingWorkspace.captureView(document,state,workspaceUI);restoreWorkspaceView(saved);return{tab:workspaceUI.activeTab,...reactionState()};});
  assert.equal(restored.tab,'displayloads');assert(restored.visible&&!restored.disabled);assert.deepEqual(restored.forces,initial.forces);
  await page.evaluate(()=>{selectResultAnalysis('sensitivity_sensitivity_retained_105_sol105');selectMode(0);});assert.equal(await page.evaluate(()=>reactionState().disabled),true);
  checks.push('The buckling static-shape row displays preload reactions, while selecting a normalized eigenmode hides them');
  const unavailable=await page.evaluate(()=>{selectResultAnalysis('sensitivity_sensitivity_retained_105_sol101');const result=state.results;result.reactions=null;result.reactionNote='SPCFORCES was suppressed for this static subcase.';rebuildSupportForces();return reactionState();});
  assert(unavailable.disabled&&unavailable.scaleDisabled);assert.match(unavailable.note,/SPCFORCES was suppressed/);
  const missing=await page.evaluate(()=>({controls:reactionControls(),note:document.getElementById('results-support-force-note').textContent}));assert(missing.controls['results-show-support-forces'].disabled&&missing.controls['results-show-support-force-values'].hidden);assert.match(missing.note,/SPCFORCES was suppressed/);
  checks.push('Missing or suppressed reaction data disables all reaction controls and explains why');
  if(fs.existsSync(path.join(fixture,'nonlinear_results.msgpack'))){
   const previousRequests=await page.evaluate(()=>requests);await page.close();page=await browser.newPage({viewport:{width:1500,height:1050}});await loadApp();await page.evaluate(previous=>{window.requests=previous;},previousRequests);
   const nonlinear=await page.evaluate(async({model,results,schema})=>{
    initScene();state.engine.stopRenderLoop();state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;
    state.importedDeck=null;state.resultCases=null;state.resultVariantPreference='';state.results=null;state.schema=schema.schema;
    state.data=MessagePack.decode(Uint8Array.from(model));state.values=state.data.model_params;
    buildForm(state.schema,state.values);buildModel(state.data);state.modelDirty=false;state.modelSignature=formSignature();state.jobSignature=state.modelSignature;state.activeCase=1;
    const previous=window.fetch;window.fetch=async url=>{requests.push(String(url));return{ok:true,arrayBuffer:async()=>Uint8Array.from(results).buffer};};
    try{await loadJfemResults();}finally{window.fetch=previous;}
    setBusy(false);document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;activateWorkspaceTab('results');
    window.reactionState=()=>{const layer=state.layers.get('SUPPORT_FORCES');return{case:state.activeCase,mode:state.activeMode,variant:state.results.variantId,disabled:document.getElementById('show-support-forces').disabled,scaleDisabled:document.getElementById('support-force-scale').disabled,visible:!!layer?.visible,glyphs:(layer?.meshes||[]).reduce((n,m)=>n+m.metadata.glyphs.length,0),forces:Array.from(state.results.reactions?.forces||[]),note:document.getElementById('support-force-note').textContent};};
    document.getElementById('animate').checked=false;state.realScale=true;applyDeformation();
    document.getElementById('show-support-force-values').checked=true;document.getElementById('show-support-force-values').dispatchEvent(new Event('change'));state.scene.render();
    const before=Array.from(state.results.reactions.forces),reaction=reactionState();
    let error=0;for(const entry of state.deformable.filter(row=>row.mesh.metadata?.glyphs&&row.mesh.name.startsWith('SUPPORT_'))){const buffer=entry.mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind);for(let i=0;i<entry.map.length;i++)for(let j=0;j<3;j++)error=Math.max(error,Math.abs(buffer[3*i+j]-currentPositions()[3*entry.map[i]+j]-entry.offsets[3*i+j]));}
    const node=state.results.reactions.nodes[0];showNode(node);
    await state.scene.whenReadyAsync();state.scene.render();await new Promise(requestAnimationFrame);state.scene.render();
    state.annotations.render(true);
    return{...reaction,error,visibleShells:state.shellMeshes.filter(mesh=>mesh.isEnabled()&&mesh.isVisible).length,converged:state.results.convergence?.full_load,labels:document.getElementById('show-support-force-values').checked,labelCandidates:WingAnnotations.supportValueCandidates(state).length,shownLabels:state.annotations.stats.supportValuesShown||[],inspection:document.getElementById('pick-content').textContent,moved:state.deformed.some((value,i)=>Math.abs(value-state.baseline[i])>1e-8),unchanged:before.every((value,i)=>value===state.results.reactions.forces[i])};
   },{model:[...fs.readFileSync(path.join(fixture,'nonlinear_model.msgpack'))],results:[...fs.readFileSync(path.join(fixture,'nonlinear_results.msgpack'))],schema:JSON.parse(fs.readFileSync(path.join(fixture,'nonlinear_schema.json'),'utf8'))});
   assert(nonlinear.converged&&nonlinear.visible&&!nonlinear.disabled&&nonlinear.glyphs>0&&nonlinear.labels&&nonlinear.labelCandidates>0&&nonlinear.shownLabels.length>0&&nonlinear.moved&&nonlinear.unchanged&&nonlinear.visibleShells>0);assert(nonlinear.error<1e-6);assert.match(nonlinear.inspection,/Constraint force/);assert.match(nonlinear.inspection,/Constraint moment/);nonlinearEvidence=nonlinear;
   await page.locator('#results-show-support-forces').uncheck();assert.equal(await page.evaluate(()=>reactionState().visible),false);assert(!(await page.locator('#results-show-support-force-values').isVisible()));await page.locator('#results-show-support-forces').check();assert(await page.locator('#results-show-support-force-values').isChecked());
   checks.push('Actual full-load SOL106 baseline displays retained reaction arrows and labels on the deformed model and signed force/moment inspection values');
   await page.evaluate(()=>activateWorkspaceTab('displayloads'));assert(await page.locator('#show-support-forces').isVisible());assert(!(await page.locator('#support-force-scale').isDisabled()));
  }
  const requests=await page.evaluate(()=>window.requests);
  assert.deepEqual(errors,[]);assert.equal(requests.filter(url=>url.includes('/sensitivity/baseline')).length,1);assert.equal(requests.filter(url=>url.includes('/jfem_results')).length,fs.existsSync(path.join(fixture,'nonlinear_results.msgpack'))?2:1);assert(!requests.some(url=>/solve|generate|sensitivity\/run/.test(url)));
  await page.locator('#load-constraint-reactions').scrollIntoViewIfNeeded();await page.screenshot({path:path.join(out,'reaction-controls.png')});
  fs.writeFileSync(path.join(out,'browser-summary.json'),JSON.stringify({passed:true,checks,errors,initial,empty,displaySaved,loaded,physical,pose,restored,missing,requests,nonlinear:nonlinearEvidence},null,2));console.log('Reaction browser checks passed: '+checks.length+' groups');
 }catch(error){fs.writeFileSync(path.join(out,'browser-failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'browser-failure.png')}).catch(()=>{});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
