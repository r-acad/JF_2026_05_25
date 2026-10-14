'use strict';
// Presentation only: completed generated/imported mesh fixtures; no solver calls.
// node this-file <generated-fixture-dir> <imported-fixture-dir> <evidence-dir> [playwright-module]
// Generated: payload.msgpack,schema.json. Imported: model.msgpack,schema.json.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [generated,imported,out]=process.argv.slice(2,5).map(value=>path.resolve(value));
const {chromium}=require(process.argv[5]||'playwright'),web=path.resolve(__dirname,'../web');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[];
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1500,height:1050}});
 try{
  page.on('pageerror',error=>errors.push(error.stack));const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43963/**',route=>{const name=new URL(route.request().url()).pathname;assert(!name.startsWith('/api/'),'Presentation must not call a solver');return name==='/index.html'?route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')}):route.fulfill({path:path.join(web,name)});});
  await page.goto('http://127.0.0.1:43963/index.html');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const source=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:source.slice(0,source.indexOf('(async function start()'))});
  const initial=await page.evaluate(async({bytes,schema})=>{
   initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;
   window.full=MessagePack.decode(Uint8Array.from(bytes));window.disabled=structuredClone(full);disabled.fuel={enabled:false};disabled.model_params['fuel.enabled']=false;
   window.dry=structuredClone(full);dry.fuel={...dry.fuel,surface:null,active_bay_count:0,volume_m3:0,volume_litres:0};
   window.showFixture=(data,preserve=true)=>{state.data=data;state.values=data.model_params;buildForm(state.schema,state.values);buildModel(data,{preserveView:preserve});state.modelDirty=false;state.modelSignature=formSignature();};
   showFixture(disabled,false);setBusy(false);document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;
   window.readDisplay=()=>({ribDisabled:document.getElementById('mesh-labels-ribs').disabled,stringerDisabled:document.getElementById('mesh-labels-stringers').disabled,panelDisabled:document.getElementById('show-panel-ids').disabled,panels:state.panelIndex.panels.length,fuelDisabled:document.getElementById('show-fuel-tank').disabled,fuelChecked:document.getElementById('show-fuel-tank').checked,fuelVisible:state.layers.get('FUEL_TANK')?.visible??false,fuelMeshes:state.layers.get('FUEL_TANK')?.meshes.filter(mesh=>mesh.isEnabled()).length||0,note:document.getElementById('fuel-display-note').textContent});
   return readDisplay();
  },{bytes:[...fs.readFileSync(path.join(generated,'payload.msgpack'))],schema:JSON.parse(fs.readFileSync(path.join(generated,'schema.json'),'utf8'))});
  assert(initial.fuelDisabled&&initial.fuelChecked);assert(!initial.ribDisabled&&!initial.stringerDisabled&&!initial.panelDisabled&&initial.panels>0);
  const defined=await page.evaluate(()=>{showFixture(full);return readDisplay();});assert(!defined.fuelDisabled&&defined.fuelChecked&&defined.fuelVisible&&defined.fuelMeshes>0);
  checks.push('Generated metadata enables physical labels; enabling a previously absent tank shows its real envelope by default');
  const hidden=await page.evaluate(()=>{const input=document.getElementById('show-fuel-tank');input.checked=false;input.dispatchEvent(new Event('change'));showFixture(disabled);const saved=WingWorkspace.captureView(document,state,workspaceUI);showFixture(full);return{display:readDisplay(),saved,restored:WingWorkspace.completeView(saved,document)};});
  assert(!hidden.display.fuelChecked&&!hidden.display.fuelVisible);assert.equal(hidden.saved.fuelTankVisible,false);assert.equal(hidden.restored.controls['show-fuel-tank'],false);
  checks.push('Explicit tank hide survives removal/recreation and a saved Study whose current model has no tank layer');
  const empty=await page.evaluate(()=>{showFixture(dry);return readDisplay();});assert(empty.fuelDisabled);assert.match(empty.note,/all selected bays are dry/);
  const restored=await page.evaluate(()=>{showFixture(full);const input=document.getElementById('show-fuel-tank');input.checked=true;input.dispatchEvent(new Event('change'));return readDisplay();});assert(restored.fuelVisible&&restored.fuelMeshes>0);
  checks.push('All-dry tanks explain their absent volume; restoring wet bays retains the prior preference and remains manually showable');
  const resultOverlay=await page.evaluate(()=>{syncFuelResultOverlay({kind:'sensitivity'});return readDisplay();});
  assert(resultOverlay.fuelVisible&&resultOverlay.fuelMeshes>0);assert.match(resultOverlay.note,/undeformed position alongside result colors/);
  checks.push('Explicit tank visibility remains effective alongside sensitivity contours with its undeformed placement explained');
  const labels=await page.evaluate(async()=>{
   activateWorkspaceTab('display');document.getElementById('mesh-labels-ribs').checked=true;document.getElementById('mesh-labels-stringers').checked=false;
   setPanelDisplay(true);await state.scene.whenReadyAsync();state.scene.render();state.annotations.render(true);
   const before={shown:state.annotations.stats.panelsShown||[],candidates:WingAnnotations.panelLabelCandidates(state,currentPositions()).length};
   const control=document.getElementById('show-panel-ids');control.checked=false;control.dispatchEvent(new Event('change'));state.annotations.render(true);
   const off={shown:state.annotations.stats.panelsShown||[],isolated:!!state.panelView,ribs:document.getElementById('mesh-labels-ribs').checked,stringers:document.getElementById('mesh-labels-stringers').checked};
   const saved=WingWorkspace.captureView(document,state,workspaceUI);control.checked=true;control.dispatchEvent(new Event('change'));state.annotations.render(true);
   return{before,off,saved,on:state.annotations.stats.panelsShown||[]};
  });assert(labels.before.candidates>0&&labels.before.shown.length>0);assert.deepEqual(labels.off.shown,[]);assert(labels.off.isolated&&labels.off.ribs&&!labels.off.stringers);assert.equal(labels.saved.controls['show-panel-ids'],false);assert.equal(labels.saved.controls['show-panels'],true);assert(labels.on.length>0);
  checks.push('Panel IDs toggle independently of isolation and rib/stringer labels, and persist separately in Study controls');
  await page.screenshot({path:path.join(out,'generated-panel-ids.png')});
  const exploded=await page.evaluate(()=>{setPanelDisplay(false);document.getElementById('show-panel-ids').checked=false;state.panelExplosion.restore({enabled:true,origin:'centroid',distance:.1});refreshPanelExplosion();state.scene.render();state.annotations.render(true);return{active:state.panelExplosion.active,panels:state.annotations.stats.panelsShown||[],isolation:!!state.panelView};});assert(exploded.active&&!exploded.isolation);assert.deepEqual(exploded.panels,[]);
  checks.push('Exploded panels honor the same independent panel-ID preference');
  const importedState=await page.evaluate(({bytes,schema})=>{state.schema=schema.schema;const data=MessagePack.decode(Uint8Array.from(bytes));state.importedDeck={...data.imported_deck,source:data.model_source};showFixture(data,false);return{...readDisplay(),labelNote:document.getElementById('physical-labels-status').textContent,ribsChecked:document.getElementById('mesh-labels-ribs').checked};},{bytes:[...fs.readFileSync(path.join(imported,'model.msgpack'))],schema:JSON.parse(fs.readFileSync(path.join(imported,'schema.json'),'utf8'))});
  assert(importedState.ribDisabled&&importedState.stringerDisabled&&importedState.panelDisabled&&importedState.fuelDisabled);assert(importedState.ribsChecked);assert.match(importedState.labelNote,/no physical rib or stringer label metadata/);assert.match(importedState.note,/no fuel-tank volume metadata/);
  checks.push('An imported model without physical metadata disables unavailable labels and panel IDs without discarding saved checkbox preferences');
  assert.deepEqual(errors,[]);await page.evaluate(()=>activateWorkspaceTab('displaylabels'));await page.screenshot({path:path.join(out,'imported-label-availability.png')});
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,initial,defined,hidden: {display:hidden.display,fuelTankVisible:hidden.saved.fuelTankVisible},empty,labels,exploded,importedState,errors},null,2));console.log('Display availability browser: '+checks.length+' scenarios passed');
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
