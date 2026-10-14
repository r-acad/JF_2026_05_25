'use strict';
// node flight_conditions_app_test.cjs <fixture-dir> <evidence-dir> [playwright-module]
// Native fixture from atmosphere_test.jl. No backend solve or Study file write.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const args=process.argv.slice(2);if(args.length<2||args.length>3)throw Error('Usage: flight_conditions_app_test.cjs <fixture-dir> <evidence-dir> [playwright-module]');
const [fixtureArg,outArg,moduleArg]=args,fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web');
const {chromium}=require(moduleArg?path.resolve(moduleArg):(process.env.WING_PLAYWRIGHT_MODULE||'playwright'));
const close=(a,b,tol=1e-10)=>assert.ok(Math.abs(a-b)<=tol*Math.max(1,Math.abs(a),Math.abs(b)),`${a} != ${b}`);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[];
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1600,height:1100}});
 try{
  page.on('pageerror',e=>errors.push(e.stack));const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43989/**',route=>{const name=new URL(route.request().url()).pathname;return route.fulfill(name.endsWith('.js')?{contentType:'application/javascript',body:fs.readFileSync(path.join(web,name),'utf8')}:{contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')});});
  await page.goto('http://127.0.0.1:43989/');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:app.slice(0,app.indexOf('(async function start()'))});
  await page.evaluate(({bytes,schema})=>{
   initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.data=MessagePack.decode(Uint8Array.from(bytes));state.values=state.data.model_params;
   state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;buildForm(state.schema,state.values);buildModel(state.data);setBusy(false);
   document.getElementById('activity-status').hidden=true;document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;
   activateWorkspaceTab('cases');state.engine.resize();state.scene.render();
  },{bytes:Array.from(fs.readFileSync(path.join(fixture,'payload.msgpack'))),schema:JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'))});
  await page.locator('#case-speed_unit').selectOption('Mach');await page.locator('#case-speed').fill('0.4');
  const before=await page.evaluate(()=>collectParams());
  await page.locator('#case-altitude_unit').selectOption('FL');await page.locator('#case-altitude').fill('');await page.locator('#case-altitude').fill('300');
  const high=await page.evaluate(()=>({p:collectParams(),c:WingFlightConditions.condition(effectiveCase(null)),dirty:state.studyDirty,mesh:state.modelDirty}));
  close(high.c.Mach,.4);close(high.c.pressure_altitude_ft,30000);assert(high.p['aero.speed']<before['aero.speed']);assert(high.dirty&&high.mesh);
  close(Number(await page.locator('#case-speed').inputValue()),.4);assert.match(await page.locator('#case-atmosphere-summary').textContent(),/T .* K.*p .* Pa.*ρ .*kg\/m³.*q .*Pa/);
  checks.push('FL300 means30000 pressure feet; altitude changes retain enteredMach and update canonicalTAS; edits dirtyStudy andmesh');
  await page.locator('#case-speed_unit').selectOption('knots');await page.locator('#case-altitude_unit').selectOption('ft');
  const converted=await page.evaluate(()=>collectParams());close(converted['aero.speed'],high.p['aero.speed']);close(converted['aero.altitude'],high.p['aero.altitude']);
  close(Number(await page.locator('#case-speed').inputValue()),high.p['aero.speed']*3600/1852);
  assert(Number(await page.locator('#case-altitude').inputValue())>30000);
  checks.push('Unit switches preserve physical speed/altitude; geometricfeet are distinguished from pressurefeet');
  await page.locator('#case-atmosphere').selectOption('manual');assert(await page.locator('#case-density').isVisible());
  const manual=await page.evaluate(()=>({p:collectParams(),c:WingFlightConditions.condition(effectiveCase(null))}));
  close(manual.c.density_kg_m3,high.c.density_kg_m3);close(manual.c.speed_of_sound_m_s,high.c.speed_of_sound_m_s);
  await page.locator('#case-speed_unit').selectOption('Mach');await page.locator('#case-speed_of_sound').fill('');await page.locator('#case-speed_of_sound').fill('330');
  close((await page.evaluate(()=>collectParams()))['aero.speed'],132);assert.match(await page.locator('#case-atmosphere-summary').textContent(),/temperature and pressure are unspecified/);
  checks.push('Switch toManual keepsderiveddensity/sound; manualsoundchanges keepMach; blankdraft canberepaired');
  await page.locator('#btn-duplicate-load-case').click();const duplicated=await page.evaluate(()=>({id:state.editingCase,c:effectiveCase(state.loadCases.find(c=>c.id===state.editingCase))}));
  assert.equal(duplicated.c.atmosphere,'manual');assert.equal(duplicated.c.speed_unit,'Mach');close(duplicated.c.speed,132);
  await page.locator('#case-atmosphere').selectOption('isa1976');await page.locator('#case-altitude_unit').selectOption('m');await page.locator('#case-altitude').fill('2000');
  const saved=await page.evaluate(()=>JSON.parse(JSON.stringify(collectParams())));
  assert.equal(saved['aero.atmosphere'],'manual');const extra=saved['loads.cases'].find(c=>c.id===duplicated.id);assert.equal(extra.atmosphere,'isa1976');assert.equal(extra.altitude,2000);assert.equal(extra.speed_unit,'Mach');
  await page.evaluate(params=>{buildForm(state.schema,params);activateWorkspaceTab('cases');},saved);
  assert.equal(await page.locator('#case-altitude').inputValue(),'2000');close(Number(await page.locator('#case-speed').inputValue()),.4);
  assert.deepEqual(await page.evaluate(()=>collectParams()),saved);checks.push('Duplicate case andJSONstudyparameterreload preserve units, SI quantities and independentatmosphere');
  await page.locator('#case-speed').fill('.51');assert.match(await page.locator('#case-atmosphere-summary').textContent(),/VLM requires Mach ≤ 0.5/);await page.locator('#case-speed').fill('.4');
  await page.screenshot({path:path.join(out,'flight-condition-isa.png')});
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'browser_summary.json'),JSON.stringify({passed:true,checks,high,manual,duplicated,saved,errors},null,2));console.log('Flight-condition app: '+checks.length+' checks passed');
 }catch(error){fs.writeFileSync(path.join(out,'browser_failure.json'),JSON.stringify({error:error.stack,errors},null,2));await page.screenshot({path:path.join(out,'browser_failure.png')}).catch(()=>{});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
