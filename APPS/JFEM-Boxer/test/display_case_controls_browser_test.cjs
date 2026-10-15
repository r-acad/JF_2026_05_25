'use strict';
// node test/display_case_controls_browser_test.cjs <fixture-dir> <evidence-dir> [playwright-module]
// Fixture: schema.json and payload.msgpack containing a generated model with two or more cases.
// Uses actual geometry/load payloads and explicitly synthetic displacement/fuel metadata.
// No solver or model-generation request. CHROME_PATH optionally selects Chrome.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
if(!process.argv[2]||!process.argv[3])throw Error('Usage: node test/display_case_controls_browser_test.cjs <fixture-dir> <evidence-dir> [playwright-module]');
const fixture=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]),web=path.resolve(__dirname,'../web'),{chromium}=require(process.argv[4]||'playwright');
const schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));schema.defaults??=schema.values;
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],requests=[];
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1510,height:1080}});page.on('pageerror',e=>errors.push(e.stack));
 try{
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43955/**',route=>{const url=new URL(route.request().url());if(url.pathname.startsWith('/api/')){requests.push(url.pathname);return url.pathname==='/api/sensitivity/saved/list'?route.fulfill({json:{runs:[]}}):url.pathname==='/api/activity'?route.fulfill({json:{ok:true}}):route.fulfill({status:404,json:{error:'Display-only fixture'}});}return url.pathname==='/'?route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')}):route.fulfill({path:path.join(web,url.pathname)});});
  await page.goto('http://127.0.0.1:43955/');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:app.slice(0,app.indexOf('(async function start()'))});
  const fixtureInfo=await page.evaluate(async({schema,bytes})=>{
   initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.defaults=schema.defaults;state.data=MessagePack.decode(Uint8Array.from(bytes));state.values=state.data.model_params;
   if(state.data.load_cases.length<2)throw Error('At least two generated cases required');
   state.data.load_cases=state.data.load_cases.slice(0,2);
   for(const [index,c]of state.data.load_cases.entries()){
    const mass=10*(index+1);c.fuel={...c.fuel,enabled:true,mass_kg:mass,bays:[{index:1,mass_kg:mass,reference_m:[0,1,0],center_of_gravity_m:[0,1,0],inertia_kg_m2:[[mass,0,0],[0,2*mass,0],[0,0,3*mass]]}]};
    c.weights.totals.fuel_mass_kg=mass;c.weights.totals.fuel_weight_N=mass*9.80665;
   }
   state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;buildForm(state.schema,state.values);buildModel(state.data);state.modelSignature=formSignature();setModelDirty(false);setBusy(false);
   document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;
   window.frame=async()=>{state.engine.resize();await state.scene.whenReadyAsync();state.scene.render();await new Promise(requestAnimationFrame);};
   window.beforeDefinition=formSignature();window.beforeCoordinates=Array.from(state.baseline);markStudySaved();window.testCases=state.data.load_cases.map(c=>({id:c.id,label:c.label,lift:c.loads.summary.lift_N,mass:c.fuel.mass_kg}));
   const node=state.nodeIds.length-1;window.inspectedNode=node;
   state.resultCases=new Map(state.data.load_cases.map((c,index)=>{const disp=new Float32Array(state.baseline.length);disp[3*node]=.01*(index+1);return[c.id,{matches:true,available:true,analysis:'SOL101',source:'test',report:'Synthetic displacement probe case '+c.id,static:{disp,maxDisp:.01*(index+1)},modes:[],contours:[],summary:[],elementResults:{},modelParams:{...state.values}}];}));
   selectLoadCase(testCases[0].id);document.getElementById('animate').checked=false;state.realScale=true;applyDeformation();activateWorkspaceTab('displaygeometry');await frame();
   return testCases;
  },{schema,bytes:[...fs.readFileSync(path.join(fixture,'payload.msgpack'))]});
  for(const id of ['show-deformed-aero','show-reference-aero']){
   assert.equal(await page.locator('#'+id).count(),1);
   assert.equal(await page.locator('#'+id).evaluate(el=>el.closest('.entity-group')?.id),'entity-group-aerodynamics');
   assert.equal(await page.locator('#geometry-results #'+id).count(),0);
  }
  assert.equal(await page.locator('[data-geometry="REFERENCE_AERO"]').evaluate(el=>el.closest('.entity-group')?.id),'entity-group-aerodynamics');
  assert.equal(await page.locator('#layer-REFERENCE_AERO').count(),0);
  assert.equal(await page.locator('#layer-AERO_SURFACE').count(),0);
  await page.locator('#show-reference-aero').check();await page.locator('#show-deformed-aero').uncheck();
  assert(await page.evaluate(()=>!state.layers.get('AERO_SURFACE').visible&&state.layers.get('REFERENCE_AERO').visible));
  await page.evaluate(()=>{buildLayerPanel();buildLayerPanel();});await page.locator('#show-deformed-aero').check();await page.locator('#show-reference-aero').uncheck();
  assert(await page.evaluate(()=>state.layers.get('AERO_SURFACE').visible&&!state.layers.get('REFERENCE_AERO').visible));
  await page.locator('#entity-group-toggle-aerodynamics').check();await page.locator('#entity-group-toggle-aerodynamics').uncheck();assert(await page.evaluate(()=>['AERO_SURFACE','AIRFOIL_SECTIONS','REFERENCE_AERO'].every(key=>!state.layers.get(key).visible)));
  await page.locator('#entity-group-toggle-aerodynamics').check();assert(await page.evaluate(()=>['AERO_SURFACE','AIRFOIL_SECTIONS','REFERENCE_AERO'].every(key=>state.layers.get(key).visible)));
  checks.push('Current and reference aero toggles and reference finish belong to Aerodynamic geometry, remain unique and functional after rebuilds, and obey its group switch');
  const targets=[['displaygeometry','geometry-case-select'],['displaymass','mass-case-select'],['summary','summary-case-select'],['displayloads','load-case-select'],['results','result-case-select'],['weights','weights-case-select'],['loadplots','plots-case-select'],['inspect','inspect-case-select']];
  for(const [index,[tab,id]]of targets.entries()){
   const wanted=fixtureInfo[index%2];await page.evaluate(tab=>activateWorkspaceTab(tab),tab);
   assert(await page.locator('#'+id).isVisible(),id+' must be visible');await page.locator('#'+id).selectOption(String(wanted.id));
   const actual=await page.evaluate(()=>({active:state.activeCase,selectors:['geometry-case-select','mass-case-select','summary-case-select','load-case-select','result-case-select','weights-case-select','plots-case-select','inspect-case-select'].map(id=>[id,document.getElementById(id)?.value]),displacement:state.results.static.disp[3*inspectedNode],summary:document.getElementById('stats').textContent,mass:document.getElementById('fuel-mass-status').textContent}));
   assert.equal(actual.active,wanted.id,id);for(const [name,value]of actual.selectors)assert.equal(value,String(wanted.id),name+' synchronized');
   assert(Math.abs(actual.displacement-.01*(index%2+1))<1e-8);assert(actual.summary.includes(await page.evaluate(x=>eng(x,4),wanted.lift)));assert.match(actual.mass,new RegExp('Case '+wanted.id+': '+wanted.mass+' kg'));
  }
  checks.push('All eight case-dependent panels expose a local selector and synchronize case, displacement, aerodynamic summary and fuel mass without navigating away');
  await page.evaluate(()=>{activateWorkspaceTab('inspect');showNode(inspectedNode);});const firstPick=await page.locator('#pick-content').innerText();
  await page.locator('#inspect-case-select').selectOption(String(fixtureInfo[0].id));const secondPick=await page.locator('#pick-content').innerText();assert.notEqual(firstPick,secondPick);assert.equal(await page.evaluate(()=>state.selectedNode),await page.evaluate(()=>inspectedNode));
  checks.push('Changing the case in Inspect refreshes the selected node results while preserving its selection');
  assert(await page.evaluate(()=>formSignature()===beforeDefinition&&!state.studyDirty));
  checks.push('Display case changes preserve the model definition and do not mark the Study definition dirty');
  await page.evaluate(()=>{activateWorkspaceTab('sensitivity');state.sensitivity.refreshContext();});
  await page.locator('#sensitivity-case').selectOption(String(fixtureInfo[1].id));
  await page.evaluate(id=>{selectLoadCase(id);activateWorkspaceTab('sensitivity');},fixtureInfo[0].id);
  assert.equal(await page.locator('#sensitivity-case').inputValue(),String(fixtureInfo[1].id));
  checks.push('Sensitivity analysis setup retains its independently chosen case when the displayed case changes');
  await page.evaluate(c=>{state.sensitivityResult={case_id:c.id,case_label:c.label,objective:{type:'displacement',component:'magnitude',node_id:1},baseline:{value:1,unit:'m'},rows:[{id:'properties.skin_upper',value:.01,derivative:2,status:'complete'}]};refreshSensitivityMapCard();activateWorkspaceTab('sensitivityresults');},fixtureInfo[0]);
  assert.match(await page.locator('#sensitivity-map-summary').textContent(),new RegExp(fixtureInfo[0].label));await page.locator('#sensitivity-map-choose-run').click();
  await page.waitForFunction(()=>document.getElementById('sensitivity-saved-status').textContent.includes('No completed sensitivity runs'));
  assert.equal(await page.evaluate(()=>workspaceUI.activeTab),'sensitivity');assert(await page.locator('#sensitivity-editor .sensitivity-saved').evaluate(el=>el.open));assert.equal(await page.locator('#sensitivity-case').inputValue(),String(fixtureInfo[1].id));assert.equal(await page.evaluate(()=>state.sensitivityResult.case_id),fixtureInfo[0].id);
  checks.push('Retained sensitivity fields keep their recorded case; Choose sensitivity run opens saved runs without retargeting derivatives or analysis setup');
  const saved=await page.evaluate(()=>WingWorkspace.captureView(document,state,workspaceUI));assert.equal(saved.activeCase,fixtureInfo[0].id);
  await page.evaluate(id=>selectLoadCase(id),fixtureInfo[1].id);await page.evaluate(view=>restoreWorkspaceView(view),saved);
  assert.equal(await page.evaluate(()=>state.activeCase),fixtureInfo[0].id);
  for(const id of ['geometry-case-select','mass-case-select','summary-case-select','inspect-case-select'])assert.equal(await page.locator('#'+id).inputValue(),String(fixtureInfo[0].id));
  checks.push('Study view restore synchronizes the local selectors with the saved active case');
  await page.evaluate(async()=>{activateWorkspaceTab('displaygeometry');document.getElementById('workspace-content').scrollTop=0;await frame();});await page.screenshot({path:path.join(out,'aerodynamic-geometry-and-case.png')});
  await page.evaluate(async()=>{activateWorkspaceTab('displaymass');document.getElementById('workspace-content').scrollTop=0;await frame();});await page.screenshot({path:path.join(out,'mass-case-selector.png')});
  await page.evaluate(async()=>{state.results=null;state.activeMode=-1;restoreBaseline();syncResultOverlays();buildLayerPanel();activateWorkspaceTab('displaygeometry');document.getElementById('workspace-content').scrollTop=0;await frame();});
  assert.match(await page.locator('#deformed-aero-label').textContent(),/^Undeformed aero/);assert(await page.locator('#show-reference-aero').isHidden());assert(await page.locator('[data-geometry="REFERENCE_AERO"]').isHidden());assert(await page.locator('#show-deformed-aero').isVisible());
  assert.equal(await page.locator('#entity-group-aerodynamics #show-deformed-aero').count(),1);await page.screenshot({path:path.join(out,'undeformed-aerodynamic-geometry.png')});
  checks.push('Without an active FE shape, the one Undeformed aero control stays in Aerodynamic geometry and the redundant undeformed-reference toggle is hidden');
  assert.deepEqual(await page.evaluate(()=>[...document.querySelectorAll('[id]')].map(el=>el.id).filter((id,index,all)=>all.indexOf(id)!==index)),[]);
  assert(await page.evaluate(()=>beforeCoordinates.every((value,i)=>value===state.baseline[i])));assert.deepEqual(errors,[]);assert.deepEqual(requests.filter(p=>p!=='/api/activity'),['/api/sensitivity/saved/list']);
  checks.push('Display case changes preserve coordinates and do not run a solve or model regeneration');
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,fixtureInfo,errors,requests},null,2));console.log(`Display case controls: ${checks.length} groups passed.`);
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors,requests},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
