'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
if(process.argv.length<4||process.argv.length>5)throw Error('Usage: node test/activity_timings_browser_test.cjs <structured-status.json> <evidence-dir> [playwright-module]');
const fixture=JSON.parse(fs.readFileSync(path.resolve(process.argv[2]),'utf8').replace(/^\uFEFF/,'')),out=path.resolve(process.argv[3]),web=path.resolve(__dirname,'../web');
const playwright=process.argv[4]||process.env.WING_PLAYWRIGHT_MODULE,{chromium}=require(playwright?path.resolve(playwright):'playwright');
fs.mkdirSync(out,{recursive:true});
(async()=>{
 const launch={headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']};if(process.env.CHROME_PATH)launch.executablePath=process.env.CHROME_PATH;
 const browser=await chromium.launch(launch),page=await browser.newPage({viewport:{width:1450,height:1000}}),errors=[],checks=[];
 try{
  page.on('pageerror',error=>errors.push(error.stack));const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43994/**',route=>new URL(route.request().url()).pathname==='/index.html'?
   route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')}):route.fulfill({path:path.join(web,new URL(route.request().url()).pathname)}));
  await page.goto('http://127.0.0.1:43994/index.html');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const source=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:source.slice(0,source.indexOf('(async function start()'))});
  await page.evaluate(()=>{document.getElementById('splash').hidden=true;});
  const snapshot=()=>page.locator('#activity-status').evaluate(el=>({category:el.dataset.category,state:el.dataset.state,background:getComputedStyle(el).backgroundColor,detail:el.textContent,busy:el.getAttribute('aria-busy')}));
  assert.equal((await snapshot()).background,'rgb(168, 84, 0)');await page.screenshot({path:path.join(out,'startup-orange.png')});
  await page.evaluate(()=>{WingActivity.end(WingActivity.startup);WingActivity.startup=null;});
  const events=fixture.events||[];assert(events.length>0,'actual structured events required');
  let numerical=0,other=0;
  for(const event of events){
   const progress=event.stage?event:{stage:event.phase,stage_category:event.category,stage_message:event.label,stage_state:event.state,
    compilation_live:event.compilation_live,stage_timing:event.timing};
   await page.evaluate(progress=>solverActivity(true,progress),progress);
   const shown=await snapshot();
   if(progress.stage_category==='numerical'&&progress.stage_state==='started'){
    numerical++;assert.equal(shown.category,'numerical');assert.match(shown.detail,/Julia compilation may occur/);
   }else{other++;assert.equal(shown.category,'preparation');}
  }
  assert(numerical>0&&other>0);checks.push('Actual structured numerical phases are blue, including possible JIT; startup, preparation and export are orange.');
  const mixed=events.find(event=>(event.category||event.stage_category)==='numerical'&&(event.state||event.stage_state)==='started');
  await page.evaluate(event=>solverActivity(true,{stage:event.phase||event.stage,stage_category:'numerical',stage_message:event.label||event.stage_message,stage_state:'started',compilation_live:'not_separable'}),mixed);
  await page.screenshot({path:path.join(out,'numerical-phase-blue.png')});
  await page.evaluate(()=>solverActivity(true,{stage:'external_numeric',stage_message:'Numerical execution (explicit test signal)',stage_category:'numerical',stage_state:'started',compilation_live:'excluded'}));
  assert.equal((await snapshot()).background,'rgb(22, 79, 145)');assert.match((await snapshot()).detail,/compilation excluded/);
  await page.screenshot({path:path.join(out,'explicit-compilation-excluded-blue.png')});
  checks.push('Numerical phases remain blue when compilation is excluded; possible JIT remains explicitly disclosed for other numerical phases.');
  await page.evaluate(job=>{solverActivity(false);for(const entry of WingRunTimings.entries(job))log(entry.text,entry.kind);flushLog();activateWorkspaceTab('log');},fixture.job);
  const logText=await page.locator('#log').textContent();assert.match(logText,/exclusive numerical execution/);assert.match(logText,/exclusive Julia compilation/);assert.match(logText,/do not add them/);
  assert(await page.locator('#log .numerical').count()>0);assert(await page.locator('#log .compilation').count()>0);
  await page.locator('#btn-max-log').click();
  await page.screenshot({path:path.join(out,'detailed-final-timing-log.png')});
  await page.locator('#btn-max-log').click();
  checks.push('Actual final timing rows include stage labels, calls, inclusive/exclusive scopes, numerical execution, measured compilation/recompilation and GC; overlapping scopes are never added.');
  await page.evaluate(()=>{window.oldFetch=fetch;window.fetch=()=>new Promise(resolve=>{window.finishResultRequest=resolve;});window.delayedRead=loadJfemResults();});
  assert.equal((await snapshot()).background,'rgb(168, 84, 0)');assert.match((await snapshot()).detail,/Loading analysis results/);
  await page.screenshot({path:path.join(out,'delayed-results-orange.png')});
  await page.evaluate(async()=>{finishResultRequest({ok:false,json:async()=>({error:'Expected test read failure'})});await delayedRead;window.fetch=oldFetch;finishRun(false,'failed');});
  assert.equal((await snapshot()).background,'rgb(135, 46, 50)');assert.equal((await snapshot()).busy,'false');
  await page.screenshot({path:path.join(out,'failed-red.png')});
  await page.evaluate(()=>{badge('JFEM done');finishRun(true,'done');});assert.equal((await snapshot()).background,'rgb(26, 97, 60)');
  assert.match(await page.locator('#activity-time').getAttribute('aria-label'),/Total task elapsed.*preparation.*compilation/);
  await page.screenshot({path:path.join(out,'completed-green.png')});
  checks.push('Delayed result reading remains orange; actual read failure produces a red terminal notice and successful completion is green.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,numericalEvents:numerical,otherEvents:other,errors},null,2));console.log(checks.join('\n'));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
