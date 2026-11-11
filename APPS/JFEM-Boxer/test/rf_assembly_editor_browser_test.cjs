'use strict';
// Real browser edits of a shared Euler column: skin and bar in one transaction.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,modulePath='playwright']=process.argv.slice(2),out=path.resolve(outArg),web=path.resolve(__dirname,'../web');
const{chromium}=require(modulePath),{context:fixture,report}=require('./rf_assembly_editor_test.cjs');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({channel:'chrome',headless:true}),page=await browser.newPage({viewport:{width:1500,height:1100}}),errors=[],checks=[];page.on('pageerror',e=>errors.push(e.stack));
 try{
  await page.setContent('<!doctype html><title>Stiffened region</title>');
  for(const file of ['minimum_gauge_inputs.js','panel_table_data.js','component_table_data.js','rf_property_editor.js','rf_assembly_editor.js'])await page.addScriptTag({path:path.join(web,file)});
  await page.addStyleTag({path:path.join(web,'rf_property_editor.css')});
  await page.evaluate(({context,report})=>{window.current=context;window.report=report;window.commits=[];window.drafts=[];window.reject=false;
   window.showEditor=()=>{window.bundle=WingRFAssemblyEditor.related(current,6000001,report);window.editor=WingRFAssemblyEditor.open({document,bundle,onDraftChange:d=>drafts.push(d),onApply:r=>{if(reject)throw Error('Study changed; cancel and reopen.');const result=WingRFAssemblyEditor.prepare(current,r.edits);for(const patch of result.patches)current.parameters[patch.parameter]=patch.rows;commits.push(result);}});};showEditor();},{context:fixture,report});
  const dialog=page.locator('.rf-assembly-editor'),skin=dialog.locator('[data-pid="6000001"]'),bar=dialog.locator('[data-pid="7000001"]');
  assert.equal(await dialog.locator('.rf-assembly-section').count(),3);assert.match(await dialog.textContent(),/complete stringer plus its associated skin/);assert.match(await bar.textContent(),/Euler column buckling/);
  await skin.locator('input[data-field="thickness"]').fill('4.5');await bar.locator('input[data-field="height"]').fill('45');await bar.locator('input[data-field="web_thickness"]').fill('1');
  assert(await dialog.locator('.rf-property-apply').isDisabled());assert.equal(await bar.locator('input[data-field="web_thickness"]').getAttribute('aria-invalid'),'true');assert.equal((await page.evaluate(()=>commits)).length,0);
  assert(await bar.locator('[data-field="web_thickness"].rf-property-cell').evaluate(e=>getComputedStyle(e).backgroundColor==='rgb(102, 45, 53)'));
  checks.push('Actual column membership exposes both skin regions and the stringer; an under-gauge bar draft blocks every write.');
  await bar.locator('input[data-field="web_thickness"]').fill('3');await page.screenshot({path:path.join(out,'coupled-skin-stringer-editor.png')});await dialog.locator('.rf-property-apply').click();await dialog.waitFor({state:'detached'});
  const saved=await page.evaluate(()=>current.parameters['properties.panels']);assert.equal(saved[0].skin.thickness,.0045);assert.equal(saved[0].stringer.height,.045);assert.equal(saved[0].stringer.web_thickness,.003);assert.equal((await page.evaluate(()=>commits)).length,1);assert.equal(await page.evaluate(()=>drafts.at(-1).hasDrafts),false);assert.equal(await page.evaluate(()=>editor.hasDrafts()),false,'A closed editor must release draft ownership for detached-table refresh.');
  checks.push('One Apply preserves simultaneous skin and stringer edits under their shared panel key, closes and clears draft ownership.');
  await page.evaluate(()=>{reject=true;showEditor();});await skin.locator('input[data-field="thickness"]').fill('5');await dialog.locator('.rf-property-apply').click();assert(await dialog.isVisible());assert.match(await dialog.locator('.rf-property-error').textContent(),/Study changed/);assert.equal(await skin.locator('input[data-field="thickness"]').inputValue(),'5');assert.equal((await page.evaluate(()=>commits)).length,1);await dialog.locator('.rf-property-close').click();
  checks.push('Rejected/stale applies retain the complete draft and leave all canonical properties unchanged.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
