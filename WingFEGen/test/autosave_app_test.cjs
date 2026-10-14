'use strict';
// Full-app regression with frozen geometry and isolated writable file handles.
// Usage: node autosave_app_test.cjs <output-dir> <fixture-dir> <playwright-module> [browser-executable]
// Fixture: schema.json (with values) and payload.msgpack from the same generated model.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [outputArg,fixtureArg,playwrightArg,browserArg]=process.argv.slice(2);
if(!outputArg||!fixtureArg||!playwrightArg){console.error('Usage: node autosave_app_test.cjs <output-dir> <fixture-dir> <playwright-module> [browser-executable]');process.exit(2);}
const web=path.resolve(__dirname,'../web'),out=path.resolve(outputArg),fixture=path.resolve(fixtureArg);
const {chromium}=require(path.resolve(playwrightArg)),M=require('../web/vendor/msgpack.min.js');
const schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'))),model=M.decode(fs.readFileSync(path.join(fixture,'payload.msgpack')));schema.defaults=structuredClone(schema.values);
const catalog={max_variables:4096,variables:[{id:'properties.t_skin_upper',label:'Upper skin thickness',value:.002,unit:'m'},{id:'properties.t_spar',label:'Spar web thickness',value:.003,unit:'m'},{id:'material.E',label:'Elastic modulus',value:70,unit:'GPa'}]};
const checks=[],errors=[],requests=[],downloads=[];let holdValidation=false,pendingValidation=null;
(async()=>{fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(browserArg?{executablePath:path.resolve(browserArg)}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1550,height:1050}}),page=await context.newPage();
try{
 context.on('page',p=>p.on('pageerror',error=>errors.push(error.stack)));page.on('pageerror',error=>errors.push(error.stack));page.on('download',d=>downloads.push(d.suggestedFilename()));
 await context.route('http://127.0.0.1:43955/**',async route=>{const url=new URL(route.request().url()),posted=route.request().method()==='POST'?route.request().postDataJSON():null;if(url.pathname.startsWith('/api/'))requests.push(url.pathname);
  if(url.pathname==='/api/input')return route.fulfill({json:schema});
  if(url.pathname==='/api/validate_workspace'){if(holdValidation)await new Promise(resolve=>pendingValidation=resolve);return route.fulfill({json:{ok:true,parameters:posted}});}
  if(['/api/generate','/api/prepare_workspace'].includes(url.pathname)){const data=M.decode(M.encode(model));data.model_params=posted;return route.fulfill({body:Buffer.from(M.encode(data)),contentType:'application/msgpack'});}
  if(url.pathname==='/api/sensitivity/catalog')return route.fulfill({json:{ok:true,catalog}});
  if(url.pathname==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
  if(url.pathname==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(url.pathname==='/api/jfem_probe')return route.fulfill({json:{found:true}});
  if(url.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{ok:false,error:'Isolated Autosave regression'}});
  return route.fulfill({path:path.join(web,url.pathname==='/'?'index.html':decodeURIComponent(url.pathname))});
 });
 const ready=async()=>{await page.waitForFunction(()=>state.autoMeshReady&&state.data&&!state.workspaceBusy&&!state.busy,null,{timeout:90000});await page.evaluate(()=>state.engine.stopRenderLoop());};
 const settled=async()=>page.waitForFunction(()=>!state.autosaveBusy&&!state.studyDirty&&!state.workspaceBusy,null,{timeout:15000});
 const edit=async(key,value)=>page.evaluate(({key,value})=>{const input=document.getElementById('p-'+key);input.value=String(value);parameterEdited(key);},{key,value});
 const color=()=>page.locator('#btn-project').getAttribute('data-saved');
 await page.goto('http://127.0.0.1:43955/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await ready();await page.locator('#auto-mesh').uncheck();
 await page.evaluate(()=>{
  window.writes=[];window.pickCalls=0;window.holdWrites=false;window.failWrites=false;window.abortCalls=0;
  window.fileHandle={name:'Autosaved-study.wingfem.json',queryPermission:async()=>"granted",requestPermission:async()=>"granted",createWritable:async()=>{let text='';return{write:async value=>{text=value;if(failWrites)throw Error('Deliberate disk write failure');if(holdWrites)await new Promise(resolve=>window.releaseWrite=resolve);},close:async()=>writes.push(text),abort:async()=>abortCalls++};}};
  window.showSaveFilePicker=async()=>{pickCalls++;return fileHandle;};
 });
 const autoBounds=await page.locator('#autosave-label').boundingBox(),liveBounds=await page.locator('#auto-mesh').boundingBox();assert(autoBounds.x<liveBounds.x);assert.equal(await color(),'false');
 await page.locator('#auto-save').check();await settled();assert.equal(await page.evaluate(()=>pickCalls),1);assert.equal(await page.evaluate(()=>writes.length),1);assert.equal(await color(),'true');
 await page.locator('#workspace-header').screenshot({path:path.join(out,'header-saved.png')});
 assert.equal(await page.evaluate(()=>JSON.parse(writes[0]).view.controls['auto-save']),true);
 checks.push('Autosave is left of Live mesh, enabling chooses a writable Study once, persists its setting and turns Project green');

 const beforeView=await page.evaluate(()=>writes.length);
 assert.equal(await page.locator('.study-comments-dialog').count(),0,'Background Autosave must not prompt for a comment');
 await page.evaluate(()=>{state.camera.alpha+=.2;markStudyViewModified();const input=document.getElementById('show-ground-plane');input.checked=!input.checked;input.dispatchEvent(new Event('change',{bubbles:true}));});
 await page.waitForTimeout(1200);assert.equal(await page.evaluate(()=>writes.length),beforeView);assert.equal(await color(),'true');
 checks.push('Camera and display-only changes neither autosave nor mark Project unsaved');

 await page.evaluate(()=>{for(const value of [.0021,.0022,.0023]){document.getElementById('p-properties.t_skin_upper').value=value;parameterEdited('properties.t_skin_upper');}});
 assert.equal(await color(),'false');await settled();assert.equal(await page.evaluate(()=>writes.length),beforeView+1);assert.equal(await page.evaluate(()=>JSON.parse(writes.at(-1)).parameters['properties.t_skin_upper']),.0023);assert.equal(await page.evaluate(()=>pickCalls),1);assert.equal(await color(),'true');
 checks.push('A burst of significant edits is coalesced into one background write with the latest definition');

 // The current geometry is frozen in this test; explicitly rebuild its identity before reading properties.
 await page.evaluate(async()=>{await createFEM({preserveView:true});activateWorkspaceTab('sensitivity');});await page.locator('#sensitivity-refresh').click();await page.waitForFunction(()=>document.querySelectorAll('#sensitivity-variables input').length===3);
 await page.locator('#sensitivity-variables input[value="properties.t_spar"]').check();await page.locator('#sensitivity-variables input[value="material.E"]').check();await page.locator('#sensitivity-target').fill('12');await settled();
 assert.deepEqual(await page.evaluate(()=>JSON.parse(JSON.parse(writes.at(-1)).parameters['sensitivity.settings']).variables),['properties.t_spar','material.E']);
 checks.push('Selected design-variable IDs and response edits are written by background Autosave');

 const [table]=await Promise.all([context.waitForEvent('page'),page.evaluate(()=>state.panelTables.open('skins'))]);await table.waitForSelector('.panel-cell input');
 await page.evaluate(()=>{holdWrites=true;document.getElementById('study-note').value='Before concurrent table edit';markStudyModified();});
 await page.waitForFunction(()=>state.autosaveBusy&&typeof releaseWrite==='function');
 const busy=await page.evaluate(()=>({inert:document.getElementById('app').inert,workspace:state.workspaceBusy,form:document.getElementById('p-properties.t_skin_upper').disabled,sensitivity:document.getElementById('sensitivity-variables').querySelector('input').disabled}));
 assert.deepEqual(busy,{inert:false,workspace:false,form:false,sensitivity:false});
 const cell=table.locator('.panel-cell input').first(),panelKey=await cell.locator('..').getAttribute('data-panel-key');await cell.fill('3.15');await cell.press('Enter');
 await page.waitForFunction(key=>JSON.parse(document.getElementById('p-properties.panels').value).some(row=>row.key===key&&row.skin?.thickness===.00315),panelKey);
 assert(await table.locator('#table-error').isHidden());assert.equal(await color(),'false');
 const beforeRelease=await page.evaluate(()=>writes.length);
 await page.evaluate(()=>{holdWrites=false;releaseWrite();releaseWrite=null;});
 await page.waitForFunction(n=>writes.length===n+1,beforeRelease);assert.equal(await page.evaluate(()=>state.studyDirty),true);assert.equal(await color(),'false');
 await settled();assert.equal(await page.evaluate(()=>writes.length),beforeRelease+2);
 assert(await page.evaluate(key=>JSON.parse(writes.at(-1)).parameters['properties.panels'].some(row=>row.key===key&&row.skin?.thickness===.00315),panelKey));
 checks.push('Background writes leave app/forms and detached property-table edits interactive; edits during writing remain orange until a second snapshot saves the latest values');

 holdValidation=true;await edit('properties.t_skin_upper',.0024);await page.waitForFunction(()=>state.autosaveBusy);while(!pendingValidation)await new Promise(resolve=>setTimeout(resolve,10));
 const oldCount=await page.evaluate(()=>writes.length);await edit('properties.t_skin_upper',.0025);holdValidation=false;pendingValidation();pendingValidation=null;await settled();
 assert.equal(await page.evaluate(()=>writes.length),oldCount+1);assert.equal(await page.evaluate(()=>JSON.parse(writes.at(-1)).parameters['properties.t_skin_upper']),.0025);
 checks.push('An edit during validation discards the obsolete snapshot before disk I/O and saves the newer definition');

 await page.evaluate(()=>{failWrites=true;document.getElementById('study-note').value='Unsaved failed write';markStudyModified();});await page.waitForFunction(()=>document.getElementById('autosave-status').dataset.status==='error');
 assert.equal(await color(),'false');assert.equal(await page.evaluate(()=>state.studyDirty),true);assert.match(await page.locator('#autosave-status').textContent(),/Deliberate disk write failure/);assert.equal(await page.evaluate(()=>abortCalls),1);
 await page.locator('#workspace-header').screenshot({path:path.join(out,'header-unsaved.png')});
 const failedCount=await page.evaluate(()=>writes.length);await page.waitForTimeout(1300);assert.equal(await page.evaluate(()=>writes.length),failedCount);
 await page.evaluate(()=>{failWrites=false;document.getElementById('study-note').value='Recovered edit';markStudyModified();});await settled();assert.equal(await color(),'true');
 checks.push('Disk errors preserve the orange unsaved state, abort the stream and avoid automatic retry loops; a subsequent edit retries successfully');
 const finalText=await page.evaluate(()=>writes.at(-1));await table.close();

 await page.reload();await page.locator('.startup-study-dialog [data-choice="open"]').click();await page.locator('.recent-studies-dialog').waitFor();await page.locator('.recent-study').filter({has:page.locator('h3',{hasText:'Autosaved-study.wingfem.json'})}).locator('.recent-study-copy').click();await page.locator('.study-comments-open').click();await ready();
 await page.waitForFunction(()=>document.querySelectorAll('#sensitivity-variables input:checked').length===2);assert.deepEqual(await page.evaluate(()=>state.sensitivity.capture().variables),['properties.t_spar','material.E']);assert.equal(await color(),'true');assert.equal(await page.locator('#auto-save').isChecked(),true);
 assert.equal(await page.evaluate(()=>document.getElementById('p-properties.t_skin_upper').value),'.0025'.replace(/^\./,'0.'));assert.equal(await page.evaluate(()=>state.studyNotes.text),'Recovered edit');
 checks.push('A fresh-page Recent Studies load restores the actual autosaved definition, selected variables, notes and enabled Autosave setting');

 // No disk-write API: background saves must use persistent browser storage, without download spam.
 await page.evaluate(()=>{window.showSaveFilePicker=undefined;state.studyFileHandle=null;state.studyFile='Browser-recovery.wingfem.json';state.studyRecentId=null;document.getElementById('study-note').value='Browser-only saved recovery';markStudyModified();});await settled();assert.equal(await color(),'true');assert.match(await page.locator('#file-save-status').textContent(),/browser recovery copy/);assert.deepEqual(downloads,[]);
 await page.reload();await page.locator('.startup-study-dialog [data-choice="open"]').click();await page.locator('.recent-studies-dialog').waitFor();await page.locator('.recent-study').filter({has:page.locator('h3',{hasText:'Browser-recovery.wingfem.json'})}).locator('.recent-study-copy').click();await page.locator('.study-comments-open').click();await ready();assert.equal(await page.evaluate(()=>state.studyNotes.text),'Browser-only saved recovery');
 checks.push('Without a file-picker API, Autosave creates a persistent browser recovery copy that survives reload and sends no downloads');

 await page.evaluate(()=>{window.showSaveFilePicker=undefined;state.studyFileHandle=null;window.originalRecord=state.recentStudies.record;state.recentStudies.record=async()=>({persisted:false});document.getElementById('study-note').value='Storage failed unsaved';markStudyModified();});await page.waitForFunction(()=>document.getElementById('autosave-status').dataset.status==='error');assert.equal(await color(),'false');assert.equal(await page.evaluate(()=>state.studyDirty),true);assert.match(await page.locator('#autosave-status').textContent(),/persistent browser copy/);assert.deepEqual(downloads,[]);
 checks.push('A non-persistent browser-copy failure cannot falsely mark the Study saved');
 assert(!requests.some(item=>['/api/run_jfem','/api/sensitivity/run'].includes(item)));assert.deepEqual(errors,[]);
 fs.writeFileSync(path.join(out,'saved-autosave.wingfem.json'),finalText);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,requests,downloads},null,2));console.log(checks.join('\n'));
}catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors,requests,downloads},null,2));await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
