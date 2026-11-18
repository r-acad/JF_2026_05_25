'use strict';
// Actual assessed-RF application state and native fixed-section responses.
// node rf_blanket_minimum_browser_test.cjs NATIVE_FIXTURE OUTPUT PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[fixtureArg,outArg,modulePath='playwright']=process.argv.slice(2),fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
const{chromium}=require(modulePath),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8')),stages=JSON.parse(fs.readFileSync(path.join(fixture,'stages.json'),'utf8'));schema.defaults=JSON.parse(JSON.stringify(schema.values));
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],requests=[],checks=[],browser=await chromium.launch({channel:'chrome',headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1600,height:1100}}),page=await context.newPage();page.setDefaultTimeout(60000);page.on('pageerror',e=>errors.push(e.stack));
 const origin='http://127.0.0.1:43971';await context.route(origin+'/**',route=>{const p=new URL(route.request().url()).pathname;
  if(p==='/api/input')return route.fulfill({json:{...schema,ok:true}});
  if(['/api/validate_workspace','/api/restore_workspace'].includes(p))return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
  if(['/api/prepare_workspace','/api/generate'].includes(p)){requests.push(p);return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});}
  if(p==='/api/rf_sections'){
   const parameters=route.request().postDataJSON().parameters,stage=stages.find(s=>stages.every(t=>parameters[t.key]===s.parameters[t.key]));
   if(!stage)return route.fulfill({status:400,json:{error:'No matching native blanket fixture'}});
   requests.push(stage.key);return route.fulfill({json:stage.response});
  }
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated blanket RF regression'}});
  return route.fulfill({path:p==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,p==='/'?'index.html':p)});
 });
 try{
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await page.waitForFunction(()=>state.studyEpoch>0&&!state.workspaceBusy);await page.locator('#btn-create').click();await page.waitForFunction(()=>state.data&&!state.meshRequestInFlight);
  const baseline=await page.evaluate(async()=>{
   state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();state.engine.stopRenderLoop();activateWorkspaceTab('stressreport');
   const records={};for(const[eid,e]of state.elements){const p=e.group.properties;if(e.group.name==='aero')continue;
    if(e.group.kind==='bar'){const input={forces:{axial:-400e6*p.section.area_m2,shear_1:0,shear_2:0,torque:0,moment_a1:0,moment_a2:0,moment_b1:0,moment_b2:0}};records[eid]={...input,...WingRFSizingEstimate.beamRecovery(p,input)};}
    else if(['quad','tria'].includes(e.group.kind)){const input={forces:{fx:400e6*p.thickness_m,fy:0,fxy:0,mx:0,my:0,mxy:0}};records[eid]={...input,...WingRFSizingEstimate.shellRecovery(p,p,input)};}
   }
   const allowables=WingMaterialAllowables.materialsFromGroups(state.data.groups).filter(m=>m.type==='MAT1').map(m=>({material_id:m.id,mode:'stress',stress:300e6}));state.values['materials.allowables']=allowables;document.getElementById('p-materials.allowables').value=JSON.stringify(allowables);
   state.data.load_cases=[{id:1,label:'Frozen internal-force regression',solution:101}];state.loadCases=[];document.getElementById('p-output.solution').value='101';state.values['output.solution']='101';state.modelSignature=formSignature();
   state.resultCases=new Map([[1,{analysis:'SOL101_STATIC',available:true,status:'complete',matches:true,static:{},signature:state.modelSignature,meshIdentity:state.meshIdentity,elementResults:records}]]);setModelDirty(false);markStudySaved();state.stressReport.invalidate();refreshStressReport();await state.stressReport.refresh(true);
   const result={rows:state.stressReport.report.rows.map(r=>({pid:r.pid,value:r.reserveFactor})),meshIdentity:state.meshIdentity,model:state.data,signature:state.modelSignature};window.__blanketBaseline={model:state.data,elements:state.elements,cases:state.resultCases,signature:state.modelSignature};return{rows:result.rows,meshIdentity:result.meshIdentity};
  });
  assert(baseline.rows.some(r=>r.value<1));checks.push('Begin with genuine complete application RF assessments from synthetic recovered internal forces on the native generated model.');
  for(const stage of stages){
   await page.evaluate(key=>{const tab=key.startsWith('leading_edge.')?'leproperties':key.includes('stringer_')?'sections':key.includes('rib_')?'ribproperties':key.includes('spar_')?'sparproperties':'shells';activateWorkspaceTab(tab);document.getElementById('p-'+key).scrollIntoView();},stage.key);
   const input=page.locator('[id="p-'+stage.key+'"]');await input.fill(String(stage.value*1000));await input.dispatchEvent('change');
   await page.waitForFunction(key=>!state.rfSizingPending&&state.rfSectionUpdate?.signature===formSignature()&&state.rfSectionUpdate?.panels&&state.stressReport.report?.estimated===true,stage.key);
   const current=await page.evaluate(()=>({parameters:collectParams(),meshIdentity:state.meshIdentity,estimated:state.stressReport.report.estimated,rows:state.stressReport.report.rows.map(r=>({pid:r.pid,value:r.reserveFactor})),sameModel:state.data===__blanketBaseline.model,sameCases:state.resultCases===__blanketBaseline.cases,sectionProps:state.rfSectionUpdate.groups.map(g=>({pid:g.pid,properties:g.properties}))}));
   for(const key of ['properties.panels','properties.ribs','properties.spar_bays','properties.components'])assert.deepEqual(current.parameters[key],stage.parameters[key],stage.key+' / '+key);
   assert.equal(current.meshIdentity,baseline.meshIdentity);assert.equal(current.sameModel,true);assert.equal(current.sameCases,true);assert.equal(current.estimated,true);assert(current.rows.some(r=>Number.isFinite(r.value)&&r.value>.5+1e-8));
   checks.push(stage.key+': lower local sizes raised, larger overrides retained, native section metadata accepted and fixed-force RF estimates refreshed without remeshing or solving.');
  }
  assert.equal(requests.filter(p=>p==='/api/generate').length,1);assert.deepEqual(errors,[]);await page.screenshot({path:path.join(out,'blanket-rf-updated.png')});fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,requests,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(e){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,checks,requests,errors,state:await page.evaluate(()=>({status:document.getElementById('mesh-status')?.textContent,pending:state.rfSizingPending,estimated:state.stressReport?.report?.estimated,rfError:state.stressReport?.report?.reason}))},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
