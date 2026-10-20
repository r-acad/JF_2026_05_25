'use strict';
// node flight_conditions_browser_test.cjs [PLAYWRIGHT] [OUTPUT]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [modulePath='playwright',output]=process.argv.slice(2),web=path.resolve(__dirname,'../web');
const close=(actual,expected)=>assert(Math.abs(actual-expected)<=1e-10*Math.max(1,Math.abs(expected)),`${actual} != ${expected}`);
(async()=>{
 const {chromium}=require(modulePath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined}),page=await browser.newPage({viewport:{width:1000,height:1100}}),errors=[],checks=[];
 page.on('pageerror',error=>errors.push(error.message));
 try{
  await page.setContent('<div id="workspace-content" style="width:360px"><section class="workspace-panel"><div id="load-cases-editor"><div id="case-row-method" class="case-field"><label for="case-method">Method</label><select id="case-method"><option>Prescribed lift</option></select></div><div id="mount"></div><div id="case-row-lift_half" class="case-field"><label>Half lifting-surface lift (N)</label><input value="10000"></div></div><section class="scene-lighting"><label>Studio preset<select aria-label="Lighting preset"><option>All-angle inspection</option></select></label></section></section></div>');
  for(const file of ['style.css','flight_conditions.css','scene_lighting.css','ui_consistency.css'])await page.addStyleTag({path:path.join(web,file)});
  for(const file of ['flight_conditions.js','ui_layout.js'])await page.addScriptTag({path:path.join(web,file)});
  await page.evaluate(()=>{
   window.testCase={method:'analytic',atmosphere:'isa1976',altitude:1000,altitude_unit:'m',speed:100,speed_unit:'m/s',density:1.225,speed_of_sound:340};window.writes=[];
   window.flightEditor=WingFlightConditions.mount({host:document.getElementById('mount'),read:()=>testCase,write:patch=>{Object.assign(testCase,patch);writes.push(patch);}});
   document.getElementById('mount').replaceWith(document.getElementById('case-flight-conditions'));WingUILayout.cases(document);
  });
  assert.equal(await page.locator('.flight-coefficient-settings').getAttribute('open'),null);assert.equal(await page.locator('#case-speed').isVisible(),false);
  assert.equal(await page.locator('#case-flight-conditions').evaluate(el=>el.closest('fieldset')?.id),'case-loading-fields');
  assert(await page.locator('#case-row-lift_half').isVisible());assert(await page.locator('#case-flight-conditions').evaluate(el=>el.getBoundingClientRect().height<70));
  checks.push('Prescribed lift keeps its force visible and folds coefficient-only flight settings into the loading group');
  const initial=await page.evaluate(()=>JSON.stringify(testCase));await page.locator('.flight-coefficient-settings > summary').click();assert(await page.locator('#case-speed').isVisible());
  assert.equal(await page.evaluate(()=>JSON.stringify(testCase)),initial);assert.equal(await page.evaluate(()=>writes.length),0);
  await page.locator('#case-speed_unit').selectOption('Mach');await page.locator('#case-speed').fill('0.4');await page.locator('#case-altitude_unit').selectOption('FL');await page.locator('#case-altitude').fill('300');
  const entered=await page.evaluate(()=>({...testCase}));close(await page.evaluate(()=>WingFlightConditions.condition(testCase).Mach),.4);assert(entered.speed<136);
  checks.push('Expanding settings never changes data; Mach and FL edits still update canonical SI values');
  await page.evaluate(()=>{testCase.method='vortex_lattice';flightEditor.refresh();});assert(await page.locator('#case-speed').isVisible());assert.equal(await page.locator('.flight-coefficient-settings').isVisible(),false);
  assert.equal(await page.locator('#case-speed').count(),1);const vlm=await page.evaluate(()=>({...testCase}));assert.deepEqual(vlm,{...entered,method:'vortex_lattice'});
  await page.locator('#case-speed').fill('0.6');assert.match(await page.locator('#case-atmosphere-summary').textContent(),/VLM requires Mach/);assert(await page.locator('#case-atmosphere-summary').isVisible());await page.locator('#case-speed').fill('0.4');
  checks.push('VLM exposes all settings without duplicated inputs and keeps its Mach warning visible');
  await page.evaluate(()=>{testCase.method='analytic';flightEditor.refresh();});assert.equal(await page.locator('#case-speed').isVisible(),false);close(await page.evaluate(()=>WingFlightConditions.condition(testCase).Mach),.4);
  await page.evaluate(()=>{testCase.speed='';flightEditor.refresh();});assert(await page.locator('#case-flight-condition-warning').isVisible());assert.match(await page.locator('#case-flight-condition-warning').textContent(),/True airspeed/);
  await page.locator('.flight-coefficient-settings > summary').click();await page.waitForFunction(()=>document.getElementById('case-flight-condition-warning').hidden);assert(await page.locator('#case-atmosphere-summary').isVisible());
  await page.locator('#case-speed').fill('.4');assert.equal(await page.locator('#case-atmosphere-summary').evaluate(el=>el.classList.contains('flight-condition-warning')),false);
  const serialized=await page.evaluate(()=>JSON.stringify(testCase));await page.evaluate(value=>{testCase=JSON.parse(value);flightEditor.refresh();},serialized);assert.equal(await page.evaluate(()=>JSON.stringify(testCase)),serialized);
  checks.push('Returning to prescribed lift preserves inputs; collapsed invalid settings report a visible warning, and correction/JSON reload retain values');
  const preset=await page.locator('.scene-lighting select').evaluate(el=>({width:el.getBoundingClientRect().width,parent:el.parentElement.getBoundingClientRect().width}));assert(preset.width>280&&Math.abs(preset.width-preset.parent)<2);
  checks.push('Studio presets use the available form width');assert.deepEqual(errors,[]);
  if(output){fs.mkdirSync(output,{recursive:true});await page.locator('.flight-coefficient-settings > summary').click();await page.screenshot({path:path.join(output,'flight-condition-compact.png')});fs.writeFileSync(path.join(output,'flight-compact-summary.json'),JSON.stringify({passed:true,checks,errors},null,2));}
  console.log(JSON.stringify({passed:true,checks}));
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
