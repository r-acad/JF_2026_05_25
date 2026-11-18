'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[fixtureArg,outArg,modulePath='playwright']=process.argv.slice(2),fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
const{chromium}=require(modulePath),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));
schema.defaults=structuredClone(schema.values);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],checks=[],browser=await chromium.launch({channel:'chrome',headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1600,height:1100}}),page=await context.newPage();page.on('pageerror',e=>errors.push(e.stack));page.setDefaultTimeout(45000);
 const origin='http://127.0.0.1:43970';await context.route(origin+'/**',route=>{const p=new URL(route.request().url()).pathname;
  if(p==='/api/input')return route.fulfill({json:{...schema,ok:true}});
  if(['/api/validate_workspace','/api/restore_workspace'].includes(p))return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
  if(['/api/prepare_workspace','/api/generate'].includes(p))return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated RF form regression'}});
  return route.fulfill({path:p==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,p==='/'?'index.html':p)});
 });
 try{
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await page.waitForFunction(()=>state.studyEpoch>0&&!state.workspaceBusy);await page.locator('#btn-create').click();await page.waitForFunction(()=>state.data&&!state.meshRequestInFlight);
  const chosen=await page.evaluate(()=>{state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();state.engine.stopRenderLoop();const p=state.data.stiffened_panels.panels.find(p=>state.data.groups.some(g=>g.pid===p.stringer_pid));if(!p)throw Error('Fixture requires PBARL stringer and skin');const assessment={failureMode:'euler_column',modeLabel:'Euler column buckling',reserveFactor:.6,complete:true,propertyIds:[p.shell_pid,p.stringer_pid],scope:p.label,caseLabel:'2.5g'};window.editReport={failureMode:'minimum_rf',rows:[p.shell_pid,p.stringer_pid].map(pid=>({pid,complete:true,reserveFactor:.6,combined:{governingMode:'euler_column',governingModeLabel:'Euler column buckling',assessments:[assessment]}}))};inspectReserveFactor=()=>({contour:{report:editReport}});openReserveFactorPropertyEditor(p.shell_pid);return{skin:p.shell_pid,bar:p.stringer_pid};});
  const dialog=page.locator('.rf-assembly-editor'),skin=dialog.locator('[data-pid="'+chosen.skin+'"] input[data-field="thickness"]'),height=dialog.locator('[data-pid="'+chosen.bar+'"] input[data-field="height"]');
  const skinValue=Number(await skin.inputValue())+1,barValue=Number(await height.inputValue())+10;await skin.fill(String(skinValue));await height.fill(String(barValue));await dialog.locator('.rf-property-apply').click();await dialog.waitFor({state:'detached'});
  const updated=await page.evaluate(ids=>{const c=reserveFactorPropertyContext();return{skin:WingRFPropertyEditor.resolve(c,ids.skin).values.thickness,height:WingRFPropertyEditor.resolve(c,ids.bar).values.height,drafts:state.rfPropertyDrafts,dirty:state.studyDirty};},chosen);
  assert.equal(updated.skin,skinValue/1000);assert.equal(updated.height,barValue/1000);assert.equal(updated.drafts,false);assert.equal(updated.dirty,true);checks.push('Production Study callback atomically retains both skin and bar overrides and marks the Study dirty.');
  await page.evaluate(ids=>openReserveFactorPropertyEditor(ids.skin),chosen);await skin.fill(String(skinValue+1));await page.evaluate(()=>{state.meshIdentity++;});await dialog.locator('.rf-property-apply').click();assert(await dialog.isVisible());assert.match(await dialog.locator('.rf-property-error').textContent(),/Study or mesh changed/);const retained=await page.evaluate(id=>WingRFPropertyEditor.resolve(reserveFactorPropertyContext(),id).values.thickness,chosen.skin);assert.equal(retained,skinValue/1000);await dialog.locator('.rf-property-close').click();checks.push('Production mesh-identity guard rejects stale multi-property edits without partial mutation.');
  await page.screenshot({path:path.join(out,'study-after-coupled-edit.png')});assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors,state:await page.evaluate(()=>({studyEpoch:state.studyEpoch,busy:state.workspaceBusy,error:document.getElementById('model-error-text')?.textContent}))},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
