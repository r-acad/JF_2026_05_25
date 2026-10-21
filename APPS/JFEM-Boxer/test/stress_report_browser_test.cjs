'use strict';
// Real SOL101/SOL106 recovery replay through Boxer. This does not start a solver.
// node stress_report_browser_test.cjs BACKEND_FIXTURE_DIR OUTPUT_DIR PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [fixtureArg,outArg,modulePath='playwright']=process.argv.slice(2),fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
const {chromium}=require(modulePath),schema=JSON.parse(fs.readFileSync(path.join(fixture,'input_schema.json'),'utf8'));schema.defaults??=schema.values;
const near=(a,b)=>assert(Number.isFinite(a)&&Math.abs(a-b)<=1e-10*Math.max(1,Math.abs(b)),`${a} != ${b}`);
const precision=value=>Number(value.toPrecision(5)).toString();
const readJSON=file=>JSON.parse(fs.readFileSync(file,'utf8'));
function expectedValues(raw,ownership,method,selected='all'){
 const output=[];
 for(const [pid,eids]of ownership){let maximum=-Infinity,envelope=-Infinity,governing=null;
  for(const c of raw.load_cases.filter(c=>selected==='all'||c.id===Number(selected))){
   const values=eids.map(eid=>Math.max(c.element_results[eid].stress.z1.von_mises,c.element_results[eid].stress.z2.von_mises)).sort((a,b)=>a-b);
   let kept=values;
   if(method==='trimmed_mean'){const rank=(values.length-1)*.95,i=Math.floor(rank),cut=values[i]+(values[Math.ceil(rank)]-values[i])*(rank-i);kept=values.filter(v=>v<=cut||v-cut<=16*Number.EPSILON*Math.max(Math.abs(v),Math.abs(cut)));}
   const peak=values.at(-1),stat=method==='maximum'?peak:kept.reduce((sum,v)=>sum+v,0)/kept.length;maximum=Math.max(maximum,peak);if(stat>envelope){envelope=stat;governing=c.id;}
  }
  output.push({pid,maximum,envelope,governing});
 }
 return output;
}
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],observed=[],requests=[];
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 try{
  for(const scenario of ['sol101','sol106']){
   const context=await browser.newContext({viewport:{width:1510,height:1080},acceptDownloads:true}),page=await context.newPage();page.setDefaultTimeout(30000);page.on('pageerror',e=>errors.push(e.stack));
   const base=path.join(fixture,scenario),raw=readJSON(path.join(base,'results.json')),source=readJSON(path.join(base,'source.json')),ownership=new Map();for(const [,eid,pid]of source.text.matchAll(/^CQUAD4,(\d+),(\d+),/gm)){if(!ownership.has(Number(pid)))ownership.set(Number(pid),[]);ownership.get(Number(pid)).push(Number(eid));}
   const html=fs.readFileSync(path.join(web,'index.html'),'utf8'),origin='http://127.0.0.1:43957';
   try{
    await page.route(origin+'/**',route=>{const url=new URL(route.request().url());if(url.pathname==='/api/jfem_results'){requests.push({scenario,path:url.pathname});return route.fulfill({path:path.join(base,'results.msgpack'),contentType:'application/msgpack'});}if(url.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Read-only replay'}});if(url.pathname==='/')return route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')});return route.fulfill({path:url.pathname==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,url.pathname)});});
    await page.goto(origin+'/');
    for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
    for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:file==='shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,file)});
    const app=fs.readFileSync(path.join(web,'app.js'),'utf8'),cut=app.indexOf('(async function start()');assert(cut>0);await page.addScriptTag({content:app.slice(0,cut)});
    const loaded=await page.evaluate(async({model,payload,schema,source})=>{
     initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.defaults=schema.defaults;state.data=MessagePack.decode(Uint8Array.from(model));state.values=state.data.model_params;
     state.importedDeck={...state.data.imported_deck,source:{...source,analysis:payload.imported_analysis}};state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;
     buildForm(state.schema,state.values);buildModel(state.data);state.modelSignature=formSignature();state.jobSignature=state.modelSignature;state.activeCase=17;state.jobId=payload.job;setModelDirty(false);setBusy(false);markStudySaved();
     const accepted=await loadJfemResults();document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;document.getElementById('animate').checked=false;
     activateWorkspaceTab('material');return{accepted,error:state.resultReadError,active:workspaceUI.activeTab,cases:[...state.resultCases].map(([id,r])=>({id,analysis:r.analysis,matches:r.matches,issues:r.validationIssues}))};
    },{model:[...fs.readFileSync(path.join(base,'model.msgpack'))],payload:raw,schema,source});assert(loaded.accepted,JSON.stringify(loaded));assert.equal(loaded.error,'');assert(loaded.cases.every(c=>c.matches));
    const materialSelect=page.locator('#material-library-select');if(await materialSelect.isVisible())await materialSelect.selectOption('8');else await page.locator('#allowable-material').selectOption('8');
    await page.locator('#allowable-mode').selectOption('stress');await page.locator('#allowable-stress').fill('400000');
    const signature=await page.evaluate(()=>formSignature());
    await page.evaluate(()=>activateWorkspaceTab('stressreport'));assert(await page.locator('#panel-stressreport').isVisible());
    const all=[];
    for(const method of ['maximum','mean','trimmed_mean']){
     await page.locator('#stress-report-method').selectOption(method);if(method==='trimmed_mean'){await page.locator('#stress-report-percentile').fill('95');await page.locator('#stress-report-percentile').blur();}
     for(const selected of ['all','17','42']){
      await page.locator('#stress-report-case').selectOption(selected);const report=await page.evaluate(()=>state.stressReport.report);assert.equal(report.complete,true,JSON.stringify(report.excludedCases));assert.equal(report.rows.length,2);assert.equal(report.stressUnit,'source stress units');
      for(const expected of expectedValues(raw,ownership,method,selected)){const row=report.rows.find(r=>r.pid===expected.pid);near(row.maxStress,expected.maximum);near(row.envelopeStress,expected.envelope);near(row.reserveFactor,400000/expected.envelope);assert(row.envelopeCaseKey.startsWith(expected.governing+':'));const cells=await page.locator('#stress-report-table tbody tr[data-pid="'+row.pid+'"] td').allTextContents();assert(cells.includes(precision(expected.maximum)));assert(cells.includes(precision(expected.envelope)));}
      all.push({method,selected,rows:report.rows.map(r=>({pid:r.pid,maximum:r.maxStress,envelope:r.envelopeStress,reserve:r.reserveFactor,coverage:r.coverage}))});
     }
    }
    checks.push(scenario+': actual recovered shell stresses independently agree for both properties, all cases and each case, maximum/mean/95th-percentile trimmed mean, governing case and reserve factors.');
    await page.locator('#stress-report-case').selectOption('all');await page.locator('#stress-report-reserve').click();assert.match(await page.locator('#stress-report-table caption').textContent(),/Reserve factors/);
    await page.evaluate(()=>activateWorkspaceTab('material'));if(await materialSelect.isVisible())await materialSelect.selectOption('8');else await page.locator('#allowable-material').selectOption('8');await page.locator('#allowable-stress').fill('200000');
    assert.equal(await page.evaluate(()=>formSignature()),signature);assert.equal(await page.evaluate(()=>state.modelDirty),false);await page.evaluate(()=>activateWorkspaceTab('stressreport'));
    const revised=await page.evaluate(()=>state.stressReport.report);for(const expected of expectedValues(raw,ownership,'trimmed_mean'))near(revised.rows.find(r=>r.pid===expected.pid).reserveFactor,200000/expected.envelope);
    for(const format of ['csv','markdown','html']){const pending=page.waitForEvent('download');await page.locator('#stress-report-export-'+format).click();const download=await pending,file=path.join(out,scenario+'-'+download.suggestedFilename());await download.saveAs(file);const text=fs.readFileSync(file,'utf8');assert(text.includes('Reserve factor')||text.includes('Reserve Factor'));assert(text.includes('101'));assert(text.includes('202'));assert(text.includes('Average below percentile'));}
    checks.push(scenario+': editing the imported material allowable refreshes reserve factors immediately without changing model signature or rerunning; all three exports contain full report metadata.');
    await page.evaluate(()=>setWorkspaceMaximized('stressreport'));await page.screenshot({path:path.join(out,scenario+'-reserve-maximized.png')});await page.locator('#stress-report-stress').click();await page.screenshot({path:path.join(out,scenario+'-stress-maximized.png')});await page.evaluate(()=>setWorkspaceMaximized(null));await page.setViewportSize({width:1050,height:820});await page.screenshot({path:path.join(out,scenario+'-stress-narrow.png')});await page.locator('#stress-report-table').scrollIntoViewIfNeeded();await page.screenshot({path:path.join(out,scenario+'-stress-narrow-table.png')});
    const checksInvalid=await page.evaluate(()=>{
     const outcomes=[],original=state.resultCases.get(42),test=(name,change,restore)=>{change();refreshStressReport();outcomes.push({name,rows:state.stressReport.report.rows.map(r=>({rf:r.reserveFactor,status:r.status})),excluded:state.stressReport.report.excludedCases.map(c=>c.reason),missing:state.stressReport.report.missingCases});restore();refreshStressReport();};
     test('missing case',()=>state.resultCases.delete(42),()=>state.resultCases.set(42,original));
     const oldStatus=original.status;test('failed case',()=>original.status='failed',()=>original.status=oldStatus);
     test('dirty model',()=>state.modelDirty=true,()=>state.modelDirty=false);
     const oldConvergence=original.convergence;test('partial nonlinear',()=>original.convergence={converged:true,full_load:false,partial:true},()=>original.convergence=oldConvergence);
     const oldAnalysis=original.analysis,oldKind=original.modeKind;test('excluded buckling',()=>{original.analysis='SOL105_BUCKLING';original.modeKind='buckling';},()=>{original.analysis=oldAnalysis;original.modeKind=oldKind;});
     return outcomes;
    });
    for(const item of checksInvalid){assert(item.rows.every(r=>r.rf===null),JSON.stringify(item));if(item.name==='missing case')assert(item.missing.length>0);else assert(item.excluded.length>0);}
    checks.push(scenario+': in-place missing/failed/dirty/partial/buckling changes immediately withhold reserve factors and retain explanatory coverage.');
    observed.push({scenario,loaded,all,guards:checksInvalid});await context.close();
   }catch(error){fs.writeFileSync(path.join(out,scenario+'-failure.json'),JSON.stringify({error:error.stack,checks,errors,requests},null,2));await page.screenshot({path:path.join(out,scenario+'-failure.png')});throw error;}
  }
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,observed,errors,requests},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
