'use strict';
// Run against a local Boxer server using a small generated model.
// node movable_surfaces_browser_test.cjs URL OUTPUT [PLAYWRIGHT]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [url,out,modulePath='playwright']=process.argv.slice(2);if(!url||!out)throw Error('Expected URL and OUTPUT');fs.mkdirSync(out,{recursive:true});
const {chromium}=require(modulePath);
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1900,height:1200}}),errors=[],requests=[];page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(r.url().includes('/api/'))requests.push(r.url());});
 const waitPreview=async n=>page.waitForFunction(n=>state.movablePreview?.meshes.length===2*n&&document.querySelector('#movable-status')?.textContent.startsWith(n+' movable'),n,{timeout:120000});
 try{
  await page.goto(url);await page.getByRole('button',{name:'Start new study',exact:true}).click();
  await page.waitForFunction(()=>state.data?.nodes?.count&&!state.meshBuilding,null,{timeout:180000});
  await page.locator('#auto-mesh').uncheck();
  await page.evaluate(()=>{window.originalFE=Array.from(state.baseline);window.originalSignature=formSignature();window.originalJob=state.jobSignature;});
  await page.locator('#tab-geometrymenu').click();await page.locator('#tab-movablesurfaces').click();
  await page.locator('#movable-add').click();let surface=page.locator('.movable-surface').nth(0);
  await surface.locator('[data-movable-field=name]').fill('Inboard flap');await surface.locator('[data-movable-field=deflection]').fill('20');await waitPreview(1);
  await page.locator('#movable-add').click();surface=page.locator('.movable-surface').nth(1);
  await surface.locator('[data-movable-field=name]').fill('Outboard aileron');await surface.locator('[data-movable-field=eta_start]').fill('0.7');await surface.locator('[data-movable-field=eta_end]').fill('0.9');await surface.locator('[data-movable-field=deflection]').fill('-12');await waitPreview(2);
  await page.locator('#movable-add').click();surface=page.locator('.movable-surface').nth(2);
  await surface.locator('[data-movable-field=name]').fill('Leading slat');await surface.locator('[data-movable-field=kind]').selectOption('slat');await surface.locator('[data-movable-field=edge]').selectOption('leading');await surface.locator('[data-movable-field=eta_start]').fill('0');await surface.locator('[data-movable-field=eta_end]').fill('0.9');await surface.locator('[data-movable-field=hinge_start]').fill('0.12');await surface.locator('[data-movable-field=hinge_end]').fill('0.18');await surface.locator('[data-movable-field=deflection]').fill('15');await waitPreview(3);
  await page.locator('.movable-surface').nth(1).locator('[data-movable-field=eta_end]').fill('1');await waitPreview(3);
  assert.equal(await page.locator('#movable-plan-view polygon').count(),4);
  await page.locator('#movable-plan-view').scrollIntoViewIfNeeded();const box=await page.locator('#movable-plan-view').boundingBox();
  await page.mouse.move(box.x+box.width*.5,box.y+30);await page.mouse.down({button:'right'});await page.mouse.move(box.x+box.width*.5+35,box.y+45);await page.mouse.up({button:'right'});
  assert(await page.evaluate(()=>document.querySelector('#movable-plan-view').wingViewport.capture().viewport.x>0));
  assert(await page.evaluate(()=>!!document.querySelector('#movable-plan-view .svgv-geometry polygon')));
  await page.locator('#movable-plan-view').evaluate(e=>e.wingViewport.fit());
  const stable=await page.evaluate(()=>({sameNodes:JSON.stringify(Array.from(state.baseline))===JSON.stringify(originalFE),sameSignature:formSignature()===originalSignature,sameJob:state.jobSignature===originalJob,dirty:state.modelDirty,rows:collectParams()['movable_surfaces.items']}));
  assert(stable.sameNodes&&stable.sameSignature&&stable.sameJob&&!stable.dirty);assert.equal(stable.rows.length,3);
  await page.locator('#show-movable-preview').uncheck();assert(await page.evaluate(()=>state.movablePreview.meshes.every(m=>!m.isEnabled())));await page.locator('#show-movable-preview').check();
  surface=page.locator('.movable-surface').nth(1);await surface.locator('[data-movable-field=eta_start]').fill('0.6');
  await page.waitForFunction(()=>document.querySelector('#group-movable-surfaces').dataset.invalidMessage.includes('overlap'));
  await page.waitForFunction(()=>!state.movablePreview);await surface.locator('[data-movable-field=eta_start]').fill('0.7');await waitPreview(3);
  await page.evaluate(()=>{applyBackgroundColor('#ffffff',false);fitView();state.camera.beta=.95;state.camera.alpha=-.9;});await page.waitForTimeout(500);
  await page.screenshot({path:path.join(out,'movable-surfaces.png')});
  await page.evaluate(()=>activateWorkspaceTab('displayproperties'));
  const button=page.locator('#property-display-show');assert.equal(await button.evaluate(e=>getComputedStyle(e).backgroundColor),'rgb(40, 122, 192)');await button.click();assert.equal(await button.evaluate(e=>getComputedStyle(e).backgroundColor),'rgb(40, 122, 192)');
  await page.screenshot({path:path.join(out,'property-colors-blue.png')});
  const saved=await page.evaluate(async()=>{const params=collectParams();params['references.items']=[];const response=await postParams('/api/validate_workspace',params),body=await response.json();if(!response.ok)throw Error(body.error);return WingWorkspace.snapshot(body.parameters,state.reference,WingWorkspace.captureView(document,state,workspaceUI),{notes:state.studyNotes});});
  const file=path.join(out,'movable-surfaces.study.json');fs.writeFileSync(file,JSON.stringify(saved,null,2));
  await page.locator('#model-file').setInputFiles(file);await page.locator('.study-comments-open').click();
  await page.waitForFunction(()=>state.studyFile==='movable-surfaces.study.json'&&!state.workspaceBusy,null,{timeout:180000});await waitPreview(3);
  assert.deepEqual(await page.evaluate(()=>collectParams()['movable_surfaces.items']),stable.rows);
  await page.evaluate(()=>state.parameterLocks.set('planform',true));assert(await page.locator('#movable-add').isDisabled());await page.evaluate(()=>state.parameterLocks.set('planform',false));
  await page.evaluate(()=>activateWorkspaceTab('movablesurfaces'));
  await page.locator('.movable-surface').nth(2).getByRole('button',{name:'Remove surface',exact:true}).click();await waitPreview(2);
  assert.deepEqual(errors,[]);
  const summary={passed:true,surfaces:stable.rows,checks:['Real Geometry menu and editable definitions','Neutral plan and deflected 3D loft previews','Overlap validation clears obsolete geometry','Preview visibility','Existing FEM, job and solver signature unchanged','Blue property colors button before and after selection','Study file loaded using normal file input retains all surface definitions','Planform lock and removal'],apiRequests:requests.length};
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(summary,null,2));console.log(JSON.stringify(summary));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.message,errors,requests,state:await page.evaluate(()=>({status:document.querySelector('#movable-status')?.textContent,validation:document.querySelector('#group-movable-surfaces')?.dataset.invalidMessage,previewMeshes:state.movablePreview?.meshes.length,rows:state.movableEditor?.readDrafts(),model:!!state.data,tab:workspaceUI.activeTab}))},null,2));throw error;}
 finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
