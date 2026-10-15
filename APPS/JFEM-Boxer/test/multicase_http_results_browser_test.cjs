'use strict';
// Replay real /api/generate and /api/jfem_results bytes; no solver is launched.
// node test/multicase_http_results_browser_test.cjs <http-fixture-dir> <evidence-dir> [playwright-module]
// Inputs: input_schema.json; multicase_{model,results}.msgpack and multicase_results.json.
// fuel_multicase equivalents are replayed when present. CHROME_PATH optional.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
if(!process.argv[2]||!process.argv[3])throw Error('Pass HTTP fixture directory, evidence directory and optional Playwright module');
const fixture=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]),web=path.resolve(__dirname,'../web'),{chromium}=require(process.argv[4]||'playwright');
const schema=JSON.parse(fs.readFileSync(path.join(fixture,'input_schema.json'),'utf8'));schema.defaults??=schema.values;
const scenarios=['multicase',...(fs.existsSync(path.join(fixture,'fuel_multicase_results.msgpack'))?['fuel_multicase']:[])];
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],requests=[],observed=[];let current='multicase';
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1510,height:1080}});
 page.on('pageerror',e=>errors.push(e.stack));
 try{
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43956/**',route=>{const url=new URL(route.request().url());if(url.pathname==='/api/jfem_results'){requests.push({path:url.pathname,fixture:current});return route.fulfill({path:path.join(fixture,current+'_results.msgpack'),contentType:'application/msgpack'});}if(url.pathname.startsWith('/api/')){requests.push({path:url.pathname});return url.pathname==='/api/activity'?route.fulfill({json:{ok:true}}):route.fulfill({status:404,json:{error:'Replay only; no solver requests allowed'}});}return url.pathname==='/'?route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')}):route.fulfill({path:path.join(web,url.pathname)});});
  await page.goto('http://127.0.0.1:43956/');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const source=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:source.slice(0,source.indexOf('(async function start()'))});
  await page.evaluate(schema=>{initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.defaults=schema.defaults;state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;},schema);
  for(const scenario of scenarios){
   current=scenario;const expected=JSON.parse(fs.readFileSync(path.join(fixture,scenario+'_results.json'),'utf8'));
   const loaded=await page.evaluate(async({bytes,job})=>{
    state.results=null;state.resultCases=null;state.activeMode=-1;state.data=MessagePack.decode(Uint8Array.from(bytes));state.values=state.data.model_params;
    buildForm(state.schema,state.values);buildModel(state.data);state.modelSignature=formSignature();state.jobSignature=state.modelSignature;state.jobId=job;setModelDirty(false);setBusy(false);markStudySaved();
    window.replayDefinition=formSignature();window.replayCoordinates=Array.from(state.baseline);
    const accepted=await loadJfemResults();activateWorkspaceTab('results');document.getElementById('animate').checked=false;
    return{accepted,error:state.resultReadError,cases:[...state.resultCases].map(([id,r])=>({id,matches:r.matches,issues:r.validationIssues,available:r.available,max:r.static?.maxDisp})),dirty:state.modelDirty};
   },{bytes:[...fs.readFileSync(path.join(fixture,scenario+'_model.msgpack'))],job:expected.job});
   assert(loaded.accepted,JSON.stringify(loaded));assert.equal(loaded.error,'');assert.equal(loaded.dirty,false);assert.equal(loaded.cases.length,2);
   for(const c of loaded.cases){const raw=expected.load_cases.find(r=>r.id===c.id);assert(c.matches&&c.available);assert.deepEqual(c.issues,[]);assert.equal(c.max,raw.static.max_disp);}
   checks.push(scenario+': actual HTTP result bytes accepted for both cases using immutable source parameters, with exact reported peak displacement');
   const perCase=[];
   for(const c of expected.load_cases){
    await page.locator('#result-case-select').selectOption(String(c.id));
    const row=await page.evaluate(()=>{
     const disp=state.results.static.disp,peak=Array.from({length:disp.length/3},(_,i)=>({i,m:Math.hypot(...disp.subarray(3*i,3*i+3))})).sort((a,b)=>b.m-a.m)[0];
     showNode(peak.i);const picked=document.getElementById('pick-content').textContent;
     return{id:state.activeCase,peak:peak.m,max:state.results.static.maxDisp,picked,contours:state.results.contours.length,rendered:state.shellMeshes.some(m=>m.isEnabled()),mass:state.data.load_cases.find(c=>c.id===state.activeCase).fuel.mass_kg,selectors:['geometry-case-select','mass-case-select','summary-case-select','load-case-select','result-case-select','weights-case-select','plots-case-select','inspect-case-select'].map(id=>document.getElementById(id)?.value),summary:document.getElementById('results-summary').textContent};
    });
    assert.equal(row.max,c.static.max_disp);assert(row.peak>0&&row.contours>0&&row.rendered);assert(row.picked.includes('Translation x, y, z (m)'));for(const selected of row.selectors)assert.equal(selected,String(c.id));perCase.push(row);
   }
   assert.notEqual(perCase[0].max,perCase[1].max);assert.notEqual(perCase[0].picked,perCase[1].picked);
   if(scenario==='multicase')assert(Math.abs(perCase[1].max/perCase[0].max-2)<1e-12);
   else{assert(perCase[1].mass>perCase[0].mass);assert(Math.abs(perCase[1].mass/perCase[0].mass-10)<1e-6,'Adaptive fuel-volume integration should preserve the 100%/10% fill ratio to integration accuracy');}
   assert(await page.evaluate(()=>!state.studyDirty&&formSignature()===replayDefinition&&replayCoordinates.every((v,i)=>v===state.baseline[i])));
   checks.push(scenario+': switching real cases updates FE/Inspect values and all eight selectors, preserves geometry/definition and displays separate fuel states when applicable');
   await page.evaluate(async()=>{activateWorkspaceTab('results');document.getElementById('workspace-content').scrollTop=0;state.engine.resize();await state.scene.whenReadyAsync();state.scene.render();await new Promise(requestAnimationFrame);});await page.screenshot({path:path.join(out,scenario+'-results.png')});
   observed.push({scenario,loaded,perCase});
  }
  assert.deepEqual(errors,[]);assert.deepEqual(requests.filter(r=>r.path!=='/api/activity').map(r=>r.path),scenarios.map(()=>'/api/jfem_results'));
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,observed,requests,errors},null,2));console.log(`Actual multicase HTTP replay: ${checks.length} groups passed.`);
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,observed,requests,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
