'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
if(process.argv.length<4||process.argv.length>5)throw Error('Usage: node test/fuel_efficiency_form_browser_test.cjs <schema.json> <evidence-directory> [playwright-module]');
const web=path.resolve(__dirname,'../web'),output=path.resolve(process.argv[3]);
const payload=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const {chromium}=require(process.argv[4]||process.env.WING_PLAYWRIGHT_MODULE||'playwright');
fs.mkdirSync(output,{recursive:true});const checks=[],errors=[];
(async()=>{
 const options={headless:true};if(process.env.CHROME_PATH)options.executablePath=process.env.CHROME_PATH;
 const browser=await chromium.launch(options),page=await browser.newPage({viewport:{width:1440,height:1100}});
 try{
  page.on('pageerror',error=>errors.push(error.stack));
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8').replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'');
  await page.setContent(html);
  for(const file of ['style.css','study_files.css','model_workspace.css'])await page.addStyleTag({path:path.join(web,file)});
  for(const file of ['numbers.js','color_scales.js','viewport-legends.js','parameter_locks.js','workspace.js','reference_import.js','imported_analysis.js','summary_export.js'])await page.addScriptTag({path:path.join(web,file)});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:app.slice(0,app.indexOf('(async function start()'))});
  await page.evaluate(payload=>{
   state.schema=payload.schema.filter(spec=>spec.key.startsWith('fuel.')||spec.key==='loads.fuel_percent');state.values=payload.values;
   document.getElementById('auto-mesh').checked=false;state.autoMeshEnabled=false;
   buildForm(state.schema,state.values);document.getElementById('splash').hidden=true;activateWorkspaceTab('fuel');
  },payload);
  const efficiency=page.locator('#group-fuel-tank [id="p-fuel.fill_efficiency"]');
  assert(await efficiency.isVisible());assert.equal(await efficiency.inputValue(),'0.9');
  assert.equal(await efficiency.getAttribute('min'),'0');assert.equal(await efficiency.getAttribute('max'),'1');
  assert.equal(await page.locator('[id="p-fuel.fill_efficiency"]').count(),1);
  const row=page.locator('[id="row-fuel.fill_efficiency"]'),help=row.locator('.help-icon');
  assert.match(await row.locator('label').textContent(),/Fill efficiency factor/);
  const title=await help.getAttribute('title');assert.match(title,/Usable capacity = gross geometric volume/);
  assert.match(title,/without changing the tank boundary/);assert.match(title,/Cases sets Fuel status separately/);
  await help.click();assert.equal(await page.locator('#help-content').textContent(),title);
  await page.screenshot({path:path.join(output,'fill-efficiency-help.png')});await page.locator('#btn-close-help').click();
  await efficiency.fill('0.35');
  const edited=await page.evaluate(()=>collectParams());assert.equal(edited['fuel.fill_efficiency'],.35);assert.equal(edited['loads.fuel_percent'],25);
  for(const value of ['0','1']){await efficiency.fill(value);assert(await efficiency.evaluate(input=>input.checkValidity()));}
  for(const value of ['-0.01','1.01']){await efficiency.fill(value);assert.equal(await efficiency.evaluate(input=>input.checkValidity()),false);}
  await efficiency.fill('0.35');
  await page.evaluate(()=>{state.parameterLocks.set('planform',true);state.parameterLocks.set('mesh',true);});assert(await efficiency.isEnabled());
  await page.screenshot({path:path.join(output,'fill-efficiency-form.png')});
  checks.push('Fuel tank exposes one Fill efficiency factor with default 0.9 and bounds 0..1; help explains usable capacity, uniform allowance and independent case Fuel status.');
  checks.push('Editing efficiency collects 0.35 while preserving case Fuel status 25%; endpoints are accepted and outside-range values invalid. Tank capacity remains editable under Planform/Mesh locks, like existing fuel inputs.');
  assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(output,'fuel-efficiency-browser-summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(checks.join('\n'));
 }catch(error){fs.writeFileSync(path.join(output,'fuel-efficiency-browser-failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(output,'fuel-efficiency-browser-failure.png')});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
