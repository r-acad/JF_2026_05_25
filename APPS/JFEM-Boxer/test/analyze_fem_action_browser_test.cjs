'use strict';
// Real GUI with native-generated mesh replay and mocked solver lifecycle.
// FIXTURE OUTPUT PLAYWRIGHT_MODULE
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[fixtureArg,outArg,modulePath='playwright']=process.argv.slice(2),fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
const{chromium}=require(modulePath),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8')),mesh=fs.readFileSync(path.join(fixture,'payload.msgpack'));schema.defaults=schema.values;
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({channel:'chrome',headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1600,height:1100}}),page=await context.newPage(),checks=[],errors=[],requests=[],bodies=[];page.setDefaultTimeout(60000);page.on('pageerror',e=>errors.push(e.stack));
 let failGenerate=false,failLaunch=false,status='running',job=0,holdGenerate=null;
 const origin='http://127.0.0.1:43981';await context.route(origin+'/**',async route=>{const p=new URL(route.request().url()).pathname;
  if(p.startsWith('/api/'))requests.push(p);
  if(['/api/generate','/api/run_jfem'].includes(p))bodies.push({path:p,parameters:route.request().postDataJSON()});
  if(p==='/api/input')return route.fulfill({json:{...schema,ok:true}});
  if(['/api/restore_workspace','/api/validate_workspace'].includes(p))return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
  if(['/api/prepare_workspace','/api/generate'].includes(p)){if(holdGenerate)await holdGenerate;if(failGenerate)return route.fulfill({status:400,json:{error:'Deliberate mesh rejection'}});return route.fulfill({body:mesh,contentType:'application/msgpack'});}
  if(p==='/api/run_jfem'){if(failLaunch)return route.fulfill({status:500,json:{error:'Deliberate launch failure'}});job++;status='running';return route.fulfill({json:{job:'mock-'+job,deck:'mock.bdf',deck_lines:1,solution:'SOL101',repo:'Mock backend',command:'Mock lifecycle only'}});}
  if(p==='/api/jfem_status')return route.fulfill({json:{state:status,seconds:1,next_line:0,total_lines:0,lines:[],has_more:false,log_done:true,results_available:false,message:status==='cancelled'?'Cancelled mock job':'Mock job',log_path:'mock.log'}});
  if(p==='/api/jfem_stop'){status='cancelled';return route.fulfill({json:{ok:true}});}
  if(p==='/api/jfem_probe')return route.fulfill({json:{found:true,repo:'Mock backend'}});
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(p.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated action regression'}});
  return route.fulfill({path:p==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,p==='/'?'index.html':p)});
 });
 const analyze=()=>page.locator('#btn-analyze-fem'),create=()=>page.locator('#btn-create'),upper=()=>page.locator('[id="p-properties.t_skin_upper"]');
 const settled=()=>page.waitForFunction(()=>!state.meshRequestInFlight&&!state.buildingScene&&!state.workspaceBusy&&!state.solverStarting);
 async function edit(value){await page.evaluate(()=>activateWorkspaceTab('shells'));await upper().fill(value);await upper().dispatchEvent('change');await page.waitForFunction(()=>state.propertyAnalysisAction?.pending);}
 async function launch(){await analyze().click();await page.waitForFunction(()=>state.polling&&!state.solverStarting&&!state.propertyAnalysisAction.running);assert(await analyze().isHidden());assert(await create().isHidden());}
 try{
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await page.waitForFunction(()=>state.studyEpoch>0&&!state.workspaceBusy);await create().click();await settled();await page.locator('#auto-mesh').uncheck();assert(await analyze().isHidden());
  await page.evaluate(()=>{const key=state.schema.find(s=>s.key.startsWith('planform.')&&s.unit==='m').key,input=document.getElementById('p-'+key);input.value=String(Number(input.value)+.1);parameterEdited(key);});assert(await analyze().isHidden());assert(await create().isVisible());
  await edit('2');assert(await analyze().isVisible());assert(await analyze().isEnabled());assert.equal(await page.evaluate(()=>document.getElementById('btn-analyze-fem').nextElementSibling?.id),'btn-create');await page.screenshot({path:path.join(out,'edited-properties-actions.png')});
  checks.push('Only physical property edits expose the red Analyze FEM action immediately left of Create FEM. A geometry-only edit retains Create FEM.');
  let release;holdGenerate=new Promise(resolve=>release=resolve);const start=requests.length;await analyze().click();await page.waitForFunction(()=>state.meshRequestInFlight);
  assert(await analyze().isHidden());assert(await create().isHidden());assert.equal(await page.evaluate(()=>document.getElementById('form').inert),true);const old=await upper().inputValue();await assert.rejects(upper().click({timeout:300}));assert.equal(await upper().inputValue(),old);
  await page.evaluate(()=>{document.getElementById('btn-analyze-fem').click();document.getElementById('btn-jfem').click();});release();holdGenerate=null;await page.waitForFunction(()=>state.polling&&!state.solverStarting&&!state.propertyAnalysisAction.running);assert.equal(await page.evaluate(()=>document.getElementById('form').inert),false);
  assert.deepEqual(requests.slice(start).filter(p=>['/api/generate','/api/run_jfem'].includes(p)),['/api/generate','/api/run_jfem']);assert(await create().isHidden());assert(await analyze().isHidden());
  checks.push('Analyze regenerates exactly once before one solver launch, blocks form edits and duplicate Run actions during preparation, and hides both actions after launch.');
  await page.evaluate(()=>finishRun(true,'done'));await edit('2.5');assert(await analyze().isVisible());assert(await create().isVisible());failGenerate=true;const g0=requests.filter(p=>p==='/api/run_jfem').length;await analyze().click();await page.waitForFunction(()=>!state.propertyAnalysisAction.running&&!state.solverStarting&&!state.meshRequestInFlight);assert(await analyze().isVisible());assert(await analyze().isEnabled());assert(await create().isVisible());assert.equal(requests.filter(p=>p==='/api/run_jfem').length,g0);failGenerate=false;
  checks.push('A later property edit restores both actions. A rejected mesh restores them without starting the solver.');
  failLaunch=true;await analyze().click();await page.waitForFunction(()=>!state.propertyAnalysisAction.running&&!state.solverStarting&&!state.meshRequestInFlight);assert(await analyze().isVisible());assert(await analyze().isEnabled());assert(await create().isVisible());failLaunch=false;
  await launch();await page.evaluate(()=>activateWorkspaceTab('analysis'));await page.locator('#btn-stop-jfem').click();await page.waitForFunction(()=>!state.polling);assert(await analyze().isVisible());assert(await analyze().isEnabled());assert(await create().isVisible());
  checks.push('A failed launch and a cancelled analysis restore actionable controls and allow retry.');
  await launch();await page.evaluate(()=>finishRun(false,'failed','Deliberate numerical failure'));assert(await analyze().isVisible());assert(await create().isVisible());await launch();await page.evaluate(()=>finishRun(true,'done'));assert(await analyze().isHidden());assert(await create().isHidden());
  checks.push('Numerical failure supports retry and successful reruns keep both actions hidden.');
  const runoutId=await page.evaluate(()=>{activateWorkspaceTab('inspect');return[...state.elements].find(([,e])=>e.group.pid===13)[0];});await page.locator('#inspect-entity').selectOption('bar');await page.locator('#inspect-id').fill(String(runoutId));await page.locator('#btn-inspect-id').click();await page.locator('#inspect-edit-property').click();const editor=page.locator('.rf-property-editor');await editor.locator('input[data-field="side"]').fill('3');await editor.locator('.rf-property-apply').click();await editor.waitFor({state:'detached'});
  assert.equal(await page.evaluate(()=>JSON.parse(document.getElementById('p-properties.components').value).find(row=>row.key==='stringer_runout:1').side),.003);assert(await analyze().isVisible());assert(await create().isVisible());await page.screenshot({path:path.join(out,'P13-local-edit-actions.png')});await launch();
  for(const body of bodies.slice(-2)){const p=body.parameters.parameters||body.parameters;assert.equal(p['properties.components'].find(row=>row.key==='stringer_runout:1').side,.003);}
  await page.evaluate(()=>finishRun(true,'done'));assert(await analyze().isHidden());assert(await create().isHidden());
  await page.evaluate(()=>{const key=state.schema.find(s=>s.key.startsWith('planform.')&&s.unit==='m').key,input=document.getElementById('p-'+key);input.value=String(Number(input.value)+.1);parameterEdited(key);});assert(await analyze().isHidden());assert(await create().isVisible());
  await page.evaluate(()=>{state.studyEpoch++;state.values=collectParams();state.data.model_params=state.values;setBusy(false);});assert(await analyze().isHidden());assert(await create().isVisible());assert.deepEqual(errors,[]);
  checks.push('Normal Inspect P13 resizing exposes the shortcut and sends the same0.003m local override to generation and launch. A subsequent geometry-only edit shows only Create FEM, and a new Study epoch clears the transient state.');
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,requests,errors,mockedSolverLifecycle:true,nativeMeshReplay:true,executedFESolve:false},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,requests,errors,state:await page.evaluate(()=>({action:state.propertyAnalysisAction,busy:state.busy,solverStarting:state.solverStarting,modelDirty:state.modelDirty,log:document.getElementById('log').textContent})).catch(()=>null)},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
