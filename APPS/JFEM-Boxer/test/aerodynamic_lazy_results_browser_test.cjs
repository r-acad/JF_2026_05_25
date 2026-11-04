'use strict';
// Isolated native-result replay: no user browser or new aerodynamic solve.
// node aerodynamic_lazy_results_browser_test.cjs OUT BOOTSTRAP RESULT_JSON PLAYWRIGHT [BROWSER]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,fixtureArg,resultArg,pwArg,browserArg]=process.argv.slice(2),out=path.resolve(outArg),fixture=path.resolve(fixtureArg),web=path.resolve(__dirname,'../web');
const{chromium}=require(path.resolve(pwArg)),native=JSON.parse(fs.readFileSync(resultArg,'utf8')),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));
schema.defaults=JSON.parse(fs.readFileSync(path.join(fixture,'params.json'),'utf8'));
const baseline=process.env.AERO_CAPTURE_BASELINE==='1';
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(browserArg?{executablePath:browserArg}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader','--disable-gpu-compositing']});
 const page=await browser.newPage({viewport:{width:1600,height:1000}}),errors=[],checks=[];let signature='';
 page.setDefaultTimeout(25000);page.on('pageerror',e=>errors.push(e.message));
 const count=()=>page.evaluate(()=>({charts:document.querySelectorAll('.aero-chart').length,tables:document.querySelectorAll('.aero-drawer table').length,resultTables:document.querySelectorAll('.aero-coefficients table,.aero-derivatives table').length,calls:window.aeroProfile.calls,milliseconds:window.aeroProfile.ms}));
 const pane=key=>page.locator('[data-aero-pane="'+key+'"]').click();
 try{
  await page.route('http://127.0.0.1:43987/**',async route=>{
   const u=new URL(route.request().url());
   if(u.pathname==='/api/input')return route.fulfill({json:schema});
   if(u.pathname==='/api/validate_workspace')return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
   if(['/api/generate','/api/prepare_workspace'].includes(u.pathname))return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});
   if(u.pathname==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
   if(u.pathname==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
   if(u.pathname==='/api/jfem_probe')return route.fulfill({json:{found:true}});
   if(u.pathname==='/api/aerodynamics/run'){signature=route.request().postDataJSON().signature;return route.fulfill({json:{id:'lazy-results'}});}
   if(u.pathname==='/api/aerodynamics/status')return route.fulfill({json:{state:'done',seconds:0}});
   if(u.pathname==='/api/aerodynamics/results')return route.fulfill({json:{...native,signature}});
   if(u.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated lazy-results replay'}});
   const file=u.pathname.startsWith('/shared/')?path.join(web,'../..',u.pathname.slice(8)):path.join(web,u.pathname==='/'?'index.html':decodeURIComponent(u.pathname));
   return fs.existsSync(file)?route.fulfill({path:file}):route.fulfill({status:404,body:'Missing fixture asset'});
  });
  await page.goto('http://127.0.0.1:43987/');await page.waitForFunction(()=>state.schema?.length);
  await page.evaluate(()=>{
   for(const d of document.querySelectorAll('dialog[open]'))d.close();state.autosave?.destroy();state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();activateWorkspaceTab('aerostudy');
   window.aeroProfile={calls:{},ms:{}};
   for(const[label,api,keys]of [['plots',WingAerodynamicPlots,['svg','sweepPlots']],['derivatives',WingAerodynamicDerivatives,['rows','plots']]])for(const key of keys){const original=api[key];api[key]=function(...args){const name=label+'.'+key,t=performance.now();window.aeroProfile.calls[name]=(window.aeroProfile.calls[name]||0)+1;try{return original.apply(this,args);}finally{window.aeroProfile.ms[name]=(window.aeroProfile.ms[name]||0)+performance.now()-t;}};}
  });
  if(!baseline){
   assert(!(await page.locator('[data-aero-field=derivatives]').isChecked()));assert.match(await page.locator('.aero-work-estimate').innerText(),/1 condition.*derivatives off/i);
   await page.evaluate(()=>{window.beforeAeroEdits=state.aerodynamicStudy.capture();state.studyDirty=false;state.studyRevision=0;});
   await page.getByLabel('Aerodynamic contour',{exact:true}).selectOption('delta_pressure_Pa');assert.equal(await page.evaluate(()=>state.studyDirty),false,'Display preferences do not dirty the Study definition.');
   await page.locator('[data-aero-field=speed]').fill('71');await page.locator('[data-aero-field=speed]').dispatchEvent('change');assert.equal(await page.evaluate(()=>state.studyDirty),true,'Aerodynamic definition edits must mark the Study unsaved.');
   await page.evaluate(()=>{state.studyDirty=false;state.aerodynamicStudy.restore(window.beforeAeroEdits);});assert.equal(await page.evaluate(()=>state.studyDirty),false,'Restoring saved settings must establish a clean definition baseline.');assert.equal(await page.evaluate(()=>state.aerodynamicStudy.capture().settings.speed),70,'A focused old input must not overwrite restored settings.');
   checks.push('Aerodynamic definition changes mark the Study unsaved; display changes and saved-state restore remain clean.');
  }
  const started=Date.now();await page.locator('[data-action=run]').click();await page.waitForFunction(()=>state.aerodynamicStudy.result&&!state.aerodynamicStudy.busy);
  const completed=await count(),elapsed=Date.now()-started;checks.push('Replayed two native solved conditions without a solver job.');
  await page.getByRole('button',{name:'Close aerodynamic status',exact:true}).click();
  if(baseline){fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({baseline:true,elapsed_ms:elapsed,completed,errors},null,2));console.log(JSON.stringify({baseline:true,elapsed_ms:elapsed,completed,errors}));return;}
  assert.equal(completed.charts,0);assert.equal(completed.resultTables,0);assert.deepEqual(completed.calls,{});checks.push('Completion builds no hidden result table or SVG.');
  await page.evaluate(()=>{window.domainReads=0;for(const panel of state.aerodynamicStudy.result.cases[0].panels){const value=panel.delta_pressure_Pa;Object.defineProperty(panel,'delta_pressure_Pa',{enumerable:true,get(){window.domainReads++;return value;}});}});
  await page.getByLabel('Aerodynamic contour',{exact:true}).selectOption('delta_pressure_Pa');await page.evaluate(()=>window.domainReads=0);
  await page.getByLabel('Case A',{exact:true}).selectOption('1');assert.equal(await page.evaluate(()=>window.domainReads),0,'A cached common domain must not rescan the unselected condition.');
  await pane('display');await page.getByLabel('Minimum aerodynamic color-scale limit',{exact:true}).fill('-1');await page.getByLabel('Minimum aerodynamic color-scale limit',{exact:true}).dispatchEvent('change');
  await page.getByLabel('Maximum aerodynamic color-scale limit',{exact:true}).fill('1');await page.getByLabel('Maximum aerodynamic color-scale limit',{exact:true}).dispatchEvent('change');assert.equal(await page.locator('[data-scale=min]').innerText(),'-1');assert.equal(await page.locator('[data-scale=max]').innerText(),'1');
  await page.getByRole('button',{name:'Close aerodynamic panel',exact:true}).click();checks.push('Automatic common color domains are cached across selected-case changes; manual limits update immediately.');
  await pane('distributions');const shown=await count();assert(shown.charts>=11);const beforeCase=shown.calls['plots.svg'];
  await page.getByRole('button',{name:'Close aerodynamic panel',exact:true}).click();await page.getByLabel('Case A',{exact:true}).selectOption('0');
  assert.equal((await count()).calls['plots.svg'],beforeCase,'Changing case with every result pane closed must not build charts.');
  await pane('distributions');assert((await count()).calls['plots.svg']>beforeCase);const current=await count();
  await page.getByRole('button',{name:'Close aerodynamic panel',exact:true}).click();await pane('distributions');assert.deepEqual((await count()).calls,current.calls,'Opening a clean pane must reuse its contents.');
  checks.push('Result panes populate on first visit, refresh for their selected condition and reuse unchanged contents.');
  await page.getByRole('button',{name:'Close aerodynamic panel',exact:true}).click();await pane('coefficients');assert(await page.locator('.aero-case-table').isVisible());assert.equal(await page.locator('.aero-all-coefficients-table').count(),0);
  await page.locator('.aero-all-coefficients > summary').click();assert.equal(await page.locator('.aero-all-coefficients-table').count(),1);
  const prior=await count();await page.getByRole('button',{name:'Close aerodynamic panel',exact:true}).click();await page.getByLabel('Case A',{exact:true}).selectOption('0');await pane('sweeps');assert((await count()).calls['plots.svg']>prior.calls['plots.svg']);
  const sweepCount=(await count()).calls['plots.svg'];await page.getByLabel('Case A',{exact:true}).selectOption('1');assert.equal((await count()).calls['plots.svg'],sweepCount,'Sweep plots cover all conditions and must not rebuild for a selected-case change.');
  checks.push('Closed all-coefficients details remain unbuilt; all-case sweep plots survive selected-case changes.');
  await page.getByRole('button',{name:'Close aerodynamic panel',exact:true}).click();await pane('coefficients');
  const popupEvent=page.waitForEvent('popup');await page.locator('[data-action=detach]').click();const popup=await popupEvent;popup.on('pageerror',e=>errors.push(e.message));
  await popup.getByLabel('Coefficient frame',{exact:true}).selectOption('body');assert(await popup.locator('.aero-case-table').isVisible());await popup.locator('[data-action=detach]').click();await page.waitForFunction(()=>!state.aerodynamicStudy.detached);
  await page.getByLabel('Coefficient frame',{exact:true}).selectOption('wind');assert.equal(await page.evaluate(()=>state.aerodynamicStudy.capture().frame),'wind');
  checks.push('A populated result pane remains interactive through detachment and return; hidden panes are rebuilt only on demand.');
  await page.getByRole('button',{name:'Close aerodynamic panel',exact:true}).click();await pane('setup');await page.locator('[data-aero-field=derivatives]').check();
  await page.locator('[data-aero-field=mode]').selectOption('sweep');
  await page.evaluate(()=>{const saved=state.aerodynamicStudy.capture();saved.settings.sweeps=[{variable:'alpha',start:-5,stop:10,count:15},{variable:'beta',start:-2,stop:2,count:10}];state.aerodynamicStudy.restore(saved);});
  assert(await page.locator('[data-aero-field=derivatives]').isChecked());assert.match(await page.locator('.aero-work-estimate').innerText(),/150 conditions/);assert.match(await page.locator('.aero-work-estimate').innerText(),/additional/);
  checks.push('Explicit saved derivative requests persist and Cartesian sweep work is visible before running.');
  assert.deepEqual(errors,[]);const final=await count();await page.screenshot({path:path.join(out,'work-estimate.png')});fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,elapsed_ms:elapsed,completed,final,checks,errors},null,2));console.log(JSON.stringify({passed:true,elapsed_ms:elapsed,completed,final,checks,errors},null,2));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure.png'),timeout:5000}).catch(()=>{});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
