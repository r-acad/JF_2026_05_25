'use strict';
// Portable UI-contract regression. Synthetic recovery is explicitly used here;
// numerical formulations have separate tests. No solver or running app required.
// node rf_report_context_browser_test.cjs OUTPUT_DIR [PLAYWRIGHT_MODULE]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [output,modulePath='playwright']=process.argv.slice(2),out=path.resolve(output),web=path.resolve(__dirname,'../web');
const {chromium}=require(modulePath),origin='http://127.0.0.1:43991';
const scripts=['color_scales','panel_table_data','component_table_data','material_allowables','euler_column_data','stringer_blade_data','skin_buckling_data','component_buckling_data','minimum_rf_data','stress_report_data','reserve_factor_table_data','rf_field_data','stress_report_snapshot','reserve_factor_table_window','stress_report'];
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],checks=[];
 const browser=await chromium.launch({headless:true,channel:process.env.CHROME_PATH?undefined:'chrome',executablePath:process.env.CHROME_PATH||undefined});
 try{
  const context=await browser.newContext({viewport:{width:1500,height:1050}}),page=await context.newPage();page.setDefaultTimeout(20000);
  context.on('page',p=>p.on('pageerror',e=>errors.push(e.stack)));
  await context.route(origin+'/**',route=>{const p=new URL(route.request().url()).pathname;return p==='/'?route.fulfill({contentType:'text/html',body:'<!doctype html><title>RF context regression</title><main id="host"></main>'+scripts.map(f=>'<script src="'+f+'.js"></script>').join('')}):route.fulfill({path:path.join(web,p)});});
  await page.goto(origin+'/');
  await page.evaluate(()=>{
   const shell={type:'PSHELL',material_id:1,material:{id:1,type:'MAT1'}},laminate={type:'PCOMP',plies:[1,2].map(()=>({material_id:8,material:{id:8,type:'MAT8'}}))};
   const e=(pid,p)=>({group:{pid,kind:'quad',name:'Synthetic P'+pid,properties:p}}),vm=x=>({stress:{z1:{von_mises:x},z2:{von_mises:x}}});
   const strain=e1=>({strain:{ply_faces_complete:true,ply_faces_coordinate_system:'ply material 1/2 axes',ply_faces:[1,2].map(ply=>({ply,material_id:8,bottom:{e1,e2:0,g12:0},top:{e1,e2:0,g12:0}}))}});
   const recovered=x=>({analysis:'SOL101_STATIC',available:true,status:'complete',matches:true,static:{},signature:'synthetic',meshIdentity:1,elementResults:{1:vm(100e6),2:vm(50e6),3:strain(x)}});
   globalThis.fixture={generated:false,studyEpoch:1,signature:'synthetic',meshIdentity:1,elements:new Map([[1,e(10,shell)],[2,e(20,shell)],[3,e(40,laminate)],[4,e(50,shell)]]),cases:new Map([[1,recovered(.02)],[2,recovered(.002)]]),allowables:[{material_id:1,mode:'stress',stress:300e6},{material_id:8,mode:'strain',strain_tension:.01,strain_compression:.006}]};
   globalThis.activeField=null;globalThis.ui=WingStressReport.install({document,host:document.getElementById('host'),readContext:()=>fixture,onShowField:request=>{activeField={request,contour:WingRFFieldData.build(fixture,request)};return{active:true,message:'Synthetic field ready'};},onClearField:()=>{activeField=null;return{active:false};}});ui.refresh(true);
  });
  assert.equal(await page.locator('#stress-report-failure-mode').inputValue(),'von_mises');
  assert.equal(await page.locator('#stress-report-field-kind option').count(),3);
  assert.equal(await page.locator('#stress-report-field-palette').count(),0);
  await page.locator('#stress-report-failure-mode').selectOption('minimum_rf');
  await page.locator('#stress-report-show-field').click();
  await page.waitForFunction(()=>activeField?.contour.failureMode==='minimum_rf');
  assert.equal(await page.locator('#stress-report-failure-mode').inputValue(),'minimum_rf');
  const summary=await page.evaluate(()=>({table:ui.report.rows.filter(r=>r.complete&&r.reserveFactor<1).map(r=>r.pid),field:[...activeField.contour.failingElementIds].map(id=>fixture.elements.get(id).group.pid),missing:ui.report.rows.find(r=>r.pid===50)}));
  assert.deepEqual(summary.table,[40]);assert.deepEqual(summary.field,[40]);assert.equal(summary.missing.reserveFactor,null);assert.equal(summary.missing.complete,false);checks.push('Selecting Minimum RF uses that same table assessment for the field, including laminate checks; missing recovery remains unassessed.');
  await page.locator('#stress-report-field-only-failing').check();
  const pending=page.waitForEvent('popup');await page.locator('#btn-reserve-factor-table').click();const popup=await pending;
  await popup.waitForFunction(()=>document.querySelectorAll('.rf-value[data-value]').length===1);
  assert(await popup.locator('#only-below-one').isChecked());assert.equal(await popup.locator('#structural-group').inputValue(),'all');assert.equal(await popup.locator('#table-view').inputValue(),'flat');
  assert.equal(await popup.locator('.rf-value[data-value]').getAttribute('data-value'),'0.5');
  checks.push('The detached property list opens with the same failing set and full model scope.');
  await popup.locator('#only-below-one').uncheck();await page.waitForFunction(()=>!document.getElementById('stress-report-field-only-failing').checked&&!activeField.request.onlyBelowOne);
  await page.locator('#stress-report-field-only-failing').check();await popup.waitForFunction(()=>document.getElementById('only-below-one').checked);checks.push('RF < 1 filtering synchronizes in both directions.');
  await popup.locator('#failure-mode').selectOption('principal_strain');await page.waitForFunction(()=>ui.report.failureMode==='principal_strain'&&activeField.request.failureMode==='principal_strain');
  assert.equal(await page.locator('#stress-report-field-kind').inputValue(),'rf:principal_strain');assert.match(await page.locator('#stress-report-table').textContent(),/0\.01.*0\.02.*0\.5/);checks.push('Laminate principal-strain assessment can be selected in the table and displays dimensionless limits and demand.');
  await page.locator('#stress-report-field-kind').selectOption('critical_failure');await popup.waitForFunction(()=>document.getElementById('failure-mode').value==='minimum_rf');assert.equal(await page.locator('#stress-report-failure-mode').inputValue(),'minimum_rf');
  await page.locator('#stress-report-case').selectOption('2');await popup.waitForFunction(()=>document.querySelectorAll('.rf-value[data-value]').length===0);assert.equal(await page.evaluate(()=>activeField.contour.failingElementIds.size),0);
  await page.locator('#stress-report-case').selectOption('all');await popup.waitForFunction(()=>document.querySelectorAll('.rf-value[data-value]').length===1);checks.push('Critical-category fields and changing load-case scope retain the shared numerical RF predicate.');
  await popup.locator('#failure-mode').selectOption('von_mises');await page.waitForFunction(()=>activeField.request.failureMode==='von_mises');await popup.waitForFunction(()=>document.querySelectorAll('.rf-value[data-value]').length===0);
  assert.equal(await page.getByRole('button',{name:'Edit material allowables',exact:true}).count(),0);
  await page.locator('#stress-report-field-only-failing').uncheck();
  await page.evaluate(async()=>{fixture.allowables=fixture.allowables.map(a=>a.material_id===1?{...a,stress:300e9}:a);await ui.refresh(true);ui.report.rows.find(r=>r.pid===10).approximation=true;ui.report.rows.find(r=>r.pid===10).governingApproximation=true;});
  await page.locator('#stress-report-reserve').click();
  // This synthetic approximation marker was assigned after the report was
  // published. Reconnect to take a fresh snapshot, as a newly built report does.
  await popup.reload();
  await popup.waitForFunction(()=>document.querySelector('.rf-value[data-value="3000"]'));
  for(const value of ['3000','6000'])assert.equal(await popup.locator('.rf-value[data-value="'+value+'"]').textContent(),'999');
  assert.match(await popup.locator('#rf-limits').textContent(),/cap 999.*999 to 999/);
  assert.match(await page.locator('#stress-report-table').textContent(),/999 \(100-term approx\.\)/);
  assert.match(await popup.locator('#reserve-factor-table').textContent(),/100-term plate approximation/);
  assert.equal(await page.evaluate(()=>ui.report.rows.find(r=>r.pid===10).reserveFactor),3000);
  checks.push('Inline and detached RFs, high-value number overlays and legend cap at999; raw RF3000 remains unchanged and approximation status is visible.');
  assert.deepEqual(errors,[]);await popup.screenshot({path:path.join(out,'rf-report-context.png')});fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,synthetic:true,checks,errors},null,2));console.log(checks.length+' RF context browser checks passed.');
 }finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
