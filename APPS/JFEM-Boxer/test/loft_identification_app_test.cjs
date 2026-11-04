'use strict';
// Actual app workflows using isolated HTTP fixtures; never writes the user's Study.
// node loft_identification_app_test.cjs <out-dir> <fixture-dir> <playwright-module> [browser]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,fixtureArg,playwrightArg,browserArg]=process.argv.slice(2),out=path.resolve(outArg),fixture=path.resolve(fixtureArg),web=path.resolve(__dirname,'../web'),{chromium}=require(path.resolve(playwrightArg));
const schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));schema.defaults=JSON.parse(fs.readFileSync(path.join(fixture,'params.json'),'utf8'));
(async()=>{fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(browserArg?{executablePath:browserArg}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1800,height:1150}}),checks=[],errors=[],requests=[];
try{
 page.on('pageerror',e=>errors.push(e.message));await page.route('http://127.0.0.1:43987/**',async route=>{
  const url=new URL(route.request().url()),body=route.request().method()==='POST'?route.request().postDataJSON():null;
  if(url.pathname.startsWith('/api/'))requests.push(url.pathname);
  if(url.pathname==='/api/input')return route.fulfill({json:schema});
  if(url.pathname==='/api/validate_workspace')return route.fulfill({json:{ok:true,parameters:body}});
  if(['/api/generate','/api/prepare_workspace'].includes(url.pathname))return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});
  if(url.pathname==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
  if(url.pathname==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(url.pathname==='/api/jfem_probe')return route.fulfill({json:{found:true}});
  if(url.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated loft fixture'}});
  const file=url.pathname.startsWith('/shared/')?path.join(web,'../..',url.pathname.slice('/shared/'.length)):path.join(web,url.pathname==='/'?'index.html':decodeURIComponent(url.pathname));
  return fs.existsSync(file)?route.fulfill({path:file}):route.fulfill({status:404,body:'No fixture asset'});
 });
 await page.goto('http://127.0.0.1:43987/');await page.locator('.startup-study-dialog [data-study-identification="text"]').fill('Student 42 — Loft assessment');await page.locator('.startup-study-dialog [data-study-identification="visible"]').check();await page.locator('.startup-study-dialog [data-choice="new"]').click();
 await page.waitForFunction(()=>typeof state!=='undefined'&&state.autoMeshReady&&!state.workspaceBusy,null,{timeout:120000});
 await page.evaluate(()=>{state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();activateWorkspaceTab('loft');setWorkspaceMaximized('loft');});
 assert.equal(await page.locator('.loft-distribution-plot').count(),3);
 await page.waitForFunction(()=>[...document.querySelectorAll('.loft-distribution-plot')].every(svg=>svg.parentElement.querySelector('.study-watermark-overlay:not([hidden])')));
 checks.push('All three actual Loft plots carry the Study identification in the maximized form');
 const thickness=page.locator('[data-loft-kind="thickness"]'),tip=()=>thickness.locator('.loft-station-row').last().locator('input').last();
 await page.locator('[data-loft-add="thickness"]').click();await tip().fill('.24');await tip().blur();
 const linear=await thickness.locator('[data-loft-curve]').getAttribute('d');await page.locator('[id="p-loft.thickness_interpolation"]').selectOption('cosine');assert.notEqual(await thickness.locator('[data-loft-curve]').getAttribute('d'),linear);
 const point=thickness.locator('[data-loft-handle="1"]');await point.scrollIntoViewIfNeeded();const box=await point.boundingBox(),before=Number(await tip().inputValue()),revision=await page.evaluate(()=>state.studyRevision);
 await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.mouse.move(box.x+box.width/2,box.y+box.height/2+25,{steps:5});assert.equal(await page.evaluate(()=>state.studyRevision),revision);await page.mouse.up();
 assert.equal(await page.evaluate(()=>state.studyRevision),revision+1);assert(Number(await tip().inputValue())<before);assert.equal(await thickness.locator('.loft-station-row').last().locator('input').first().inputValue(),'1');
 checks.push('Typed thickness and cosine interpolation redraw correctly; dragging preserves eta and commits one actual Study edit on release');
 for(const[kind,value]of[['twist','-4'],['vertical_shift','2']]){await page.locator(`[data-loft-add="${kind}"]`).click();await page.locator(`[data-loft-kind="${kind}"] .loft-station-row`).last().locator('input').last().fill(value);await page.locator(`[id="p-loft.${kind}_interpolation"]`).selectOption('cosine');}
 const expected=await page.evaluate(()=>{commitStudyNumericEdits();return{identification:state.studyWatermark.capture(),parameters:Object.fromEntries(['thickness','twist','vertical_shift'].flatMap(kind=>[['loft.'+kind+'_stations',collectParams()['loft.'+kind+'_stations']],['loft.'+kind+'_interpolation',collectParams()['loft.'+kind+'_interpolation']]]))};});
 assert.deepEqual(expected.parameters['loft.twist_stations'],[{eta:0,twist:0},{eta:1,twist:-4}]);assert.deepEqual(expected.parameters['loft.vertical_shift_stations'],[{eta:0,shift_percent:0},{eta:1,shift_percent:2}]);
 checks.push('Twist and vertical-shift edits are independent and reach the actual collected FE parameters');
 const saved=await page.evaluate(async()=>{window.loftWrites=[];window.showSaveFilePicker=async()=>({kind:'file',name:'LoftIdentity.wingfem.json',requestPermission:async()=> 'granted',createWritable:async()=>({write:async text=>loftWrites.push(text),close:async()=>{},abort:async()=>{}})});const result=await saveModelDefinition({saveAs:true,noteText:'Graphical loft edit fixture'});if(!result)throw Error('Actual Study Save As failed');return JSON.parse(loftWrites.at(-1));});
 assert.deepEqual(saved.identification,expected.identification);for(const[key,value]of Object.entries(expected.parameters))assert.deepEqual(saved.parameters[key],value,key);
 checks.push('Actual Save As serializes the graphical loft schedules, interpolation methods and identification together');
  await page.evaluate(()=>{state.studyWatermark.restore({text:'Other model',visible:false});state.values['loft.twist_stations']=[];});
 await page.evaluate(async saved=>{const ok=await loadModelDefinition(new File([JSON.stringify(saved)],'LoftIdentity.wingfem.json',{type:'application/json'}),{recent:true});if(!ok)throw Error('Actual Study reload failed');activateWorkspaceTab('loft');setWorkspaceMaximized('loft');},saved);
 await page.waitForFunction(()=>!state.workspaceBusy&&[...document.querySelectorAll('.loft-distribution-plot')].every(svg=>svg.parentElement.querySelector('.study-watermark-overlay:not([hidden])')));
 const restored=await page.evaluate(()=>({identification:state.studyWatermark.capture(),parameters:Object.fromEntries(['thickness','twist','vertical_shift'].flatMap(kind=>[['loft.'+kind+'_stations',collectParams()['loft.'+kind+'_stations']],['loft.'+kind+'_interpolation',collectParams()['loft.'+kind+'_interpolation']]]))}));assert.deepEqual(restored,expected);assert.equal(await page.locator('[data-loft-handle]').count(),6);
 checks.push('Actual Study reload restores all control points, functions, interpolation choices and visible identification');
 await page.screenshot({path:path.join(out,'loft-identity-maximized.png'),fullPage:true});
 await page.evaluate(()=>{setWorkspaceMaximized(null);activateWorkspaceTab('loft');});await page.screenshot({path:path.join(out,'loft-identity-sidebar.png')});
 assert(!requests.some(url=>/jfem_run|sensitivity_run|vlm_run/.test(url)),'Editing charts and saving must not launch an analysis');assert.deepEqual(errors,[]);
 fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,expected,restored,requests,errors},null,2));console.log('Loft and identification actual-app workflow: '+checks.length+' groups passed');
}catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors,requests},null,2));await page.screenshot({path:path.join(out,'failure.png'),fullPage:true}).catch(()=>{});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
