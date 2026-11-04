'use strict';
// Real app, isolated native-mesh bootstrap and mocked file handles only.
// node study_new_unsaved_browser_test.cjs OUT BOOTSTRAP_FIXTURE PLAYWRIGHT [BROWSER]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,fixtureArg,pwArg,browserArg]=process.argv.slice(2),out=path.resolve(outArg),fixture=path.resolve(fixtureArg),web=path.resolve(__dirname,'../web');
const{chromium}=require(path.resolve(pwArg)),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));
schema.defaults=JSON.parse(fs.readFileSync(path.join(fixture,'params.json'),'utf8'));
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(browserArg?{executablePath:browserArg}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1800,height:1100}}),checks=[],errors=[],requests=[];page.setDefaultTimeout(25000);page.on('pageerror',e=>errors.push(e.message));
 const unsaved=()=>page.locator('[data-unsaved-study=true]'),identify=()=>page.locator('.startup-study-dialog:not([data-unsaved-study])');
 const settle=()=>page.waitForFunction(()=>!state.newStudyPending&&!state.workspaceBusy&&!state.studyCommentOpen&&!state.meshRequestInFlight);
 const project=async button=>{if(!await button.isVisible())await page.locator('#btn-project').click();await button.click();};
 const startNew=()=>project(page.locator('#btn-new-study'));
 const note=text=>page.evaluate(text=>{const input=document.getElementById('study-note');input.value=text;input.dispatchEvent(new Event('input',{bubbles:true}));},text);
 const snapshot=()=>page.evaluate(()=>({epoch:state.studyEpoch,name:state.studyFile,handle:state.studyFileHandle?.name||null,dirty:state.studyDirty,parameters:collectParams(),notes:structuredClone(state.studyNotes),note:document.getElementById('study-note').value,identification:state.studyWatermark.capture()}));
 const submitComment=async text=>{if(text!==undefined)await page.locator('#study-save-comment').fill(text);await page.locator('.study-comments-save').click();};
 const beginSaveFromNew=async text=>{await startNew();await unsaved().locator('[data-unsaved-choice=save]').click();await page.locator('#study-save-comment').waitFor();await submitComment(text);};
 try{
  await page.route('http://127.0.0.1:43988/**',async route=>{
   const u=new URL(route.request().url()),data=route.request().method()==='POST'?route.request().postDataJSON():null;if(u.pathname.startsWith('/api/'))requests.push(u.pathname);
   if(u.pathname==='/api/input')return route.fulfill({json:schema});
   if(u.pathname==='/api/validate_workspace')return route.fulfill({json:{ok:true,parameters:data}});
   if(['/api/generate','/api/prepare_workspace'].includes(u.pathname))return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});
   if(u.pathname==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
   if(u.pathname==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
   if(u.pathname==='/api/jfem_probe')return route.fulfill({json:{found:true}});
   if(u.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated New Study test'}});
   const file=u.pathname.startsWith('/shared/')?path.join(web,'../..',u.pathname.slice(8)):path.join(web,u.pathname==='/'?'index.html':decodeURIComponent(u.pathname));
   return fs.existsSync(file)?route.fulfill({path:file}):route.fulfill({status:404,body:'Missing fixture asset'});
  });
  await page.goto('http://127.0.0.1:43988/');await page.locator('.startup-study-dialog [data-study-identification=text]').fill('Original assignment');await page.locator('.startup-study-dialog [data-choice=new]').click();
  await page.waitForFunction(()=>state.autoMeshReady&&!state.workspaceBusy&&!state.meshRequestInFlight,null,{timeout:120000});assert.equal(await unsaved().count(),0);
  await page.evaluate(()=>{
   state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();window.savedFiles=[];window.pickerCalls=0;window.cancelPicker=false;window.failWrite=false;window.nextName='Original.wingfem.json';
   window.makeHandle=name=>({name,kind:'file',requestPermission:async()=> 'granted',createWritable:async()=>({write:async text=>{if(window.failWrite)throw Error('Fixture disk full');window.savedFiles.push({name,text,epoch:state.studyEpoch});},close:async()=>{},abort:async()=>{}})});
   window.showSaveFilePicker=()=>{if(!navigator.userActivation.isActive)throw Error('Save picker lost user activation');window.pickerCalls++;if(window.cancelPicker)return Promise.reject(Object.assign(Error('Cancelled'),{name:'AbortError'}));return Promise.resolve(window.makeHandle(window.nextName));};
  });
  await project(page.locator('#btn-save-model'));await submitComment();await page.waitForFunction(()=>savedFiles.length===1&&!state.workspaceBusy);
  assert.equal(await page.locator('#btn-save-model').getAttribute('data-saved'),'true');checks.push('Initial startup New creates a Study without an unsaved-change prompt; Save links a file and turns green.');

  await page.evaluate(()=>{activateWorkspaceTab('aerostudy');state.camera.alpha+=.1;});await page.getByLabel('Aerodynamic contour',{exact:true}).selectOption('force');
  assert.equal(await page.evaluate(()=>state.studyDirty),false);assert.equal(await page.locator('#btn-save-model').getAttribute('data-saved'),'true');
  await page.locator('[data-aero-field=speed]').fill('71');await page.locator('[data-aero-field=speed]').dispatchEvent('change');assert.equal(await page.locator('#btn-save-model').getAttribute('data-saved'),'false');
  await note('Current aerodynamic changes');const original=await snapshot(),writes=await page.evaluate(()=>savedFiles.length);
  await startNew();assert(await unsaved().isVisible());await unsaved().locator('[data-unsaved-choice=cancel]').click();await settle();assert.deepEqual(await snapshot(),original);
  await startNew();await page.keyboard.press('Escape');await settle();assert.deepEqual(await snapshot(),original);assert.equal(await page.evaluate(()=>savedFiles.length),writes);
  checks.push('Aero definition edits turn Save orange; camera/display changes stay green. Cancel and Escape preserve the complete current Study.');

  await startNew();await unsaved().locator('[data-unsaved-choice=save]').click();await page.locator('.study-comments-cancel').click();await settle();assert.deepEqual(await snapshot(),original);
  await page.evaluate(()=>{state.studyFileHandle=null;window.cancelPicker=true;});const unlinked=await snapshot();await beginSaveFromNew();await settle();assert.deepEqual(await snapshot(),unlinked);assert.equal(await identify().count(),0);
  await page.evaluate(()=>{window.cancelPicker=false;window.failWrite=true;});await beginSaveFromNew();await settle();assert.deepEqual(await snapshot(),unlinked);assert.match(await page.locator('#model-error').textContent(),/Fixture disk full/);assert.equal(await page.evaluate(()=>savedFiles.length),writes);
  checks.push('Canceling the save dialog or picker, and a failed write, all retain the current Study and stop New.');

  await page.evaluate(()=>{window.failWrite=false;window.nextName='Before-new.wingfem.json';});await beginSaveFromNew();await identify().locator('.startup-study-create').waitFor();
  const saved=await snapshot();assert.equal(saved.dirty,false);assert.equal(saved.name,'Before-new.wingfem.json');const disk=await page.evaluate(()=>JSON.parse(savedFiles.at(-1).text));
  assert.equal(disk.view.aerodynamics.settings.speed,71);assert.equal(disk.notes.text,'Current aerodynamic changes');assert.equal(disk.identification.text,'Original assignment');
  fs.writeFileSync(path.join(out,'study-before-new.json'),JSON.stringify(disk,null,2));await identify().getByRole('button',{name:'Cancel',exact:true}).click();await settle();assert.deepEqual(await snapshot(),saved);
  checks.push('Save writes the edited aerodynamic settings, notes and identification before New; canceling identification keeps the successfully saved original.');

  const cleanEpoch=saved.epoch;await startNew();assert.equal(await unsaved().count(),0);await identify().locator('[data-study-identification=text]').fill('Clean replacement');await identify().locator('.startup-study-create').click();await settle();
  assert.notEqual((await snapshot()).epoch,cleanEpoch);assert.equal((await snapshot()).identification.text,'Clean replacement');checks.push('New on a clean saved Study skips the unsaved prompt and proceeds directly to identification.');

  await note('Do not lose this unsaved definition');const beforeDiscard=await snapshot(),countBeforeDiscard=await page.evaluate(()=>savedFiles.length);
  await startNew();await unsaved().locator('[data-unsaved-choice=discard]').click();await identify().getByRole('button',{name:'Cancel',exact:true}).click();await settle();assert.deepEqual(await snapshot(),beforeDiscard);
  await page.evaluate(()=>{document.getElementById('auto-save').checked=true;state.autosave.changed();});await startNew();await page.evaluate(()=>state.autosave.run());assert.equal(await page.evaluate(()=>savedFiles.length),countBeforeDiscard);
  await unsaved().locator('[data-unsaved-choice=discard]').click();await identify().locator('[data-study-identification=text]').fill('Discard replacement');await identify().locator('.startup-study-create').click();await settle();
  await page.evaluate(()=>{document.getElementById('auto-save').checked=false;state.autosave.changed();});assert.equal(await page.evaluate(()=>savedFiles.length),countBeforeDiscard);assert.notEqual((await snapshot()).epoch,beforeDiscard.epoch);assert.equal((await snapshot()).identification.text,'Discard replacement');assert.equal((await snapshot()).note,'');
  checks.push('Discard followed by canceled identification retains changes; confirmed Discard creates the new Study without writing the old one, and Autosave remains blocked during the prompt.');
  assert(!requests.some(p=>/run_jfem|sensitivity\/run|aerodynamics\/run|jfem\/run/.test(p)));assert.deepEqual(errors,[]);
  await page.screenshot({path:path.join(out,'new-study.png')});fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,writes:await page.evaluate(()=>savedFiles.length),requests},null,2));console.log(JSON.stringify({passed:true,checks,errors},null,2));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png'),timeout:5000}).catch(()=>{});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
