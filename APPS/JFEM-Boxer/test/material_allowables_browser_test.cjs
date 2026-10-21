'use strict';
// Integration against an owned Boxer server, including an actual two-shell solve.
// node material_allowables_browser_test.cjs URL OUTPUT PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[url,out,modulePath='playwright']=process.argv.slice(2);fs.mkdirSync(out,{recursive:true});
const source={kind:'reference',name:'allowables_two_shells.bdf',includes:[],text:`SOL 101
CEND
DISPLACEMENT(PLOT)=ALL
STRESS(PLOT)=ALL
STRAIN(PLOT)=ALL
SPCFORCES(PLOT)=ALL
SUBCASE 1
 SPC=1
 LOAD=2
BEGIN BULK
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,2.,0.,0.
GRID,4,,0.,1.,0.
GRID,5,,1.,1.,0.
GRID,6,,2.,1.,0.
MAT1,1,7.0+10,,.3,2700.
MAT8,81,1.3+11,1.0+10,.3,5.0+9,5.0+9,5.0+9,1600.
PSHELL,101,1,.01,1
PCOMP,102,-.005
,81,.005,30.,YES,81,.005,-30.,YES
CQUAD4,11,101,1,2,5,4
CQUAD4,12,102,2,3,6,5
SPC1,1,123456,1,4
SPC1,1,3456,2,3,5,6
FORCE,2,3,0,1000.,1.,0.,0.
FORCE,2,6,0,1000.,1.,0.,0.
ENDDATA
`};
(async()=>{
 const{chromium}=require(modulePath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1600,height:1050}}),errors=[],checks=[];
 page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(30000);
 const progress=setInterval(async()=>{try{const state=await page.evaluate(()=>({busy:state.workspaceBusy,job:state.jobId,polling:state.polling,activity:document.getElementById('activity-detail').textContent,error:document.getElementById('model-error-text').textContent}));console.log(JSON.stringify(state));fs.writeFileSync(path.join(out,'progress.json'),JSON.stringify({checks,...state},null,2));}catch{}},30000);
 const tab=id=>page.evaluate(id=>activateWorkspaceTab(id),id);
 const save=async(name)=>{const data=await page.evaluate(async()=>{state.allowablesEditor.assertValid();const parameters=state.importedDeck?state.values:(await(await postParams('/api/validate_workspace',collectParams())).json()).parameters;return WingWorkspace.snapshot(parameters,state.reference,WingWorkspace.captureView(document,state,workspaceUI),{modelSource:state.importedDeck?.source,notes:state.studyNotes});});const f=path.join(out,name);fs.writeFileSync(f,JSON.stringify(data));return f;};
 const open=async(f)=>{await page.locator('#model-file').setInputFiles(f);await page.locator('.study-comments-open').click();await page.waitForFunction(name=>state.studyFile===name&&!state.workspaceBusy,path.basename(f),{timeout:300000});};
 try{
  await page.goto(url);await page.getByRole('button',{name:'Start new study',exact:true}).click();await page.waitForFunction(()=>state.data?.nodes?.count&&!state.workspaceBusy&&!state.meshRequestInFlight,null,{timeout:300000});await page.locator('#auto-mesh').uncheck();await tab('material');
  const signature=await page.evaluate(()=>formSignature());await page.locator('#allowable-material').selectOption('1');await page.locator('#allowable-mode').selectOption('stress');await page.locator('#allowable-stress').fill('.32');
  assert.equal(await page.evaluate(()=>readMaterialAllowables()[0].stress),320e6);assert.equal(await page.evaluate(()=>formSignature()),signature);assert.equal(await page.evaluate(()=>state.modelDirty),false);assert.equal(await page.evaluate(()=>state.studyDirty),true);
  const generated=await save('generated-allowables.study.json');await open(generated);await tab('material');assert.equal(await page.locator('#allowable-stress').inputValue(),'0.32');checks.push('Generated stress GPa conversion, unchanged FE identity, dirty Study and actual save/reopen retain criteria.');
  await page.evaluate(source=>loadReferenceSource(source),source);await tab('material');assert(!(await page.locator('#tab-material').isDisabled()));assert(await page.locator('#form').isHidden());assert.deepEqual(await page.evaluate(()=>readMaterialAllowables()),[]);
  await page.locator('#allowable-material').selectOption('81');await page.locator('#allowable-mode').selectOption('strain');for(const[key,value]of Object.entries({strain_tension:.01,strain_compression:.008}))await page.locator('#allowable-'+key).fill(String(value));
  await page.locator('#allowable-material').selectOption('1');await page.locator('#allowable-mode').selectOption('stress');await page.locator('#allowable-stress').fill('320000000');
  const imported=await save('imported-allowables.study.json');await open(imported);await tab('material');assert.equal(await page.evaluate(()=>readMaterialAllowables().length),2);await page.locator('#allowable-material').selectOption('81');assert.equal(await page.locator('#allowable-strain_tension').inputValue(),'0.01');await page.screenshot({path:path.join(out,'material-strain-limits.png')});checks.push('Imported MAT1/MAT8 criteria use source stress units, stay distinct and survive source Study save/reopen; a new deck clears old criteria.');
  await tab('analysis');await page.locator('#btn-jfem').click();await page.waitForFunction(()=>state.results?.static&&!state.polling&&!state.solverStarting,null,{timeout:Number(process.env.JFEM_BROWSER_SOLVE_TIMEOUT_MS)||1800000});await tab('results');
  const assessed=await page.evaluate(()=>{const a=currentMaterialAssessment();return a&&{assessed:a.assessed,total:a.total,worst:a.worst,details:[...a.details],reasons:[...a.reasons],job:state.jobId,outDir:state.results.outDir};});fs.writeFileSync(path.join(out,'actual-solve-assessment.json'),JSON.stringify(assessed,null,2));assert.equal(assessed?.assessed,2);assert.equal(assessed.total,2);
  assert.equal(assessed.details.find(([id])=>id===11)[1].criterion,'Von Mises stress');assert.equal(assessed.details.find(([id])=>id===12)[1].criterion,'Principal strain');
  const select=page.locator('#contour-select');await select.selectOption({label:'Material allowable utilization'});assert(await page.locator('#allowables-result-note').isVisible());await page.screenshot({path:path.join(out,'allowable-utilization.png')});
  const modes=await page.evaluate(()=>{const before=state.activeMode;state.activeMode=0;const unavailable=currentMaterialAssessment()===null;state.activeMode=before;return unavailable;});assert(modes);
  const initial=assessed.details.find(([id])=>id===11)[1].utilization;await tab('material');await page.locator('#allowable-material').selectOption('1');await page.locator('#allowable-stress').fill('160000000');const revised=await page.evaluate(()=>currentMaterialAssessment().details.get(11).utilization);assert(Math.abs(revised-2*initial)<1e-12);assert.equal(await page.evaluate(()=>state.polling),false);await tab('results');await page.evaluate(()=>showElement(12));assert.match(await page.locator('#pick-content').textContent(),/Material allowable check/);checks.push('Actual SOL101 mixed MAT1/MAT8 model assesses both elements from recovered stresses and every ply face; live criteria update ratio without another solve, normalized modes are excluded.');
  const guarded=await page.evaluate(()=>{
   const r=state.results,checks=[];
   for(const[key,value]of [['signature','unrelated-model'],['historical',true],['status','failed'],['meshIdentity','other-mesh'],['convergence',{converged:true,full_load:false,partial:true}]]){
    const old=r[key];r[key]=value;checks.push(currentMaterialAssessment()===null);updateAnalysisValidity();checks.push(!document.getElementById('allowables-result-note').textContent.includes('Maximum '));r[key]=old;
   }
   updateAnalysisValidity();return checks;
  });assert(guarded.every(Boolean));checks.push('Stale signatures, mesh identity, historical, failed and partial nonlinear states cannot retain an allowable assessment or valid-result note.');
  const archives=fs.readdirSync(assessed.outDir,{recursive:true}).filter(name=>name.endsWith('.jfem'));assert(archives.length,'Actual solve must export its binary result');
  const archive=path.join(assessed.outDir,archives[0]);await page.locator('#results-file').setInputFiles(archive);await page.waitForFunction(name=>state.diskResults?.name===name&&!state.workspaceBusy,path.basename(archive),{timeout:120000});assert.deepEqual(await page.evaluate(()=>readMaterialAllowables()),[]);assert.equal(await page.locator('[id="p-materials.allowables"]').inputValue(),'[]');checks.push('Opening an unrelated result archive clears Study allowables and their canonical input.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,errors,checks},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{clearInterval(progress);await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
