'use strict';
// Replay real recovered results through full Boxer startup; synthetic stress
// samples on a real generated mesh exercise table mapping, not solver accuracy.
// node reserve_factor_table_browser_test.cjs BACKEND_FIXTURE_DIR GENERATED_MSGPACK OUTPUT_DIR PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [fixtureArg,generatedArg,outArg,modulePath='playwright']=process.argv.slice(2),fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
const {chromium}=require(modulePath),schema=JSON.parse(fs.readFileSync(path.join(fixture,'input_schema.json'),'utf8'));schema.defaults??=schema.values;
const near=(a,b)=>assert(Number.isFinite(a)&&Math.abs(a-b)<=1e-10*Math.max(1,Math.abs(b)),`${a} != ${b}`);
const read=file=>JSON.parse(fs.readFileSync(file,'utf8'));
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],requests=[];
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const context=await browser.newContext({viewport:{width:1510,height:1080},acceptDownloads:true}),page=await context.newPage();let popup;
 context.on('page',p=>p.on('pageerror',e=>errors.push(e.stack)));page.on('pageerror',e=>errors.push(e.stack));page.setDefaultTimeout(30000);
 const origin='http://127.0.0.1:43961';let scenario='sol101';
 await context.route(origin+'/**',route=>{
  const url=new URL(route.request().url());
  if(url.pathname==='/api/input')return route.fulfill({json:{...schema,ok:true,input_file:'browser-fixture.toml',units:'SI'}});
  if(url.pathname==='/api/jfem_results'){requests.push(scenario);return route.fulfill({path:path.join(fixture,scenario,'results.msgpack'),contentType:'application/msgpack'});}
  if(url.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Read-only regression replay'}});
  const file=url.pathname==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,url.pathname==='/'?'index.html':decodeURIComponent(url.pathname));
  if(!fs.existsSync(file))return route.fulfill({status:404,body:'Not found'});return route.fulfill({path:file});
 });
 try{
  await page.goto(origin+'/');await page.locator('.startup-study-dialog').waitFor();
  assert(await page.evaluate(()=>typeof WingReserveFactorTables.connect==='function'&&typeof WingReserveFactorTableData.build==='function'));
  await page.evaluate(()=>{document.querySelector('.startup-study-dialog').close();document.querySelector('.startup-study-dialog').remove();state.engine.stopRenderLoop();});
  checks.push('Full index.html/app.js startup loads the RF modules, shared engine and all normal forms without script errors.');
  for(scenario of['sol101','sol106']){
   const base=path.join(fixture,scenario),raw=read(path.join(base,'results.json')),source=read(path.join(base,'source.json'));
   const loaded=await page.evaluate(async({model,raw,source})=>{
    state.studyEpoch++;state.data=MessagePack.decode(Uint8Array.from(model));state.values=state.data.model_params;state.importedDeck={...state.data.imported_deck,source:{...source,analysis:raw.imported_analysis}};state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;buildForm(state.schema,state.values);buildModel(state.data);state.modelSignature=formSignature();state.jobSignature=state.modelSignature;state.activeCase=17;state.jobId=raw.job;setModelDirty(false);setBusy(false);markStudySaved();
    const accepted=await loadJfemResults();document.getElementById('splash').hidden=true;document.getElementById('animate').checked=false;state.autoMeshReady=true;activateWorkspaceTab('material');return{accepted,error:state.resultReadError};
   },{model:[...fs.readFileSync(path.join(base,'model.msgpack'))],raw,source});assert(loaded.accepted,JSON.stringify(loaded));
   const select=page.locator('#material-library-select');if(await select.isVisible())await select.selectOption('8');else await page.locator('#allowable-material').selectOption('8');
   await page.locator('#allowable-mode').selectOption('stress');await page.locator('#allowable-stress').fill('400000');await page.evaluate(()=>activateWorkspaceTab('stressreport'));
   if(!popup){const pending=page.waitForEvent('popup');await page.locator('#btn-reserve-factor-table').click();popup=await pending;await popup.waitForLoadState();popup.setDefaultTimeout(30000);}
   await popup.waitForFunction(()=>document.querySelectorAll('.rf-value[data-value]:not([data-value=""])').length===2);
   assert.equal(await popup.locator('#structural-group').inputValue(),'all');assert.equal(await popup.locator('#table-view').inputValue(),'flat');assert(await popup.locator('#table-view option[value="grid"]').evaluate(o=>o.disabled));
   for(const row of await page.evaluate(()=>state.stressReport.report.rows))near(Number(await popup.locator('.rf-value[data-pid="'+row.pid+'"]').getAttribute('data-value')),row.reserveFactor);
   assert.match(await popup.locator('#reserve-factor-table thead').textContent(),/source stress units/);
   assert.match(await popup.locator('#rf-limits').textContent(),/Fixed color limits 0 to 2/);assert.deepEqual(await popup.locator('#rf-ticks span').allTextContents(),['0','1','2']);
   const high=popup.locator('.rf-high-number').first();if(await high.count())assert.equal(await high.evaluate(el=>getComputedStyle(el).color),'rgb(150, 62, 0)');
   const paletteValues=await popup.locator('#table-palette option').evaluateAll(nodes=>nodes.map(n=>n.value));assert.deepEqual(paletteValues,['signed','spectrum','viridis','inferno','coolwarm','grayscale']);
   for(const value of paletteValues){await popup.locator('#table-palette').selectOption(value);assert(await popup.locator('#rf-ramp').evaluate(el=>!!el.style.background));}await popup.locator('#table-palette').selectOption('signed');
   await page.locator('#stress-report-palette').selectOption('spectrum');assert(await page.locator('.stress-report-colorbar').evaluate(el=>el.style.background.includes('linear-gradient')));
   await page.locator('#stress-report-case').selectOption('17');await popup.waitForFunction(()=>!document.querySelector('#case-scope').textContent.includes('All eligible'));
   for(const method of['maximum','mean','trimmed_mean']){
    await page.locator('#stress-report-method').selectOption(method);await popup.waitForFunction(expected=>document.querySelector('#envelope-method').textContent.includes(expected),{maximum:'Maximum',mean:'Average',trimmed_mean:'Average below percentile'}[method]);
    const rows=await page.evaluate(()=>state.stressReport.report.rows);for(const row of rows)await popup.waitForFunction(({pid,value})=>Math.abs(Number(document.querySelector('.rf-value[data-pid="'+pid+'"]').dataset.value)-value)<1e-10*Math.max(1,value),{pid:row.pid,value:row.reserveFactor});
   }
   await page.evaluate(()=>activateWorkspaceTab('material'));if(await select.isVisible())await select.selectOption('8');else await page.locator('#allowable-material').selectOption('8');await page.locator('#allowable-stress').fill('200000');
   const updated=await page.evaluate(()=>state.stressReport.report.rows);for(const row of updated)await popup.waitForFunction(({pid,value})=>Number(document.querySelector('.rf-value[data-pid="'+pid+'"]').dataset.value)===value,{pid:row.pid,value:row.reserveFactor});
   for(const format of['csv','markdown','html']){const pending=popup.waitForEvent('download');await popup.locator('#export-'+format).click();const download=await pending,file=path.join(out,scenario+'-'+download.suggestedFilename());await download.saveAs(file);const text=fs.readFileSync(file,'utf8');assert.match(text,/Reserve factor/i);assert(text.includes('101')&&text.includes('202'));assert(text.includes('source stress units'));assert(text.includes('Average below percentile'));}
   await popup.screenshot({path:path.join(out,scenario+'-imported-property-list.png')});
   checks.push(scenario+': real recovered result RFs match the parent report, source units remain explicit, case/statistic/allowable changes update the detached window while the report tab is inactive, and all three exports retain provenance.');
   const beforeEdit=await page.evaluate(()=>state.stressReport.report.rows.map(row=>({pid:row.pid,rf:row.reserveFactor})));
   await page.evaluate(()=>{state.modelDirty=true;refreshStressReport();});await popup.waitForFunction(()=>document.getElementById('connection').textContent.includes('Model and results are not in sync.'));assert.equal(await popup.locator('.rf-value[data-value]:not([data-value=""])').count(),2);
   assert.deepEqual(await page.evaluate(()=>state.stressReport.report.rows.map(row=>({pid:row.pid,rf:row.reserveFactor}))),beforeEdit);assert.equal(await page.locator('#stress-report-stale').evaluate(node=>node.hidden),false);assert.equal(await page.evaluate(()=>state.stressReport.report.stale),true);assert(await page.locator('#stress-report-show-field').isDisabled());
   await page.evaluate(()=>{state.modelDirty=false;refreshStressReport();});await popup.waitForFunction(()=>!document.getElementById('connection').textContent.includes('not in sync'));assert.equal(await popup.locator('.rf-value[data-value]:not([data-value=""])').count(),2);
   checks.push(scenario+': unsolved edits retain unchanged historical RFs with a mismatch warning; current 3D fields remain disabled until the solved definition matches again.');
   await page.evaluate(()=>activateWorkspaceTab('stressreport'));await page.locator('#stress-report-case').selectOption('all');
  }
  const generated=await page.evaluate(model=>{
   state.studyEpoch++;state.importedDeck=null;state.data=MessagePack.decode(Uint8Array.from(model));state.values=state.data.model_params;state.values['output.solution']=101;buildForm(state.schema,state.values);buildModel(state.data);state.modelSignature=formSignature();state.jobSignature=state.modelSignature;setModelDirty(false);setBusy(false);
   const properties=[...new Set([...state.elements.values()].map(e=>Number(e.group.pid)).filter(Number.isFinite))].sort((a,b)=>a-b),mats=WingMaterialAllowables.materialsFromGroups(state.data.groups).filter(m=>m.type==='MAT1');state.values['materials.allowables']=mats.map(m=>({material_id:m.id,mode:'stress',stress:300e6}));document.getElementById('p-materials.allowables').value=JSON.stringify(state.values['materials.allowables']);
   const results={};for(const[eid,e]of state.elements){const i=properties.indexOf(Number(e.group.pid)),v=[600e6,300e6,150e6,240e6][i%4];results[eid]={stress:{z1:{von_mises:v},z2:{von_mises:v*.5}}};}
   state.resultCases=new Map(modelCases().map(c=>[Number(c.id),{analysis:'SOL101_STATIC',available:true,status:'complete',matches:true,static:{},signature:state.modelSignature,meshIdentity:state.meshIdentity,elementResults:results}]));
   state.allowablesEditor?.refresh();activateWorkspaceTab('stressreport');state.stressReport.invalidate();refreshStressReport();
   return{panels:state.data.stiffened_panels?.panels.length,groups:WingReserveFactorTableData.build({...stressReportContext(),report:state.stressReport.report}).groups,report:state.stressReport.report};
  },[...fs.readFileSync(generatedArg)]);
  assert(generated.panels>0);assert(generated.groups.some(g=>g.id==='upper'));assert(generated.groups.some(g=>g.id==='sparwebs'));
  await popup.waitForFunction(()=>document.querySelector('#structural-group option[value="upper"]'));
  await popup.locator('#structural-group').selectOption('upper');await popup.waitForFunction(()=>document.querySelector('#table-view').value==='grid');
  assert.equal(await popup.locator('.shared-heading').count(),0,'Unique panel properties must not become shared merely because their display groups have family names.');
  await popup.evaluate(()=>{window.receivedSnapshots=0;addEventListener('message',event=>{if(event.data?.type==='snapshot'&&event.source===opener)window.receivedSnapshots++;});});
  await page.locator('#stress-report-search').fill('P');await page.locator('#stress-report-reserve').click();await page.locator('#stress-report-search').fill('');await popup.waitForTimeout(80);assert.equal(await popup.evaluate(()=>window.receivedSnapshots),0,'Parent table filtering must not resend identical report data.');
  const colors=await popup.locator('.rf-value[data-value]:not([data-value=""])').evaluateAll(nodes=>nodes.map(n=>({pid:n.dataset.pid,value:Number(n.dataset.value),text:n.textContent,color:getComputedStyle(n).backgroundColor,state:n.dataset.state,minimumGauge:n.dataset.minimumGauge==='true'})));
  assert(colors.some(c=>c.value<1)&&colors.some(c=>c.value>1));for(const c of colors){assert.equal(c.text,Number(c.value.toPrecision(5)).toString());const rgb=c.color.match(/[\d.]+/g).map(Number);if(c.value<1)assert(rgb[0]>rgb[2]);else if(c.value>1&&c.minimumGauge)assert.deepEqual(rgb,[255,222,89]);else if(c.value>1)assert(rgb[2]>rgb[0]);else assert.equal(c.state,'threshold');}
  assert.match(await popup.locator('#rf-legend').textContent(),/dimensionless/);assert.match(await popup.locator('#reserve-factor-table thead').textContent(),/R1.R2/);
  await popup.screenshot({path:path.join(out,'generated-upper-grid-dark.png')});await popup.locator('#theme-button').click();await popup.screenshot({path:path.join(out,'generated-upper-grid-light.png')});
  for(const group of generated.groups.filter(g=>g.id!=='all')){await popup.locator('#structural-group').selectOption(group.id);assert(await popup.locator('#reserve-factor-table tbody tr').count()>0);}
  await popup.locator('#structural-group').selectOption('sparwebs');await popup.screenshot({path:path.join(out,'generated-spar-web-grid.png')});
  checks.push('Actual generated lifting-surface panel/component ownership produces structural grids; deliberately synthetic stress samples exercise red RF<1, neutral RF=1, blue RF>1 with minimum-gauge yellow, five-significant-digit display and available structural groups.');
  // A property reused in two panels must retain one full-region result.
  await page.evaluate(()=>{const panels=state.data.stiffened_panels.panels,first=panels.find(p=>p.skin==='upper');state.data.stiffened_panels={...state.data.stiffened_panels,panels:[...panels,{...first,id:99999,key:'shared-regression',rib_bay:999}]};refreshStressReport();});
  await popup.locator('#structural-group').selectOption('upper');await popup.waitForFunction(()=>document.querySelector('.shared-heading'));
  assert(await popup.locator('.rf-value').filter({hasText:'Shared property'}).count()>=2);assert(await popup.locator('.shared-note').count()>0);
  await popup.screenshot({path:path.join(out,'generated-shared-property.png')});
  const before=await popup.locator('#table-count').textContent();await popup.evaluate(()=>window.postMessage({channel:'JFEM-Boxer.reserve-factor-table.v1',token:location.hash.slice(1),type:'snapshot',snapshot:{report:{rows:[]}}},location.origin));await popup.waitForTimeout(50);assert.equal(await popup.locator('#table-count').textContent(),before);
  checks.push('A shared property is never duplicated as independent bay results; untrusted same-origin messages cannot replace the report.');
  await popup.setViewportSize({width:780,height:850});await popup.screenshot({path:path.join(out,'generated-grid-narrow.png')});
  await page.close();await popup.waitForFunction(()=>document.querySelector('#connection').textContent.includes('disconnected'));assert(await popup.locator('#export-csv').isEnabled());
  checks.push('Closing the parent keeps the last received table available for export with an explicit disconnected notice.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,requests,colors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors,requests},null,2));if(!page.isClosed())await page.screenshot({path:path.join(out,'failure-main.png')});if(popup&&!popup.isClosed())await popup.screenshot({path:path.join(out,'failure-table.png')});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
