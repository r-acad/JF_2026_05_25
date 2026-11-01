'use strict';
// Real unchanged editor modules, isolated native fixture; no live API mutations.
// node numeric_inputs_browser_test.cjs FIXTURE OUTPUT PLAYWRIGHT_MODULE
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [fixtureArg,outArg,modulePath='playwright']=process.argv.slice(2);
const fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
const {chromium}=require(modulePath),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));
// Long pre-existing values test lossless opening/saving. The supplied native
// mesh is used only to populate editor choices; no changed solve is claimed.
schema.values['nonstructural.rib_stiffener']=.123456789123;
schema.values['loads.lift_total']=12345.678901234;
schema.defaults=schema.values;
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[];
 const browser=await chromium.launch({channel:'chrome',headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1660,height:1080}}),page=await context.newPage();
 context.on('page',p=>p.on('pageerror',e=>errors.push(e.stack)));page.on('pageerror',e=>errors.push(e.stack));page.setDefaultTimeout(30000);
 const origin='http://127.0.0.1:43976';
 await context.route(origin+'/**',route=>{const p=new URL(route.request().url()).pathname;
  if(p==='/api/input')return route.fulfill({json:{...schema,ok:true}});
  if(p==='/api/validate_workspace')return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
  if(['/api/prepare_workspace','/api/generate'].includes(p))return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated numeric-entry test'}});
  return route.fulfill({path:p==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,p==='/'?'index.html':p)});
 });
 const read=()=>page.evaluate(()=>JSON.parse(JSON.stringify(collectParams({includeView:true}))));
 async function edit(selector,value){const f=page.locator(selector);await f.fill(value);await f.dispatchEvent('change');return f;}
 try{
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();
  await page.waitForFunction(()=>state.studyEpoch>0&&!state.workspaceBusy);
  await page.locator('#btn-create').click();await page.waitForFunction(()=>state.data&&!state.meshRequestInFlight);
  await page.evaluate(()=>{state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();state.engine.stopRenderLoop();activateWorkspaceTab('sections');});
  const original=await read(),geometry=await page.evaluate(()=>JSON.stringify(state.data.nodes.xyz)),computedLoads=await page.evaluate(()=>JSON.stringify(state.data.loads));
  assert(geometry.length>100);assert(computedLoads.length>50);
  assert.equal(original['nonstructural.rib_stiffener'],.123456789123);
  assert.equal(original['loads.lift_total'],12345.678901234);
  const height=await edit('[id="p-properties.stringer_height"]','0.07085');
  assert.equal(await height.inputValue(),'70.85e-3');assert.equal((await read())['properties.stringer_height'],.07085);
  await page.evaluate(()=>activateWorkspaceTab('nonstructural'));
  const mass=await edit('[id="p-nonstructural.stringer"]','0.07695');
  assert.equal(await mass.inputValue(),'76.95e-3');assert.equal((await read())['nonstructural.stringer'],.07695);
  assert.equal(await page.locator('[id="p-nonstructural.movable"]').count(),1);
  await edit('[id="p-nonstructural.movable"]','.5');assert.equal((await read())['nonstructural.movable'],.5);
  checks.push('Static SI dimensions and NSM preserve 0.07085 m / 0.07695 kg/m through commit and Study collection; movable NSM field exists.');
  await page.evaluate(()=>activateWorkspaceTab('shells'));
  const skin=await edit('[id="p-properties.t_skin_upper"]','0.0005');
  assert.equal(await skin.inputValue(),'500e-6');assert.equal((await read())['properties.t_skin_upper'],.0005);
  checks.push('The 1 mm skin value is a new-study default, not a clamp: an explicit 0.5 mm family minimum stays nonzero.');
  await page.evaluate(()=>activateWorkspaceTab('movablesurfaces'));
  const eta=await edit('[data-movable-field="eta_start"]','0.123456789');
  assert.equal(await eta.inputValue(),'123.46e-3');assert.equal((await read())['movable_surfaces.items'][0].eta_start,.12346);
  assert(await eta.evaluate(e=>e.checkValidity()),'an arbitrary valid eta must not fail HTML step validation');
  await eta.press('ArrowUp');assert.equal(Number(await eta.inputValue()),.2);
  const etaBox=await eta.boundingBox();await eta.click({position:{x:etaBox.width-16,y:etaBox.height/2-4}});
  assert.equal(Number(await eta.inputValue()),.3,'native spinner retains the original 0.1 increment');
  await edit('[data-movable-field="eta_start"]','0.12346');
  checks.push('Coordinate commits keep five significant figures in engineering notation without the legacy formatter expanding the decimals.');
  checks.push('Off-grid engineering values pass HTML validity; native arrow keys and spinner clicks still use the requested 0.1 eta increment.');
  await page.evaluate(()=>activateWorkspaceTab('movablestructure'));
  const movable=await edit('[data-movable-structure-field="upper_thickness"]','0.00123456');
  assert.equal(await movable.inputValue(),'1.235e-3');assert.equal((await read())['movable_structure.surfaces'][0].upper_thickness,.001235);
  checks.push('Dynamically created movable controls normalize the committed draft before hidden JSON is saved.');
  await page.evaluate(()=>activateWorkspaceTab('engines'));await page.locator('#engine-add').click();
  const engineI=page.locator('[data-engine-field="I1"]');assert.equal(await engineI.count(),1);
  await edit('[data-engine-field="I1"]','1e-12');await edit('[data-engine-field="E"]','73.1');
  assert.equal((await read())['engines.items'][0].I1,1e-12);assert.equal((await read())['engines.items'][0].E,73.1e9);
  checks.push('Dynamic engine I1=1e-12 m4 remains nonzero; E=73.1 GPa stores exactly 73.1e9 Pa.');
  await page.evaluate(()=>activateWorkspaceTab('material'));
  await page.locator('#material-library-select').selectOption('2');
  const modulus=page.locator('.material-library-row:not([hidden]) input[aria-label="E (GPa)"]');await modulus.fill('73.123456');await modulus.dispatchEvent('change');
  assert.equal(await modulus.inputValue(),'73.123');assert.equal((await read())['materials.library'].find(r=>r.id===2).E,73.123e9);
  checks.push('Text inputs with decimal inputMode follow the same precision policy in the material editor.');
  await page.evaluate(()=>activateWorkspaceTab('ribproperties'));
  const tableButton=page.locator('#btn-panel-table-ribwebs');assert(await tableButton.isEnabled(),await tableButton.evaluate(e=>e.outerHTML));
  const [popup]=await Promise.all([page.waitForEvent('popup'),tableButton.click()]);
  await popup.waitForLoadState();await popup.waitForSelector('.panel-cell input');
  const cell=popup.locator('.panel-cell input').first();await cell.fill('2.34567');await cell.press('Tab');
  await page.waitForFunction(()=>JSON.parse(document.getElementById('p-properties.components').value).some(r=>r.thickness===.002346));
  checks.push('Separate rib-property popup commits 2.34567 mm as 2.346 mm / 0.002346 m through the native edit protocol.');
  await popup.close();await page.evaluate(()=>activateWorkspaceTab('nonstructural'));
  await page.locator('[id="p-nonstructural.stringer"]').fill('0.076954321');
  const saved=await read();assert.equal(saved['nonstructural.stringer'],.076954);
  assert.equal(saved['nonstructural.rib_stiffener'],original['nonstructural.rib_stiffener']);
  assert.equal(saved['loads.lift_total'],original['loads.lift_total']);
  assert.equal(await page.evaluate(()=>JSON.stringify(state.data.nodes.xyz)),geometry);
  assert.equal(await page.evaluate(()=>JSON.stringify(state.data.loads)),computedLoads);
  assert.deepEqual(JSON.parse(JSON.stringify(saved)),saved);
  checks.push('Saving commits a still-active edit; untouched high-precision NSM/load values and computed FE coordinates are not rounded.');
  // Exercise the actual Save / Save As path and its File writer, without a
  // system dialog or any write to a running Boxer instance.
  await page.evaluate(()=>{
   state.autosave?.destroy();state.recentStudies=null;window.__studyWrites=0;
   const handle={kind:'file',name:'numeric-entry.wingfem.json',queryPermission:async()=>'granted',requestPermission:async()=>'granted',createWritable:async()=>{
    let text='';return{write:async value=>{text=String(value);},close:async()=>{window.__writtenStudy=new File([text],handle.name,{type:'application/json'});window.__studyWrites++;},abort:async()=>{}};
   }};
   window.showSaveFilePicker=async()=>handle;
  });
  const save=saveAs=>page.evaluate(async saveAs=>{const result=await saveModelDefinition({saveAs});if(!result)throw Error('Actual Study save failed: '+document.getElementById('model-error-text')?.textContent);return JSON.parse(await window.__writtenStudy.text());},saveAs);
  await page.locator('[id="p-nonstructural.stringer"]').fill('0.076954321');
  const actual=await save(true);
  assert.equal(actual.parameters['nonstructural.stringer'],.076954);
  assert.equal(actual.parameters['nonstructural.rib_stiffener'],original['nonstructural.rib_stiffener']);
  assert.equal(actual.parameters['engines.items'][0].I1,1e-12);
  checks.push('Actual Save Study as commits the focused field into a File-backed writer, preserves untouched precision and retains tiny engine inertia I1=1e-12.');
  await page.evaluate(()=>{
   activateWorkspaceTab('aerostudy');const prior=state.aerodynamicStudy.capture();
   state.aerodynamicStudy.restore({...prior,settings:{...prior.settings,p:1.234567891}});
  });
  const detached=async()=>{const pending=page.waitForEvent('popup');await page.locator('[data-action=detach]').click();const popup=await pending;await popup.locator('[data-aero-field=speed]').waitFor();return popup;};
  let aeroPopup=await detached();
  assert(await aeroPopup.evaluate(()=>!!window.WingNumericInputs));
  await aeroPopup.locator('[data-aero-field=speed]').fill('42.1234567');await aeroPopup.locator('[data-aero-field=speed]').press('Tab');
  assert.equal(await aeroPopup.locator('[data-aero-field=speed]').inputValue(),'42.123');
  await aeroPopup.locator('input[data-reference="0"]').fill('1e-12');await aeroPopup.locator('input[data-reference="0"]').press('Tab');
  assert.equal(await aeroPopup.locator('input[data-reference="0"]').inputValue(),'1e-12');
  await aeroPopup.locator('[data-aero-field=speed]').fill('43.1234567');
  await aeroPopup.locator('[data-action=detach]').click();await page.waitForFunction(()=>!state.aerodynamicStudy.detached);
  assert.equal(await page.locator('[data-aero-field=speed]').inputValue(),'43.123');
  aeroPopup=await detached();await aeroPopup.locator('[data-aero-field=speed]').fill('44.1234567');
  assert.equal(await page.evaluate(()=>state.aerodynamicStudy.capture().settings.speed),44.1234567,'ordinary capture must not interrupt typing');
  const fromDetached=await save(false);
  assert.equal(fromDetached.view.aerodynamics.settings.speed,44.123);
  assert.equal(fromDetached.view.aerodynamics.settings.p,1.234567891,'untouched loaded rate remains exact');
  assert.equal(fromDetached.view.aerodynamics.settings.reference[0],1e-12);
  assert.equal(await aeroPopup.locator('[data-aero-field=speed]').inputValue(),'44.123');
  await aeroPopup.locator('[data-aero-field=speed]').fill('45.1234567');await aeroPopup.close();
  await page.waitForFunction(()=>!state.aerodynamicStudy.detached);
  assert.equal(await page.locator('[data-aero-field=speed]').inputValue(),'45.123');
  assert.equal(await page.evaluate(()=>state.aerodynamicStudy.capture().settings.p),1.234567891);
  checks.push('Real detached Aerodynamics edits normalize on blur, explicit return, close and actual main-window Save; tiny coordinates and untouched loaded rates survive transfer/capture.');
  await page.evaluate(()=>activateWorkspaceTab('nonstructural'));
  const active=page.locator('[id="p-nonstructural.stringer"]');await active.fill('0.076954321');
  await page.evaluate(async()=>{document.getElementById('auto-save').checked=true;const ok=await autosaveStudy({epoch:state.studyEpoch,revision:state.studyRevision});if(!ok)throw Error('Actual autosave did not complete');});
  assert.equal(await active.inputValue(),'0.076954321');
  assert.equal(await active.evaluate(e=>e===document.activeElement),true);
  assert.equal(await page.evaluate(async()=>JSON.parse(await window.__writtenStudy.text()).parameters['nonstructural.stringer']),.076954321);
  const committed=await save(false);assert.equal(committed.parameters['nonstructural.stringer'],.076954);
  checks.push('Actual autosave preserves the active raw draft and focus; a later explicit Save commits its precision.');
  assert.deepEqual(errors,[]);await page.screenshot({path:path.join(out,'numeric-entry-controls.png')});
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(e){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw e;}
 finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
