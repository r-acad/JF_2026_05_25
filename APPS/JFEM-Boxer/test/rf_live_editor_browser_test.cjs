'use strict';
// Modal interaction contract. The callback is a deterministic presentation
// oracle; FE/recovery accuracy is tested separately by the native RF suite.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,modulePath='playwright']=process.argv.slice(2),out=path.resolve(outArg),web=path.resolve(__dirname,'../web');
const{chromium}=require(modulePath),{context:fixture,report}=require('./rf_assembly_editor_test.cjs');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({channel:'chrome',headless:true}),page=await browser.newPage({viewport:{width:1100,height:1000}}),errors=[],checks=[];page.on('pageerror',e=>errors.push(e.stack));
 try{
  await page.setContent('<!doctype html><title>RF live draft contract</title>');
  for(const file of['numeric_inputs.js','minimum_gauge_inputs.js','assessment_load_policy.js','panel_table_data.js','component_table_data.js','color_scales.js','material_allowables.js','euler_column_data.js','stringer_blade_data.js','skin_buckling_data.js','component_buckling_data.js','minimum_rf_data.js','stress_report_data.js','reserve_factor_table_data.js','rf_panel_scope.js','rf_property_editor.js','rf_assembly_editor.js'])await page.addScriptTag({path:path.join(web,file)});
  await page.addStyleTag({path:path.join(web,'rf_property_editor.css')});
  await page.addStyleTag({content:'td{min-width:230px;white-space:nowrap}'});
  await page.evaluate(({context,report})=>{
   // Match the imported form-contract fixture's intentional scope provider.
   // It has no FE geometry; physical membership is tested by the native suite.
   // Functions cannot survive Playwright serialization, so install it here.
   const physical=WingRFPanelScope;
   report.rows=[{pid:6000001,reserveFactor:report.panelAssessment.value,combined:{assessments:report.panelAssessment.checks.map(check=>({...check,reserveFactor:check.value}))}}];
   window.WingRFPanelScope={...physical,resolve:(input,focus)=>input.fixtureScope||physical.resolve(input,focus),summary:(input,current,scope)=>{
    if(!current?.panelAssessment)return physical.summary(input,current,scope);
    const row=current.rows[0],checks=row.combined.assessments.map(check=>({...check,value:check.reserveFactor}));
    return{...current.panelAssessment,value:row.reserveFactor,checks,estimated:current.estimated,failures:checks.filter(check=>check.value<1).map(check=>({value:check.value,mode:check.mode,scope:check.scope,caseLabel:check.caseLabel}))};
   }};
   window.context=context;window.baseReport=report;window.calls=[];window.commits=[];window.pending=[];window.canonical=JSON.stringify(context.parameters);
   for(const row of report.rows)for(const a of row.combined.assessments)a.scope='Physical rib bay with an intentionally long descriptive name, every component must wrap inside its own card';
   window.showEditor=()=>{const bundle=WingRFAssemblyEditor.related(context,6000001,baseReport);window.editor=WingRFAssemblyEditor.open({document,bundle,
    onPreview:({edits,signal,onProgress})=>new Promise(resolve=>{onProgress({phase:'sections',message:'Updating edited sections…'});calls.push(edits);pending.push({signal,resolve,edits,onProgress});}),
    onApply:result=>commits.push(result)});};showEditor();
  },{context:fixture,report});
  const dialog=page.locator('.rf-assembly-editor'),input=dialog.locator('[data-pid="6000001"] input[data-field="thickness"]'),status=dialog.locator('.rf-property-preview-status');
  await input.fill('4');await page.waitForFunction(()=>calls.length===1);assert.match(await status.textContent(),/Updating edited sections/);assert.equal(await status.getAttribute('aria-busy'),'true');assert.equal(await status.evaluate(el=>getComputedStyle(el,'::before').animationName),'rf-draft-spin');assert.equal(await page.evaluate(()=>JSON.stringify(context.parameters)===canonical),true);assert.equal(await page.evaluate(()=>commits.length),0);
  await page.emulateMedia({reducedMotion:'reduce'});assert.equal(await status.evaluate(el=>getComputedStyle(el,'::before').animationName),'none');assert.notEqual(await status.evaluate(el=>getComputedStyle(el,'::before').content),'none');await page.emulateMedia({reducedMotion:'no-preference'});
  await page.screenshot({path:path.join(out,'live-rf-progress.png')});checks.push('A graphical progress ring and live phase text are exposed with aria-busy; reduced-motion keeps a static visible glyph.');
  await input.fill('5');await page.waitForFunction(()=>calls.length===2);assert.equal(await page.evaluate(()=>pending[0].signal.aborted),true);
  await page.evaluate(()=>{const report=structuredClone(baseReport);report.estimated=true;report.incremental={evaluatedRows:2,reusedRows:101};for(const row of report.rows){row.reserveFactor=.9;for(const a of row.combined.assessments)a.reserveFactor=.9;}pending[1].resolve({report});});
  await page.waitForFunction(()=>document.querySelector('.rf-property-assessment').textContent.includes('RF 0.9'));
  assert.match(await status.textContent(),/Updated 2 physical checks; reused 101/);assert.equal(await status.getAttribute('aria-busy'),'false');assert.equal(await page.evaluate(()=>JSON.stringify(context.parameters)===canonical),true);
  // A superseded response cannot overwrite the latest displayed estimate.
  await page.evaluate(()=>{pending[0].onProgress({phase:'obsolete',message:'Old phase must stay hidden'});const report=structuredClone(baseReport);for(const row of report.rows){row.reserveFactor=.1;for(const a of row.combined.assessments)a.reserveFactor=.1;}pending[0].resolve({report});});await page.waitForTimeout(80);assert.doesNotMatch(await status.textContent(),/Old phase/);
  assert.match(await dialog.locator('.rf-property-assessment').first().textContent(),/RF 0.9/);
  const boxes=await dialog.locator('.rf-property-assessment').evaluateAll(sections=>sections.map(s=>{const a=s.getBoundingClientRect(),t=s.querySelector('table').getBoundingClientRect();return{section:a.right,table:t.right,scroll:s.scrollWidth,width:s.clientWidth};}));
  assert(boxes.every(b=>b.table<=b.section&&b.scroll<=b.width+1),JSON.stringify(boxes));
  checks.push('Draft typing recomputes modal RFs without Apply or Study writes; debouncing and superseded-reply rejection work.');
  checks.push('Long RF mode/case/scope cells wrap within each property card even with hostile global table styles.');
  await page.screenshot({path:path.join(out,'live-rf-editor.png')});
  await input.fill('1');await page.waitForTimeout(400);assert.equal(await page.evaluate(()=>calls.length),2);assert.match(await status.textContent(),/valid property/);assert(await dialog.locator('.rf-property-apply').isDisabled());
  await dialog.getByRole('button',{name:'Cancel',exact:true}).click();assert.equal(await page.evaluate(()=>JSON.stringify(context.parameters)===canonical),true);assert.equal(await page.evaluate(()=>commits.length),0);
  checks.push('Invalid below-gauge drafts pause preview; Cancel discards every uncommitted edit and estimate.');
  await page.evaluate(()=>showEditor());await input.fill('4');await page.waitForFunction(()=>calls.length===3);await dialog.getByRole('button',{name:'Cancel',exact:true}).click();assert.equal(await page.evaluate(()=>pending[2].signal.aborted),true);
  checks.push('Closing a pending preview aborts its request and cannot resurrect modal results.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,syntheticPresentationOracle:true},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
