'use strict';
// Isolated actual-app replay; no user browser and no new aerodynamic solve.
// node TEST OUT FIXTURE RESULT_JSON PLAYWRIGHT [BROWSER]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,fixtureArg,resultArg,pwArg,browserArg]=process.argv.slice(2),out=path.resolve(outArg),fixture=path.resolve(fixtureArg),web=path.resolve(__dirname,'../web');
const{chromium}=require(path.resolve(pwArg)),native=JSON.parse(fs.readFileSync(resultArg,'utf8')),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));
schema.defaults=JSON.parse(fs.readFileSync(path.join(fixture,'params.json'),'utf8'));
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(browserArg?{executablePath:browserArg}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader','--disable-gpu-compositing']});
 const page=await browser.newPage({viewport:{width:1600,height:1000}}),errors=[],checks=[],requests=[];let signature='';
 page.setDefaultTimeout(25000);page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.route('http://127.0.0.1:43987/**',async route=>{
   const u=new URL(route.request().url());
   if(u.pathname==='/api/input')return route.fulfill({json:schema});
   if(u.pathname==='/api/validate_workspace')return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
   if(['/api/generate','/api/prepare_workspace'].includes(u.pathname))return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});
   if(u.pathname==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
   if(u.pathname==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
   if(u.pathname==='/api/jfem_probe')return route.fulfill({json:{found:true}});
   if(u.pathname==='/api/aerodynamics/run'){const body=route.request().postDataJSON();requests.push(body);signature=body.signature;return route.fulfill({json:{id:'sweep-warning-'+requests.length}});}
   if(u.pathname==='/api/aerodynamics/status')return route.fulfill({json:{state:'done',seconds:0}});
   if(u.pathname==='/api/aerodynamics/results')return route.fulfill({json:{...native,signature}});
   if(u.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated sweep UI test'}});
   const file=u.pathname.startsWith('/shared/')?path.join(web,'../..',u.pathname.slice(8)):path.join(web,u.pathname==='/'?'index.html':decodeURIComponent(u.pathname));
   return fs.existsSync(file)?route.fulfill({path:file}):route.fulfill({status:404,body:'Missing fixture asset'});
  });
  await page.goto('http://127.0.0.1:43987/');await page.waitForFunction(()=>state.schema?.length);
  await page.evaluate(()=>{for(const d of document.querySelectorAll('dialog[open]'))d.close();state.autosave?.destroy();state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();activateWorkspaceTab('aerostudy');});
  const header=await page.evaluate(()=>{const info=document.getElementById('btn-aero-information'),actions=document.querySelector('.aero-header-actions'),first=actions.firstElementChild,r=info.getBoundingClientRect(),a=first.getBoundingClientRect(),exports=document.querySelector('[data-aero-pane=exports]').getBoundingClientRect(),estimate=document.querySelector('.aero-work-estimate').getBoundingClientRect();return{sameParent:actions.parentElement===info.parentElement,actionsRight:a.left>=r.right,aligned:Math.abs((r.top+r.bottom)/2-(a.top+a.bottom)/2)<3,estimateRight:estimate.left>=exports.right};});
  assert.deepEqual(header,{sameParent:true,actionsRight:true,aligned:true,estimateRight:true});checks.push('Primary commands share the title/help row; work estimate follows Exports.');
  await page.locator('[data-aero-field=mode]').selectOption('sweep');await page.getByRole('button',{name:'Add sweep variable',exact:true}).click();
  for(const[key,value]of [['start','0'],['end','1'],['step','0.3']]){await page.getByLabel('Sweep 1 '+key,{exact:true}).fill(value);await page.getByLabel('Sweep 1 '+key,{exact:true}).dispatchEvent('change');}
  assert.match(await page.locator('.aero-sweep-summary').innerText(),/5 conditions.*1\.2/);assert.match(await page.locator('.aero-work-estimate').innerText(),/5 conditions/);
  assert.deepEqual(await page.evaluate(()=>state.aerodynamicStudy.capture().settings.sweeps),[{variable:'alpha',start:0,stop:1,step:.3}]);checks.push('Start/End/Step inputs include the first condition past a non-dividing endpoint and persist without count.');
  await page.locator('[data-aero-field=derivatives]').check();await page.locator('[data-action=run]').click();
  await page.locator('[data-aero-derivative-warning]').waitFor();await page.screenshot({path:path.join(out,'derivative-warning.png')});assert.equal(requests.length,0);assert.equal(await page.locator('[data-derivative-choice=cancel]').evaluate(el=>el===el.ownerDocument.activeElement),true);
  assert.match(await page.locator('[data-aero-derivative-warning]').innerText(),/80 VLM evaluations.*85 total/);await page.locator('[data-derivative-choice=cancel]').click();assert.equal(requests.length,0);assert(await page.locator('[data-aero-field=derivatives]').isChecked());
  await page.locator('[data-action=run]').click();await page.keyboard.press('Escape');assert.equal(requests.length,0);assert(await page.locator('[data-aero-field=derivatives]').isChecked());checks.push('Cancel is focused by default; Cancel and Escape send no analysis request and preserve derivatives.');
  await page.locator('[data-action=run]').click();await page.locator('[data-derivative-choice=continue]').click();await page.waitForFunction(()=>state.aerodynamicStudy.result&&!state.aerodynamicStudy.busy);assert.equal(requests.length,1);assert.equal(requests[0].settings.derivatives,true);checks.push('Run with derivatives explicitly preserves and submits the requested derivative sweep.');
  await page.locator('[data-action=run]').click();await page.locator('[data-aero-derivative-warning]').waitFor();await page.evaluate(()=>state.studyDirty=false);await page.locator('[data-derivative-choice=disable]').click();await page.waitForFunction(()=>!state.aerodynamicStudy.busy&&state.aerodynamicStudy.capture().settings.derivatives===false);assert.equal(requests.length,2);assert.equal(requests[1].settings.derivatives,false);assert.equal(await page.evaluate(()=>state.studyDirty),true);assert(!(await page.locator('[data-aero-field=derivatives]').isChecked()));checks.push('Each derivative sweep warns again; Disable derivatives and run updates the persisted definition, marks it dirty and submits no derivatives.');
  await page.getByLabel('Sweep 1 step',{exact:true}).fill('-0.3');await page.getByLabel('Sweep 1 step',{exact:true}).dispatchEvent('change');await page.locator('[data-action=run]').click();assert.equal(requests.length,2);assert.match(await page.locator('.aero-status').innerText(),/negative step|towards End/);checks.push('Invalid step direction is explained without submitting a job.');
  await page.evaluate(()=>{const saved=state.aerodynamicStudy.capture();saved.settings.sweeps[0].step=.3;state.aerodynamicStudy.restore(saved);});await page.locator('[data-aero-field=derivatives]').check();await page.locator('[data-action=run]').click();await page.locator('[data-aero-derivative-warning]').waitFor();await page.evaluate(()=>state.aerodynamicStudy.restore(state.aerodynamicStudy.capture()));await page.waitForFunction(()=>!document.querySelector('[data-aero-derivative-warning]'));assert.equal(requests.length,2);checks.push('Restoring another workspace cancels an outstanding derivative warning without running the old definition.');
  const legacy=[{variable:'alpha',start:-5,stop:10,count:15},{variable:'beta',start:-2,stop:2,count:10}];
  await page.evaluate(sweeps=>{const saved=state.aerodynamicStudy.capture();saved.settings.sweeps=sweeps;saved.settings.derivatives=true;state.aerodynamicStudy.restore(saved);},legacy);assert.deepEqual(await page.evaluate(()=>state.aerodynamicStudy.capture().settings.sweeps),legacy);assert.match(await page.locator('.aero-work-estimate').innerText(),/150 conditions/);checks.push('Legacy saved count-based sweeps restore without changing their definition or exact original condition counts.');
  const popupEvent=page.waitForEvent('popup');await page.locator('[data-action=detach]').click();const popup=await popupEvent;popup.on('pageerror',e=>errors.push(e.message));
  assert.equal(await popup.locator('.aero-heading>.aero-header-actions').count(),1);await popup.locator('[data-action=run]').click();await popup.locator('[data-derivative-choice=cancel]').click();assert.equal(requests.length,2);await popup.locator('[data-action=detach]').click();await page.waitForFunction(()=>!state.aerodynamicStudy.detached);assert.equal(await page.locator('#sidebar>.panel-heading>.aero-header-actions').count(),1);checks.push('Detached workspace retains title-row controls and warning behavior; Return restores live controls to the main header.');
  await page.getByLabel('Sweep 1 step',{exact:true}).scrollIntoViewIfNeeded();await page.screenshot({path:path.join(out,'sweep-wide.png')});
  for(const width of [1000,700]){await page.setViewportSize({width,height:950});await page.waitForTimeout(150);const bounds=await page.locator('.aero-header-actions').evaluate(el=>{const r=el.getBoundingClientRect();return{left:r.left,right:r.right,width:innerWidth,children:[...el.children].map(b=>{const q=b.getBoundingClientRect();return{left:q.left,right:q.right};})};});assert(bounds.left>=0&&bounds.right<=bounds.width+1);for(const b of bounds.children)assert(b.left>=bounds.left-1&&b.right<=bounds.right+1);await page.screenshot({path:path.join(out,'sweep-'+width+'.png')});}
  checks.push('Title-row commands wrap within the workspace at 1600, 1000 and 700 pixel widths.');assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,requests:requests.map(r=>({derivatives:r.settings.derivatives,sweeps:r.settings.sweeps}))},null,2));console.log(JSON.stringify({passed:true,checks,errors},null,2));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure.png'),timeout:5000}).catch(()=>{});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
