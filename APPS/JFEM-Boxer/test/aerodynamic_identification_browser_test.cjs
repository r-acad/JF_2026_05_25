'use strict';
// Actual Boxer UI with immutable HTTP/result fixtures. No server or VLM solve.
// node aerodynamic_identification_browser_test.cjs OUT FIXTURE AERO_RESULT PLAYWRIGHT [BROWSER]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,fixtureArg,resultArg,modulePath,browserArg]=process.argv.slice(2),out=path.resolve(outArg),fixture=path.resolve(fixtureArg),web=path.resolve(__dirname,'../web'),{chromium}=require(path.resolve(modulePath));
const schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8')),native=JSON.parse(fs.readFileSync(resultArg,'utf8'));schema.defaults=JSON.parse(fs.readFileSync(path.join(fixture,'params.json'),'utf8'));
(async()=>{fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(browserArg?{executablePath:browserArg}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1750,height:1200}}),checks=[],errors=[],requests=[];let signature='';
try{
 page.on('pageerror',e=>errors.push(e.message));await page.route('http://127.0.0.1:43988/**',async route=>{
  const url=new URL(route.request().url()),body=route.request().method()==='POST'?route.request().postDataJSON():null;
  if(url.pathname.startsWith('/api/'))requests.push(url.pathname);
  if(url.pathname==='/api/input')return route.fulfill({json:schema});
  if(url.pathname==='/api/validate_workspace')return route.fulfill({json:{ok:true,parameters:body}});
  if(['/api/generate','/api/prepare_workspace'].includes(url.pathname))return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});
  if(url.pathname==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
  if(url.pathname==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(url.pathname==='/api/jfem_probe')return route.fulfill({json:{found:true}});
  if(url.pathname==='/api/aerodynamics/run'){signature=body.signature;return route.fulfill({json:{id:'immutable-aero-display'}});}
  if(url.pathname==='/api/aerodynamics/status')return route.fulfill({json:{state:'done',seconds:0}});
  if(url.pathname==='/api/aerodynamics/results')return route.fulfill({json:{...native,signature}});
  if(url.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated identification fixture'}});
  const file=url.pathname.startsWith('/shared/')?path.join(web,'../..',url.pathname.slice('/shared/'.length)):path.join(web,url.pathname==='/'?'index.html':decodeURIComponent(url.pathname));
  return fs.existsSync(file)?route.fulfill({path:file}):route.fulfill({status:404,body:'No fixture asset'});
 });
 await page.goto('http://127.0.0.1:43988/');await page.locator('[data-study-identification=text]').fill('Student 42 <CONFIDENTIAL>');await page.locator('[data-study-identification=visible]').check();await page.locator('[data-choice=new]').click();
 await page.waitForFunction(()=>typeof state!=='undefined'&&state.autoMeshReady&&!state.workspaceBusy,null,{timeout:120000});
 await page.evaluate(()=>{state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();activateWorkspaceTab('aerostudy');});
 const overlay=()=>page.locator('#aerodynamic-study .aero-canvas-wrap>.study-watermark-overlay:not([hidden])');
 await overlay().waitFor();assert.equal(await overlay().count(),1);assert.equal(await overlay().innerText(),'Student 42 <CONFIDENTIAL>');
 assert.equal(await page.locator('.aero-reference-overlay [data-study-watermark]').count(),0);checks.push('Inline aerodynamic 3D canvas carries exactly one literal identification; its reference-axes SVG does not duplicate it');
 await page.evaluate(settings=>{const v=state.aerodynamicStudy.capture();v.settings=settings;state.aerodynamicStudy.restore(v);},native.settings);
 await page.locator('[data-action=run]').click();await page.waitForFunction(()=>state.aerodynamicStudy.result&&!state.aerodynamicStudy.busy);
 await overlay().waitFor();const snapshot=await page.evaluate(()=>JSON.stringify(state.aerodynamicStudy.result)),requestsAfterReplay=requests.length;
 async function verifyExport(tab,name,enabled=true){await page.evaluate(()=>state.aerodynamicStudy.showPane('display'));const [download]=await Promise.all([tab.waitForEvent('download'),tab.locator('[data-action=view-svg]').click()]);const file=path.join(out,name);await download.saveAs(file);const text=fs.readFileSync(file,'utf8');assert.equal((text.match(/data-study-watermark="true"/g)||[]).length,enabled?1:0);assert.equal(await page.evaluate(text=>new DOMParser().parseFromString(text,'image/svg+xml').querySelectorAll('parsererror').length,text),0);if(enabled)assert(text.includes('Student 42 &lt;CONFIDENTIAL&gt;'));return file;}
 await verifyExport(page,'inline-aerodynamic.svg');checks.push('Inline aerodynamic vector export preserves identification once, escaped as SVG text');
 await page.evaluate(()=>state.aerodynamicStudy.showPane('distributions'));
 const plot=page.locator('.aero-distributions .aero-chart').first();
 const [plotDownload]=await Promise.all([page.waitForEvent('download'),plot.locator('[data-plot-export=svg]').click()]);
 const plotPath=path.join(out,'distribution.svg');await plotDownload.saveAs(plotPath);const plotText=fs.readFileSync(plotPath,'utf8');assert.equal((plotText.match(/data-study-watermark="true"/g)||[]).length,1);assert(plotText.includes('Student 42 &lt;CONFIDENTIAL&gt;'));assert(plotText.includes('<title>'));assert.equal(await page.evaluate(text=>new DOMParser().parseFromString(text,'image/svg+xml').querySelectorAll('parsererror').length,plotText),0);
 await page.evaluate(()=>state.aerodynamicStudy.showPane('sweeps'));
 const [reportDownload]=await Promise.all([page.waitForEvent('download'),page.locator('[data-sweep-export=html]').click()]);
 const reportPath=path.join(out,'sweep-figures.html');await reportDownload.saveAs(reportPath);const reportText=fs.readFileSync(reportPath,'utf8');
 const figures=await page.evaluate(text=>{const d=new DOMParser().parseFromString(text,'text/html');return[...d.querySelectorAll('svg')].filter(svg=>!svg.parentElement.closest('svg')).map(svg=>({stamps:svg.querySelectorAll('[data-study-watermark]').length,title:svg.querySelector('title')?.textContent}));},reportText);
 assert(figures.length>0);assert(figures.every(figure=>figure.stamps===1&&figure.title));
 assert.equal(await page.evaluate(()=>WingStudyWatermark.stampExport('A,B\n1,2','text/csv')),'A,B\n1,2');assert.equal(await page.evaluate(()=>WingStudyWatermark.stampExport('# Data\nTable','text/markdown')),'# Data\nTable');
 checks.push('Aerodynamic distribution SVG and every top-level figure in HTML exports retain identification and titles; CSV and Markdown data remain exact');
 const popupPending=page.waitForEvent('popup');await page.locator('[data-action=detach]').click();const popup=await popupPending;popup.on('pageerror',e=>errors.push(e.message));
 const detached=()=>popup.locator('.aero-canvas-wrap>.study-watermark-overlay:not([hidden])');await detached().waitFor();assert.equal(await detached().count(),1);
 assert.equal(await detached().evaluate(n=>getComputedStyle(n).pointerEvents),'none');assert.equal(await detached().evaluate(n=>getComputedStyle(n).position),'absolute');assert.equal(await detached().innerText(),'Student 42 <CONFIDENTIAL>');
 const bounds=await popup.locator('.aero-canvas').boundingBox(),stamp=await detached().boundingBox();for(const k of ['x','y','width','height'])assert(Math.abs(bounds[k]-stamp[k])<1);
 await verifyExport(popup,'detached-aerodynamic.svg');checks.push('Detached aerodynamic canvas receives styled, non-interactive identification matching its bounds; detached vector export retains it');
 await page.evaluate(()=>state.studyWatermark.restore({text:'Student 42 <CONFIDENTIAL>',visible:false}));await detached().waitFor({state:'hidden'});await verifyExport(popup,'hidden-aerodynamic.svg',false);
 await page.evaluate(()=>state.studyWatermark.restore({text:'Student 42 <CONFIDENTIAL>',visible:true}));await detached().waitFor();
 await popup.setViewportSize({width:1450,height:950});await popup.waitForTimeout(100);const resized=await popup.locator('.aero-canvas').boundingBox(),resizedStamp=await detached().boundingBox();for(const k of ['x','y','width','height'])assert(Math.abs(resized[k]-resizedStamp[k])<1);
 await popup.screenshot({path:path.join(out,'detached-identification.png')});checks.push('Main Study identification toggle updates the detached workspace and its exports; overlay follows resizing');
 await popup.locator('[data-action=detach]').click();await page.waitForFunction(()=>!state.aerodynamicStudy.detached);await overlay().waitFor();assert.equal(await overlay().count(),1);
 const secondPending=page.waitForEvent('popup');await page.locator('[data-action=detach]').click();const second=await secondPending;await second.locator('.aero-canvas-wrap>.study-watermark-overlay:not([hidden])').waitFor();await second.close();await page.waitForFunction(()=>!state.aerodynamicStudy.detached);await overlay().waitFor();assert.equal(await overlay().count(),1);
 assert.equal(await page.evaluate(()=>JSON.stringify(state.aerodynamicStudy.result)),snapshot);assert.equal(requests.length,requestsAfterReplay);checks.push('Explicit return, repeated detach and browser close restore exactly one inline watermark without new requests or result mutation');
 await page.screenshot({path:path.join(out,'restored-identification.png')});assert.deepEqual(errors,[]);
 fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,requests,errors},null,2));console.log('Aerodynamic identification: '+checks.length+' groups passed');
}catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,requests,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
