'use strict';
// node nonstructural_study_browser_test.cjs <evidence> <current-schema.json> <payload.msgpack> <playwright> [chrome]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [outArg,schemaArg,payloadArg,playwright,chrome]=process.argv.slice(2);if(!outArg||!schemaArg||!payloadArg||!playwright)throw Error('Pass evidence, current schema, generated payload, Playwright module and optional Chrome path');
const out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),schema=JSON.parse(fs.readFileSync(schemaArg,'utf8').replace(/^\uFEFF/,'')),{chromium}=require(path.resolve(playwright));
const msgpack=require('../web/vendor/msgpack.min.js'),geometry=msgpack.decode(fs.readFileSync(payloadArg));
schema.defaults??=schema.values;
(async()=>{fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(chrome?{executablePath:chrome}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1540,height:1080}}),errors=[],checks=[];
try{
 page.on('pageerror',e=>errors.push(e.message));await page.route('http://127.0.0.1:43984/**',route=>{const p=new URL(route.request().url()).pathname;
  if(p==='/api/input')return route.fulfill({json:schema});
  // Geometry is retained as an explicit frontend fixture. Only the selected
  // new parameter metadata is echoed; no mass/FEM numerical claim is made here.
  if(['/api/generate','/api/prepare_workspace'].includes(p)){const data=route.request().postDataJSON(),params=data.parameters||data;return route.fulfill({body:Buffer.from(msgpack.encode({...geometry,model_params:{...geometry.model_params,...Object.fromEntries(Object.keys(schema.values).filter(k=>k.startsWith('nonstructural.')).map(k=>[k,params[k]??schema.values[k]]))}})),contentType:'application/msgpack'});}
  if(p==='/api/validate_workspace')return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
  if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(p.startsWith('/api/'))return route.fulfill({json:{ok:true,events:[]}});
  return route.fulfill({path:path.join(web,p==='/'?'index.html':p)});
 });
 await page.goto('http://127.0.0.1:43984/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await page.waitForFunction(()=>typeof state!=='undefined'&&state.data&&state.autoMeshReady&&!state.workspaceBusy,null,{timeout:120000});
 await page.evaluate(()=>{state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();markStudySaved();window.studySavedText='';window.showSaveFilePicker=()=>Promise.resolve({name:'Nonstructural.wingfem.json',createWritable:async()=>({write:async text=>{studySavedText=text;},close:async()=>{}})});});
 await page.locator('#tab-properties').click();await page.locator('#tab-nonstructural').click();
 const panel=page.locator('#group-non-structural-mass');assert(await panel.isVisible());assert.equal(await panel.locator('input').count(),10);
 assert.match(await panel.textContent(),/actual shell area/);assert.match(await panel.textContent(),/every rib bay/);checks.push('Properties menu opens the dedicated 10-field Non-structural mass tab with substantive units and scope guidance');
 await page.locator('[id="p-nonstructural.upper_skin"]').fill('2.5');await page.locator('[id="p-nonstructural.stringer"]').fill('0.7');await page.locator('[id="p-nonstructural.rib_stiffener"]').fill('0.4');
 assert.equal(await page.evaluate(()=>state.studyDirty),true);assert.equal(await page.locator('#btn-save-model').getAttribute('data-saved'),'false');
 await page.locator('#btn-project').click();await page.locator('#btn-save-model').click();await page.locator('.study-comments-save').click();await page.waitForFunction(()=>!!studySavedText&&!state.workspaceBusy&&!state.studyCommentOpen);
 const saved=await page.evaluate(()=>JSON.parse(studySavedText));assert.deepEqual([saved.parameters['nonstructural.upper_skin'],saved.parameters['nonstructural.stringer'],saved.parameters['nonstructural.rib_stiffener']],[2.5,.7,.4]);assert.equal(await page.evaluate(()=>state.studyDirty),false);
 checks.push('Surface and line density edits dirty the Study and save as exact numeric parameters');
 await page.locator('[id="p-nonstructural.upper_skin"]').fill('9');assert.equal(await page.evaluate(()=>state.studyDirty),true);
 await page.evaluate(()=>loadModelDefinition(new File([studySavedText],'Nonstructural.wingfem.json',{type:'application/json'}),{recent:true,source:'snapshot'}));
 await page.locator('#tab-properties').click();await page.locator('#tab-nonstructural').click();
 assert.deepEqual(await page.evaluate(()=>['upper_skin','stringer','rib_stiffener'].map(key=>Number(document.getElementById('p-nonstructural.'+key).value))),[2.5,.7,.4]);assert.equal(await page.evaluate(()=>state.studyDirty),false);
 checks.push('Reopening the portable Study restores all changed surface/line values and clears only the successfully loaded dirty state');
 await page.screenshot({path:path.join(out,'nonstructural-study-restored.png')});assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log('Non-structural Study browser: '+checks.length+' groups passed');
}catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
