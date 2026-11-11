'use strict';
// The detached table must receive per-section/alias drafts from an assembly dialog.
// node rf_assembly_table_drafts_browser_test.cjs OUTPUT PLAYWRIGHT_MODULE
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,modulePath='playwright']=process.argv.slice(2),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),{chromium}=require(modulePath);
const{context:fixture,report:source}=require('./rf_assembly_editor_test.cjs');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],checks=[],browser=await chromium.launch({channel:'chrome',headless:true}),context=await browser.newContext({viewport:{width:1600,height:1100}}),page=await context.newPage();page.on('pageerror',e=>errors.push(e.stack));
 const origin='http://127.0.0.1:43971',token='assembly-drafts';
 await context.route(origin+'/**',route=>{const p=new URL(route.request().url()).pathname;return route.fulfill({path:path.join(web,p.slice(1)||'reserve_factor_table.html')});});
 // Authenticate actual window message delivery using a same-origin opener.
 // This isolates the table handler; the production bridge is tested separately.
 await page.addInitScript(()=>Object.defineProperty(window,'opener',{value:window,configurable:true}));
 const post=(type,data={})=>page.evaluate(({token,type,data})=>window.postMessage({channel:'JFEM-Boxer.reserve-factor-table.v1',token,type,...data},location.origin),{token,type,data});
 try{
  await page.goto(origin+'/reserve_factor_table.html#'+token);
  const snapshot={generated:true,onlyBelowOne:true,panels:fixture.panels.map(p=>p.key===fixture.panels[0].key?{...p,stringer_web_pid:19000001,stringer_flange_pid:20000001}:p),report:{...source,caseScopeLabel:'2.5g',rows:[...source.rows,...[19000001,20000001].map(pid=>({...source.rows[2],pid}))].map(row=>({...row,coverage:{recovered:1,total:1}}))}};
  await post('snapshot',{snapshot});await page.waitForFunction(()=>document.querySelectorAll('.rf-edit-origin').length>=5);
  const cell=pid=>page.locator('.rf-edit-origin').filter({has:page.locator('[data-edit-pid="'+pid+'"]')});
  assert.match(await cell(6000001).locator('.rf-edit-property').textContent(),/skin \/ stringer/);
  const initial=await page.locator('.rf-value[data-value]').evaluateAll(nodes=>nodes.map(el=>[el.dataset.pid,el.dataset.value]));
  const props=[{pid:6000001,hasDrafts:false,belowMinimumFields:[]},...[7000001,19000001,20000001].map(pid=>({pid,hasDrafts:true,belowMinimumFields:['web_thickness']}))];
  await post('property-draft',{pid:6000001,detail:{hasDrafts:true,properties:props,belowMinimumFields:['web_thickness']}});
  await page.waitForFunction(()=>document.querySelectorAll('.rf-edit-origin.rf-below-minimum').length===3);
  assert.equal(await cell(6000001).evaluate(el=>el.classList.contains('rf-below-minimum')),false);
  for(const pid of[7000001,19000001,20000001])assert(await cell(pid).evaluate(el=>el.classList.contains('rf-below-minimum')));
  await page.locator('#table-palette').selectOption('viridis');
  assert.equal(await page.locator('.rf-edit-origin.rf-below-minimum').count(),3);
  assert.deepEqual(await page.locator('.rf-value[data-value]').evaluateAll(nodes=>nodes.map(el=>[el.dataset.pid,el.dataset.value])),initial);
  checks.push('An undersized stringer draft marks its bar/web/flange cells red rather than the clicked skin; rerender preserves warnings without changing RF values.');
  await post('property-draft',{pid:6000001,detail:{hasDrafts:false,properties:props.map(p=>({...p,hasDrafts:false,belowMinimumFields:[]}))}});
  await page.waitForFunction(()=>document.querySelectorAll('.rf-edit-origin.rf-below-minimum').length===0);
  await post('property-draft',{pid:6000001,detail:{hasDrafts:true,belowMinimumFields:['thickness']}});
  await page.waitForFunction(()=>document.querySelectorAll('.rf-edit-origin.rf-below-minimum').length===1);
  assert(await cell(6000001).evaluate(el=>el.classList.contains('rf-below-minimum')));
  await post('property-draft',{pid:6000001,detail:{hasDrafts:false,belowMinimumFields:[]}});await page.waitForFunction(()=>document.querySelectorAll('.rf-edit-origin.rf-below-minimum').length===0);
  checks.push('Closing the multi-property editor clears all owned alias warnings; legacy single-property draft messages remain compatible.');
  assert.deepEqual(errors,[]);await page.screenshot({path:path.join(out,'assembly-table-drafts.png')});fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,errors,checks},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
