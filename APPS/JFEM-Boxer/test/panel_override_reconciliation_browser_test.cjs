'use strict';
// node panel_override_reconciliation_browser_test.cjs <url> <out> <playwright> <study.json>
// The optional external study fixture has local stringer overrides and a tapered spar.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [url,out,modulePath,studyFile]=process.argv.slice(2),{chromium}=require(modulePath);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],responses=[];
 const browser=await chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']});
 const page=await browser.newPage({viewport:{width:1600,height:1100}});page.setDefaultTimeout(240000);
 page.on('pageerror',e=>errors.push(e.message));page.on('response',async r=>{if(r.url().endsWith('/api/generate')&&r.status()===409)responses.push(await r.json());});
 const settled=()=>page.waitForFunction(()=>state.data?.nodes?.count&&!state.workspaceBusy&&!state.meshRequestInFlight,null,{timeout:240000});
 const rows=()=>page.evaluate(()=>JSON.parse(document.getElementById('p-properties.panels').value));
 const withoutToken=rows=>rows.map(({layout_token,...rest})=>rest).sort((a,b)=>a.key.localeCompare(b.key));
 const edit=values=>page.evaluate(values=>{for(const [key,value] of Object.entries(values)){document.getElementById('p-'+key).value=typeof value==='object'?JSON.stringify(value):String(value);state.sparEditor?.externalChange(key);parameterEdited(key);}},values);
 try{
  await page.goto(url,{waitUntil:'domcontentloaded'});await page.getByRole('button',{name:'Start new study',exact:true}).waitFor();
  await page.evaluate(()=>{state.defaults=structuredClone(state.values);});
  await page.getByRole('button',{name:'Start new study',exact:true}).click();await settled();await page.locator('#auto-mesh').uncheck();
  const text=fs.readFileSync(studyFile,'utf8'),original=JSON.parse(text).parameters['properties.panels'];
  assert.equal(await page.evaluate(text=>loadModelDefinition(new File([text],'panel-override-regression.wingfem.json',{type:'application/json'})),text),true);
  await settled();await page.locator('#auto-mesh').uncheck();
  assert.deepEqual(withoutToken(await rows()),withoutToken(original));
  checks.push(`The original Study loads with all ${original.length} local assignments intact.`);
  const points=await page.evaluate(()=>structuredClone(collectParams()['box.rear_spar_points']));points[0].dxc+=.001;
  await edit({'box.rear_spar_points':points});assert.equal(await page.evaluate(()=>createFEM({preserveView:true})),true);
  assert.deepEqual(withoutToken(await rows()),withoutToken(original));
  const synced=await page.evaluate(()=>({dirty:state.modelDirty,signatureMatches:state.modelSignature===formSignature(),migration:state.data.stiffened_panels.override_migration}));
  assert(!synced.dirty&&synced.signatureMatches&&synced.migration?.status==='retained',JSON.stringify(synced));
  checks.push('A small rear-spar edit that changes adjacent runout compartments rebuilds and retains every compatible stringer assignment.');
  const current=await rows(),baseline=await page.evaluate(()=>({nodes:state.data.nodes.count,token:state.data.stiffened_panels.layout_token,front:Number(document.getElementById('p-box.front_spar_xc').value)}));
  await edit({'box.front_spar_xc':baseline.front+.0001});assert.equal(await page.evaluate(()=>createFEM({preserveView:true})),false);
  await page.locator('#model-error-review').waitFor({state:'visible'});
  assert.deepEqual(await rows(),current);
  assert.deepEqual(await page.evaluate(()=>({nodes:state.data.nodes.count,token:state.data.stiffened_panels.layout_token})),{nodes:baseline.nodes,token:baseline.token});
  assert.equal(responses.at(-1)?.code,'panel_override_conflict');
  checks.push('A root-stringer count change returns a structured review and preserves the last valid mesh and all assignments.');
  await page.locator('#model-error-review').click();await page.locator('dialog.panel-override-review').waitFor();
  assert.match(await page.locator('dialog.panel-override-review').innerText(),/Physical ribs:.*Stringers:/);
  await page.getByRole('button',{name:'Keep all and return',exact:true}).click();assert.deepEqual(await rows(),current);
  checks.push('Cancelling review keeps every assignment.');
  await page.locator('#model-error-review').click();await page.screenshot({path:path.join(out,'actual-panel-review.png')});
  const compatible=responses.at(-1).compatible_rows;
  await page.getByRole('button',{name:'Keep compatible assignments and rebuild',exact:true}).click();
  await page.waitForFunction(()=>!state.meshRequestInFlight&&!state.modelDirty,null,{timeout:240000});
  assert.deepEqual(await rows(),compatible);
  assert(await page.evaluate(()=>state.modelSignature===formSignature()));
  const snapshot=await page.evaluate(()=>WingWorkspace.snapshot(collectParams(),state.reference,WingWorkspace.captureView(document,state,workspaceUI),{notes:state.studyNotes}));
  assert.deepEqual(snapshot.parameters['properties.panels'],compatible);
  checks.push('Explicit review approval applies exactly the retained rows, rebuilds, and saves a synchronized Study.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'panel_override_reconciliation_browser.json'),JSON.stringify({passed:true,checks,errors,conflict:responses.at(-1)},null,2));
  console.log(JSON.stringify({passed:true,checks}));
 }catch(error){await page.screenshot({path:path.join(out,'actual-panel-review-failure.png')});fs.writeFileSync(path.join(out,'panel_override_reconciliation_browser_failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
