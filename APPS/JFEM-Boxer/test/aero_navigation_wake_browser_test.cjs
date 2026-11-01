'use strict';
// Actual app/server; provide a completed two-condition VLM JSON result fixture.
// node aero_navigation_wake_browser_test.cjs URL OUTPUT PLAYWRIGHT RESULT_JSON
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [url,out,modulePath,fixture]=process.argv.slice(2),{chromium}=require(modulePath);
const result=JSON.parse(fs.readFileSync(fixture,'utf8'));fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,channel:process.env.CHROME_PATH?undefined:'chrome',args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1600,height:1000}}),errors=[],checks=[];
 page.on('pageerror',e=>errors.push(e.stack));let signature='';
 await page.route('**/api/aerodynamics/**',async route=>{
  const u=new URL(route.request().url()),action=u.pathname.split('/').pop();
  let body;if(action==='run'){signature=route.request().postDataJSON().signature;body={id:'wake-display-fixture',state:'running'};}
  else if(action==='status')body={state:'done',progress:{stage:'Complete',done:2,total:2},seconds:1};
  else if(action==='results')body={...result,signature};
  else return route.continue();
  await route.fulfill({json:body});
 });
 try{
  await page.goto(url);await page.getByRole('button',{name:'Start new study',exact:true}).waitFor({timeout:90000});
  await page.evaluate(()=>{document.getElementById('auto-mesh').checked=false;document.getElementById('auto-save').checked=false;});
  await page.getByRole('button',{name:'Start new study',exact:true}).click();
  await page.waitForFunction(()=>state.autoMeshReady&&!state.workspaceBusy,null,{timeout:120000});
  const nav=await page.evaluate(()=>({role:document.getElementById('tab-aerostudy').getAttribute('role'),previous:document.getElementById('tab-aerostudy').previousElementSibling.id,parent:parentTab('aerostudy'),display:parentTab('displayaerodynamics')}));
  assert.deepEqual(nav,{role:'tab',previous:'tab-aerodynamics',parent:undefined,display:'displaymenu'});
  await page.evaluate(()=>activateWorkspaceTab('displayaerodynamics'));assert(await page.locator('#show-aero-wakes').isDisabled());assert(await page.locator('#aero-wake-length').isDisabled());
  checks.push('Aerodynamics is a top-level tab immediately after Loads; Display contains Aerodynamics with unavailable wakes disabled.');
  await page.locator('#tab-aerostudy').click();await page.locator('[data-action=run]').click();await page.waitForFunction(()=>state.aerodynamicStudy.result?.cases?.length===2&&!state.aerodynamicStudy.busy);
  await page.getByLabel('Case A',{exact:true}).selectOption('1');
  await page.evaluate(()=>{window.__feData=state.data;window.__feResults=state.results;activateWorkspaceTab('displayaerodynamics');});
  assert(await page.locator('#show-aero-wakes').isEnabled());await page.locator('#show-aero-wakes').check();
  const wake=await page.evaluate(()=>{const m=state.aeroWakeOverlay.mesh,c=state.aerodynamicStudy.selectedCase,p=c.wake_origins[0];return{name:m.name,enabled:m.isEnabled(),pickable:m.isPickable,vertices:m.getTotalVertices(),first:Array.from(m.getVerticesData(BABYLON.VertexBuffer.PositionKind)).slice(0,3),expected:[p[1],p[2],p[0]],caseId:m.metadata.caseId,selected:c.id,unchanged:state.data===__feData&&state.results===__feResults};});
  assert(wake.enabled&&!wake.pickable&&wake.vertices>1&&wake.unchanged);assert.equal(wake.caseId,wake.selected);wake.first.forEach((v,i)=>assert(Math.abs(v-wake.expected[i])<1e-5));
  await page.locator('#aero-wake-length').fill('2');await page.locator('#aero-wake-length').dispatchEvent('change');
  assert.equal(await page.evaluate(()=>state.scene.meshes.filter(m=>m.name==='independent-aero-wake-overlay').length),1);
  assert.match(await page.locator('#aero-wake-note').innerText(),/Case 2/);
  await page.screenshot({path:path.join(out,'fe-wake-overlay.png')});
  await page.locator('#show-aero-wakes').uncheck();assert.equal(await page.evaluate(()=>state.aeroWakeOverlay.mesh.isEnabled()),false);await page.locator('#show-aero-wakes').check();
  const saved=await page.evaluate(()=>{const v=WingWorkspace.captureView(document,state,workspaceUI);WingWorkspace.validateView(v);return v.controls;});assert.equal(saved['show-aero-wakes'],true);assert.equal(saved['aero-wake-length'],'2');
  checks.push('Solved selected-case wakes draw in the FE construction frame, hide/show and change length without modifying FE data; display preferences validate for Study saving.');
  await page.locator('#tab-aerostudy').click();await page.getByLabel('Show case difference A minus B').check();
  assert.equal(await page.evaluate(()=>state.aeroWakeOverlay.mesh.metadata.caseId),2);
  await page.getByLabel('Case A',{exact:true}).selectOption('0');assert.equal(await page.evaluate(()=>state.aeroWakeOverlay.mesh.metadata.caseId),1);
  await page.evaluate(()=>state.aerodynamicStudy.restore(state.aerodynamicStudy.capture()));
  await page.evaluate(()=>activateWorkspaceTab('displayaerodynamics'));assert(await page.locator('#show-aero-wakes').isDisabled());assert.equal(await page.evaluate(()=>state.scene.meshes.filter(m=>m.name==='independent-aero-wake-overlay').length),0);
  checks.push('Difference display keeps real case A wake; case selection updates FE overlay; restored Study discards old wake geometry and disables the option.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(e){await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,errors,checks},null,2));throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
