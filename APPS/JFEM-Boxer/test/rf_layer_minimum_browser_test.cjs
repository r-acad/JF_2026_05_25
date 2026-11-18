'use strict';
// Committed face/core minimum edits with actual native laminated-web responses.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[fixtureArg,outArg,modulePath='playwright']=process.argv.slice(2),fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
const{chromium}=require(modulePath),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8')),stages=JSON.parse(fs.readFileSync(path.join(fixture,'stages.json'),'utf8'));schema.defaults=JSON.parse(JSON.stringify(schema.values));
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],requests=[],checks=[],browser=await chromium.launch({channel:'chrome',headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1600,height:1100}}),page=await context.newPage();page.setDefaultTimeout(60000);page.on('pageerror',e=>errors.push(e.stack));
 const origin='http://127.0.0.1:43972';await context.route(origin+'/**',route=>{const p=new URL(route.request().url()).pathname;
  if(p==='/api/input')return route.fulfill({json:{...schema,ok:true}});
  if(['/api/validate_workspace','/api/restore_workspace'].includes(p))return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
  if(['/api/prepare_workspace','/api/generate'].includes(p)){requests.push(p);return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});}
  if(p==='/api/rf_sections'){
   const assignment=route.request().postDataJSON().parameters['materials.shells'].find(r=>r.component==='spar_web'),stage=assignment.kind==='sandwich'&&stages.find(s=>{const expected=s.parameters['materials.shells'].find(r=>r.component==='spar_web');return['face_thickness','core_thickness'].every(key=>assignment[key]===expected[key]);});
   if(!stage)return route.fulfill({status:400,json:{error:'No matching native layer fixture'}});requests.push(stage.field);return route.fulfill({json:stage.response});
  }
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated layer-minimum regression'}});
  return route.fulfill({path:p==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,p==='/'?'index.html':p)});
 });
 try{
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await page.waitForFunction(()=>state.studyEpoch>0&&!state.workspaceBusy);await page.locator('#btn-create').click();await page.waitForFunction(()=>state.data&&!state.meshRequestInFlight);
  const initial=await page.evaluate(async()=>{
   state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();state.engine.stopRenderLoop();activateWorkspaceTab('stressreport');
   const records={};for(const[eid,e]of state.elements){if(e.group.name==='aero')continue;records[eid]=e.group.kind==='bar'?{forces:{axial:-1000,shear_1:0,shear_2:0,torque:0,moment_a1:0,moment_a2:0,moment_b1:0,moment_b2:0},stress:{von_mises:1e6,axial:-1e6}}:{forces:{fx:-300000,fy:0,fxy:0,mx:0,my:0,mxy:0},stress:{z1:{von_mises:1e6},z2:{von_mises:1e6}}};}
   state.data.load_cases=[{id:1,label:'Frozen compression regression',solution:101}];state.loadCases=[];document.getElementById('p-output.solution').value='101';state.values['output.solution']='101';state.modelSignature=formSignature();state.resultCases=new Map([[1,{analysis:'SOL101_STATIC',available:true,status:'complete',matches:true,static:{},signature:state.modelSignature,meshIdentity:state.meshIdentity,elementResults:records}]]);setModelDirty(false);state.stressReport.invalidate();document.getElementById('stress-report-failure-mode').value='spar_web_buckling';await state.stressReport.refresh(true);const row=state.stressReport.report.rows.find(r=>r.panelKey==='front_web:1');if(!Number.isFinite(row?.reserveFactor))throw Error('Native laminated front web must be assessed');window.__layerBaseline={model:state.data,cases:state.resultCases,value:row.reserveFactor};return{value:row.reserveFactor,mesh:state.meshIdentity,components:JSON.parse(document.getElementById('p-properties.components').value)};
  });
  let previous=initial.value;
  for(const stage of stages){
   await page.evaluate(()=>activateWorkspaceTab('sparproperties'));
   const input=page.getByLabel(stage.field==='face_thickness'?'Spar webs minimum face thickness (mm)':'Spar webs minimum core thickness (mm)',{exact:true});
   await input.fill('4');assert.deepEqual(await page.evaluate(()=>JSON.parse(document.getElementById('p-properties.components').value)),stage===stages[0]?initial.components:stages[0].parameters['properties.components']);
   assert.equal(requests.filter(v=>v===stage.field).length,0,'an unfinished input must not request local section changes');
   await input.fill(String(stage.value*1000));await input.dispatchEvent('change');
   await page.waitForFunction(()=>!state.rfSizingPending&&state.rfSectionUpdate?.signature===formSignature()&&!state.stressReport.pending&&state.stressReport.report?.estimated===true);
   await page.evaluate(()=>state.stressReport.refresh());
   const updated=await page.evaluate(()=>{const parameters=collectParams(),row=state.stressReport.report.rows.find(r=>r.panelKey==='front_web:1');return{parameters,value:row.reserveFactor,pending:resultsHavePendingDrafts(),sameModel:state.data===__layerBaseline.model,sameCases:state.resultCases===__layerBaseline.cases};});
   for(const key of ['materials.shells','properties.components','properties.spar_bays'])assert.deepEqual(updated.parameters[key],stage.parameters[key],stage.field+' / '+key);
   assert(updated.value>previous,stage.field+' must increase web capacity at fixed compression');previous=updated.value;assert.equal(updated.pending,false);assert(updated.sameModel&&updated.sameCases);
   checks.push(stage.field+': transient mantissa changes no properties; committed floor raises smaller local layers/totals, preserves larger dimensions/materials and increases assessed web RF from unchanged internal forces.');
  }
  await page.screenshot({path:path.join(out,'layer-rf-updated.png')});
  const face=page.getByLabel('Spar webs minimum face thickness (mm)',{exact:true});await face.fill('bad');assert.equal(await page.evaluate(()=>state.pendingMaterialMinimums.size),1);
  await page.getByLabel('Spar webs construction',{exact:true}).selectOption('monolithic');
  const cancelled=await page.evaluate(()=>({pending:resultsHavePendingDrafts(),parameters:collectParams({includeView:true})}));assert.equal(cancelled.pending,false);assert.equal(cancelled.parameters['materials.shells'].find(r=>r.component==='spar_web').kind,'monolithic');assert.deepEqual(cancelled.parameters['properties.components'],stages.at(-1).parameters['properties.components']);
  checks.push('Switching an invalid unfinished layer draft to Monolithic releases pending ownership, restores only invalid dormant fields and permits Study saving without changing accepted local dimensions.');
  assert.equal(requests.filter(v=>v==='/api/generate').length,1);assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,requests,initialRF:initial.value,finalRF:previous,errors},null,2));console.log(JSON.stringify({passed:true,checks,initialRF:initial.value,finalRF:previous},null,2));
 }catch(e){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,checks,requests,errors,state:await page.evaluate(()=>({status:document.getElementById('mesh-status')?.textContent,pending:state.rfSizingPending,estimated:state.stressReport?.report?.estimated,materialPending:[...state.pendingMaterialMinimums||[]]}))},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
