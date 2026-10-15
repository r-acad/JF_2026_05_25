'use strict';
// Optional fixture-free browser regression. Arguments: output directory, Playwright module directory.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const out=path.resolve(process.argv[2]||'sensitivity-setup-browser-output');
const {chromium}=require(process.argv[3]||'playwright'),web=path.resolve(__dirname,'../web');
const checks=[],errors=[];
(async()=>{
 fs.mkdirSync(out,{recursive:true});
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
 const page=await browser.newPage({viewport:{width:1100,height:1050}});
 try{
  page.on('pageerror',error=>errors.push(error.stack));
  await page.route('http://127.0.0.1:43957/**',route=>{const url=new URL(route.request().url());
   if(url.pathname==='/')return route.fulfill({contentType:'text/html',body:'<!DOCTYPE html><link rel="stylesheet" href="style.css"><main id="host"></main><script src="result_display.js"></script><script src="sensitivity.js"></script><script src="workspace.js"></script>'});
   assert(!url.pathname.startsWith('/api/'),'Editing/restoring must not start analysis');
   return route.fulfill({path:path.join(web,decodeURIComponent(url.pathname))});
  });
  await page.goto('http://127.0.0.1:43957/');
  await page.evaluate(()=>{
   window.ctx={ready:true,dirty:false,blocked:false,catalogVisible:true,signature:'generated',meshIdentity:1};
   window.rows=[{id:'properties.t_skin_upper',label:'Upper skin',value:.002,unit:'m'},{id:'properties.t_spar',label:'Spar web',value:.003,unit:'m'},{id:'material.E',label:'Elastic modulus',value:70,unit:'GPa'}];
   window.catalogCalls=0;window.edits=[];window.runCalls=0;window.pending=[];window.defer=false;
   window.editor=WingSensitivity.create(document.getElementById('host'),{
    context:()=>ctx,cases:()=>[{id:1,label:'Flight'},{id:7,label:'Imported case'}],onEdit:text=>edits.push(JSON.parse(text)),
    catalog:()=>{catalogCalls++;const result={variables:structuredClone(rows),max_variables:4096};return defer?new Promise(resolve=>pending.push(()=>resolve(result))):Promise.resolve(result);},
    run:()=>{runCalls++;}
   });
   window.settings={case_id:1,objective:{type:'displacement',component:'z',node_id:12},variables:['properties.t_spar','material.E'],derivative_method:'analytic',relative_step:.01,check_step:true};
   editor.restore(JSON.stringify(settings));
  });
  await page.waitForFunction(()=>document.querySelectorAll('#sensitivity-variables input:checked').length===2);
  assert.deepEqual(await page.locator('#sensitivity-variables input:checked').evaluateAll(nodes=>nodes.map(n=>n.value)),['properties.t_spar','material.E']);
  assert.equal(await page.evaluate(()=>catalogCalls),1);assert.deepEqual(await page.evaluate(()=>edits),[]);
  checks.push('Restored saved selections automatically load current checkboxes without marking Study edited or starting analysis');

  await page.locator('#sensitivity-filter').fill('no-match');
  await page.evaluate(()=>{ctx.catalogVisible=false;ctx.meshIdentity=2;editor.restore(JSON.stringify(settings));});
  assert.equal(await page.locator('#sensitivity-filter').inputValue(),'');assert.equal(await page.evaluate(()=>catalogCalls),1);
  assert.match(await page.locator('#sensitivity-variables').textContent(),/2 saved design variables selected/);
  await page.evaluate(()=>{ctx.catalogVisible=true;ctx.blocked=true;editor.refreshContext();});
  assert.equal(await page.evaluate(()=>catalogCalls),1);
  await page.evaluate(()=>{ctx.blocked=false;editor.refreshContext();});
  await page.waitForFunction(()=>catalogCalls===2&&document.querySelectorAll('#sensitivity-variables input:checked').length===2);
  checks.push('Restoring clears old filters, defers property reads until the restored model is idle and Sensitivity is visible, then restores the saved selections');

  await page.evaluate(()=>{defer=true;editor.readCatalog();});await page.waitForFunction(()=>pending.length===1);
  await page.evaluate(()=>{
   ctx.signature='imported';ctx.meshIdentity=3;rows=[{id:'reference.PSHELL#123#T',label:'PSHELL 123 thickness',value:.001,unit:'m'},{id:'reference.MAT1#2#E',label:'MAT1 2 modulus',value:70,unit:'GPa'}];
   editor.restore({...settings,case_id:7,variables:['reference.PSHELL#123#T']});
  });
  await page.waitForFunction(()=>pending.length===2);
  await page.evaluate(()=>pending[0]());
  assert.equal(await page.locator('#sensitivity-variables input').count(),0);
  await page.evaluate(()=>pending[1]());
  await page.waitForFunction(()=>document.querySelectorAll('#sensitivity-variables input:checked').length===1);
  assert.equal(await page.locator('#sensitivity-variables input:checked').inputValue(),'reference.PSHELL#123#T');
  assert.equal(await page.locator('#sensitivity-case').inputValue(),'7');
  checks.push('An old in-flight generated-model catalogue cannot replace restored imported-deck selections or release the new pending read');

  await page.evaluate(()=>{defer=false;editor.restore({...settings,variables:[]});});
  const calls=await page.evaluate(()=>catalogCalls);await page.waitForTimeout(40);assert.equal(await page.evaluate(()=>catalogCalls),calls);
  assert.deepEqual(await page.evaluate(()=>editor.capture().variables),[]);
  await page.locator('#sensitivity-refresh').click();await page.waitForFunction(()=>document.querySelectorAll('#sensitivity-variables input').length===2);
  assert.equal(await page.locator('#sensitivity-variables input:checked').count(),0);
  checks.push('An explicitly empty saved selection stays empty after a manual refresh instead of selecting defaults');

  await page.evaluate(()=>editor.restore({...settings,variables:['removed-property','reference.PSHELL#123#T']}));
  await page.waitForFunction(()=>document.querySelectorAll('#sensitivity-variables input:checked').length===1);
  assert.deepEqual(await page.evaluate(()=>editor.capture().variables),['removed-property','reference.PSHELL#123#T']);
  assert.match(await page.locator('#sensitivity-context').textContent(),/no longer present/);
  assert(await page.locator('#sensitivity-run').isDisabled());assert.deepEqual(await page.evaluate(()=>edits),[]);
  await page.locator('#sensitivity-recover').click();assert.deepEqual(await page.evaluate(()=>editor.capture().variables),['reference.PSHELL#123#T']);
  assert.equal(await page.evaluate(()=>edits.length),1);
  checks.push('Unavailable saved IDs remain selected and explicitly reported until the user removes them; only deliberate edits mark the Study changed');
  assert.equal(await page.evaluate(()=>runCalls),0);assert.deepEqual(errors,[]);
  await page.screenshot({path:path.join(out,'restored-design-variables.png')});
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(checks.join('\n'));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
