'use strict';
// node display_organization_browser_test.cjs <generated-fixture-dir> <evidence-dir> [playwright-module]
// Fixture: schema.json + payload.msgpack (gaps_ names also accepted).
// Uses real generated meshes, plus explicit synthetic VLM, reaction and imported-connection probes.
// CHROME_PATH optionally selects Chrome. No model generation or solver requests.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
if(!process.argv[2]||!process.argv[3])throw Error('Usage: node display_organization_browser_test.cjs <generated-fixture-dir> <evidence-dir> [playwright-module]');
const fixture=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]),web=path.resolve(__dirname,'../web'),{chromium}=require(process.argv[4]||'playwright');
const fixtureFile=name=>path.join(fixture,fs.existsSync(path.join(fixture,name))?name:'gaps_'+name);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],requests=[];
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1520,height:1050}});page.on('pageerror',e=>errors.push(e.stack));
 try{
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43961/**',route=>{const url=new URL(route.request().url());if(url.pathname.startsWith('/api/')){requests.push(url.pathname);return route.fulfill({status:404,json:{error:'Display-only fixture'}});}return url.pathname==='/'?route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')}):route.fulfill({path:path.join(web,url.pathname)});});
  await page.goto('http://127.0.0.1:43961/');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:app.slice(0,app.indexOf('(async function start()'))});
  await page.evaluate(async({schema,bytes})=>{
   initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.defaults=schema.defaults;state.data=MessagePack.decode(Uint8Array.from(bytes));state.values=state.data.model_params;
   const binary=a=>new Uint8Array(a.buffer),first=state.data.load_cases[0];
   first.loads.vlm={count:1,xyz:binary(Float32Array.of(0,0,0,1,0,0,1,1,0,0,1,0)),conn:binary(Int32Array.of(0,1,2,3)),pressure:binary(Float32Array.of(50)),cp:binary(Float32Array.of(.5)),area:binary(Float32Array.of(1))};
   const second=structuredClone(first);second.id=2;second.label='Prescribed fixture';delete second.loads.vlm;state.data.load_cases=[first,second];
   state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;buildForm(state.schema,state.values);buildModel(state.data);state.modelSignature=formSignature();setModelDirty(false);setBusy(false);
   document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;
   window.frame=async()=>{state.engine.resize();await state.scene.whenReadyAsync();state.scene.render();await new Promise(requestAnimationFrame);};
   window.unchanged={signature:formSignature(),baseline:[...state.baseline],mesh:resultMeshIdentity(state.data)};
   window.reactions=analysis=>{const node=asI32(state.data.spc.nodes)[0];state.activeMode=-1;state.results={matches:true,available:true,analysis,static:{disp:new Float32Array(state.baseline.length),maxDisp:0},contours:[],modes:[],reactions:{nodes:Int32Array.of(node),forces:Float32Array.of(12,-34,56),moments:Float32Array.of(2,-3,4)}};rebuildSupportForces();buildLayerPanel();};
   activateWorkspaceTab('displayloads');await frame();
  },{schema:JSON.parse(fs.readFileSync(fixtureFile('schema.json'),'utf8')),bytes:[...fs.readFileSync(fixtureFile('payload.msgpack'))]});
  assert.equal(await page.locator('#tab-displayloads').textContent(),'Loads&Constraints');assert.equal(await page.locator('#tab-vlm').count(),0);
  await page.locator('#tab-displaymenu').click();await page.locator('#tab-displayloads').click();assert(await page.locator('#panel-displayloads').isVisible());
  for(const id of ['load-case-select','entity-group-loads','entity-group-constraints','entity-group-vlm','layer-SPC','vlm-force-scale','btn-vlm-cp','show-rbe3-dofs','show-celas-cylinders','celas-radius','marker-radius','show-support-forces','support-force-scale'])assert.equal(await page.locator('#'+id).evaluate(el=>el.closest('[data-workspace-panel]').dataset.workspacePanel),'displayloads',id);
  for(const id of ['show-ground-plane','show-symmetry-plane','ground-plane-z','ground-grid-spacing'])assert.equal(await page.locator('#'+id).evaluate(el=>el.closest('[data-workspace-panel]').dataset.workspacePanel),'displayenvironment',id);
  for(const key of ['GROUND','SYMMETRY'])assert.equal(await page.locator('[data-geometry="'+key+'"]').evaluate(el=>el.closest('[data-workspace-panel]').dataset.workspacePanel),'displayenvironment');
  for(const id of ['show-reference-aero','show-deformed-aero','show-rib-datums'])assert.equal(await page.locator('#'+id).evaluate(el=>el.closest('[data-workspace-panel]').dataset.workspacePanel),'displaygeometry');
  assert.equal(await page.locator('#support-definitions').evaluate(el=>el.closest('[data-workspace-panel]').dataset.workspacePanel),'supports');
  const duplicateIds=await page.evaluate(()=>[...document.querySelectorAll('[id]')].map(e=>e.id).filter((id,i,all)=>all.indexOf(id)!==i));assert.deepEqual(duplicateIds,[]);
  await page.evaluate(()=>activateWorkspaceTab('vlm'));assert.equal(await page.evaluate(()=>workspaceUI.activeTab),'displayloads');
  assert.equal(await page.locator('#panel-displayloads label:visible input#vlm-show-forces').count(),0);assert(await page.locator('#layer-AERO_LOADS').isVisible());
  checks.push('One Loads&Constraints submenu owns force, pressure, connection and reaction controls; Environment owns context planes, Geometry retains surfaces, and model definitions remain separate');
  await page.locator('#layer-SPC').uncheck();assert(await page.evaluate(()=>state.layers.get('SPC').meshes.every(m=>!m.isEnabled())));await page.locator('#layer-SPC').check();
  await page.locator('#layer-AERO_LOADS').uncheck();assert(await page.evaluate(()=>!state.layers.get('AERO_LOADS').visible&&!document.getElementById('vlm-show-forces').checked));await page.locator('#layer-AERO_LOADS').check();
  await page.locator('#btn-vlm-cp').click();assert.equal(await page.evaluate(()=>document.getElementById('vlm-field').value),'cp');assert(await page.evaluate(()=>state.layers.get('VLM_PRESSURE').visible));
  await page.locator('#layer-VLM_FORCES').check();assert(await page.evaluate(()=>state.layers.get('VLM_FORCES').meshes.some(m=>m.isEnabled())));
  await page.locator('#vlm-force-scale').fill('2');await page.locator('#vlm-force-scale').dispatchEvent('change');
  await page.locator('#load-case-select').selectOption('2');assert(await page.locator('#btn-vlm-cp').isDisabled());assert.equal(await page.locator('#entity-group-vlm').count(),0);
  await page.locator('#load-case-select').selectOption('1');assert(!(await page.locator('#btn-vlm-cp').isDisabled()));assert(await page.locator('#entity-group-vlm').isVisible());
  await page.locator('#show-rbe3-dofs').check();await page.locator('#marker-radius').fill('.035');await page.locator('#marker-radius').dispatchEvent('change');
  checks.push('Generated constraint and applied-load glyphs respond to their relocated toggles; VLM Cp, force scale and case switching rebuild the correct dynamic groups');
  const reactionCases=[];
  for(const analysis of ['SOL101','SOL105','SOL106']){
   await page.evaluate(analysis=>reactions(analysis),analysis);assert(await page.locator('#show-support-forces').isVisible());assert.equal(await page.locator('#layer-SUPPORT_FORCES').count(),0);assert(!(await page.locator('#support-force-scale').isDisabled()));
   await page.locator('#show-support-forces').uncheck();assert(await page.evaluate(()=>!document.getElementById('results-show-support-forces').checked&&state.layers.get('SUPPORT_FORCES').meshes.every(m=>!m.isEnabled())));await page.locator('#show-support-forces').check();
   await page.locator('#show-support-force-values').check();reactionCases.push(await page.evaluate(()=>({analysis:state.results.analysis,glyphs:state.layers.get('SUPPORT_FORCES').meshes.reduce((n,m)=>n+m.metadata.glyphs.length,0)})));
  }
  await page.evaluate(()=>{state.activeMode=0;state.results.modeKind='buckling';rebuildSupportForces();buildLayerPanel();});assert(await page.locator('#support-force-scale').isDisabled());assert.match(await page.locator('#support-force-note').textContent(),/arbitrary normalization/);assert.equal(await page.locator('#layer-SUPPORT_FORCES').count(),0);
  await page.evaluate(()=>reactions('SOL105'));await page.locator('#support-force-scale').fill('1.7');await page.locator('#support-force-scale').dispatchEvent('change');
  checks.push('Physical static SOL101, SOL105 preload and SOL106 reactions remain accessible and independently visible; arbitrary-amplitude buckling modes disable physical reactions');
  await page.evaluate(()=>activateWorkspaceTab('displayenvironment'));await page.locator('#show-ground-plane').check();await page.locator('#show-symmetry-plane').check();
  await page.locator('#ground-plane-z').fill('-0.4');await page.locator('#ground-plane-z').dispatchEvent('change');await page.locator('#ground-grid-spacing').fill('2');await page.locator('#ground-grid-spacing').dispatchEvent('change');
  await page.locator('[data-geometry="GROUND"] select').selectOption('translucent');await page.locator('[data-geometry="GROUND"] input[type="range"]').evaluate(el=>{el.value='.32';el.dispatchEvent(new Event('input',{bubbles:true}));});
  await page.locator('[data-geometry="SYMMETRY"] input[type="color"]').evaluate(el=>{el.value='#df9251';el.dispatchEvent(new Event('input',{bubbles:true}));});
  const planes=await page.evaluate(()=>({z:state.viewPlanes.layout.z,spacing:state.viewPlanes.layout.spacing,alpha:state.viewPlanes.meshes.ground.material.alpha,shown:Object.values(state.viewPlanes.meshes).every(m=>m.isEnabled())}));assert.deepEqual(planes,{z:-.4,spacing:2,alpha:.32,shown:true});
  const groundInputs=await page.evaluate(()=>({input:document.getElementById('ground-plane-z').value,inputNumber:document.getElementById('ground-plane-z').valueAsNumber,toolbar:document.getElementById('view-ground-z').value,toolbarNumber:document.getElementById('view-ground-z').valueAsNumber,note:document.getElementById('view-planes-note').textContent}));assert.equal(groundInputs.input,'-0.4');assert.equal(groundInputs.inputNumber,planes.z);assert.equal(groundInputs.toolbar,'-0.4');assert.equal(groundInputs.toolbarNumber,planes.z);assert.match(groundInputs.note,/global z = -0\.4 m/);
  await page.evaluate(()=>{document.getElementById('workspace-content').scrollTop=0;return frame();});await page.screenshot({path:path.join(out,'environment.png')});
  checks.push('Relocated ground and symmetry inputs change real Babylon plane elevation, spacing, finish, opacity, color and visibility');
  await page.evaluate(()=>activateWorkspaceTab('displayloads'));
  await page.locator('#entity-list-toggle-constraints').click();
  const saved=await page.evaluate(async()=>{const view=WingWorkspace.captureView(document,state,workspaceUI);const study=await WingWorkspace.snapshot(state.values,state.reference,view);return WingWorkspace.parse(JSON.stringify(study)).data.view;});
  assert.equal(saved.workspace.activeTab,'displayloads');assert.equal(saved.controls['marker-radius'],'.035');assert.equal(saved.controls['support-force-scale'],'1.7');assert.equal(saved.geometryAppearance.GROUND.opacity,.32);
  const restored=await page.evaluate(saved=>{const legacy=structuredClone(saved);legacy.workspace.activeTab='vlm';restoreWorkspaceView(legacy);return{tab:workspaceUI.activeTab,ground:state.viewPlanes.layout.z,opacity:state.viewPlanes.meshes.ground.material.alpha,marker:document.getElementById('marker-radius').value,groups:[...state.layerGroupControls.keys()],constraintsCollapsed:document.getElementById('entity-list-constraints').hidden};},saved);assert.equal(restored.tab,'displayloads');assert.equal(restored.ground,-.4);assert.equal(restored.opacity,.32);assert.equal(restored.marker,'.035');assert(restored.groups.includes('constraints'));assert(restored.constraintsCollapsed);
  await page.locator('#entity-list-toggle-constraints').click();
  assert(await page.evaluate(()=>formSignature()===unchanged.signature&&resultMeshIdentity(state.data)===unchanged.mesh&&unchanged.baseline.every((v,i)=>v===state.baseline[i])));
  await page.evaluate(()=>{document.getElementById('workspace-content').scrollTop=0;return frame();});await page.screenshot({path:path.join(out,'loads-constraints.png')});
  checks.push('Study snapshot/parse restores relocated settings and migrates the old VLM active tab; every operation preserves canonical model parameters and FE coordinates');
  const imported=await page.evaluate(async()=>{
   const data=structuredClone(state.data),bytes=a=>new Uint8Array(a.buffer);data.imported_deck={name:'Imported connection display probe'};
   data.imported_connections=[{name:'IMPORTED_RBE2',card:'RBE2',elements:[{eid:90001,type:'RBE2',nodes:[0,1],properties:{CM:'123'}}]},{name:'IMPORTED_CELAS1',card:'CELAS1',elements:[{eid:90002,type:'CELAS1',nodes:[0,1],properties:{PID:42,K:1000},endpoints:[{node:0,component:1,axis:[1,0,0]},{node:1,component:2,axis:[0,1,0]}]}]}];
   data.aero={count:0};data.rib_layout=null;data.fuel={enabled:false};data.rbe3={count:0};data.fuel_rbe3={count:0};data.loads={stations:[]};data.load_cases=[{id:1,label:'Imported static',loads:data.loads}];state.data=data;state.importedDeck=data.imported_deck;buildModel(data);setModelDirty(false);activateWorkspaceTab('displayloads');await frame();
   return{groups:[...state.layerGroupControls.keys()],note:document.getElementById('vlm-view-status').textContent};
  });
  assert(imported.groups.includes('constraints'));assert.match(imported.note,/imported deck has no VLM/);assert(await page.locator('#btn-vlm-cp').isDisabled());assert.equal(await page.locator('#entity-group-vlm').count(),0);
  // Connections are FE entities; Loads & Constraints owns their glyph options.
  await page.evaluate(()=>activateWorkspaceTab('display'));
  for(const name of ['IMPORTED_RBE2','IMPORTED_CELAS1']){assert(await page.locator('#layer-'+name).isVisible());await page.locator('#layer-'+name).uncheck();assert(await page.evaluate(name=>state.layers.get(name).meshes.every(m=>!m.isEnabled()),name));await page.locator('#layer-'+name).check();}
  await page.evaluate(()=>activateWorkspaceTab('displayloads'));
  await page.locator('#show-celas-cylinders').check();assert(await page.evaluate(()=>state.layers.get('IMPORTED_CELAS1').meshes.some(m=>m.springCylinders&&m.isEnabled())));
  await page.evaluate(()=>activateWorkspaceTab('displayenvironment'));assert(await page.locator('[data-geometry="GROUND"] select').isVisible());
  await page.evaluate(()=>activateWorkspaceTab('displaygeometry'));
  for(const selector of ['#aerodynamic-appearance','#loft-cut-controls','#geometry-airfoil-appearance','#geometry-undeformed-structure'])assert(await page.locator(selector).isHidden(),selector+' is inapplicable to imported geometry without a loft or results');
  assert(await page.locator('#reference-file').isVisible());
  checks.push('Imported RBE and spring visibility stays in Entities with glyph options in Loads&Constraints; unavailable aerodynamic geometry is hidden while import/reference tools and environment planes remain accessible');
  assert.deepEqual(requests,[]);assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,reactionCases,planes,groundInputs,restored,imported,requests,errors},null,2));console.log(`Display organization browser: ${checks.length} groups passed.`);
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,requests,errors},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
