'use strict';
// Current full application with an actual native schema/mesh. No FE solve.
// NATIVE_FIXTURE OUTPUT PLAYWRIGHT_MODULE
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[fixtureArg,outArg,modulePath='playwright']=process.argv.slice(2),fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
const{chromium}=require(modulePath),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8')),bytes=fs.readFileSync(path.join(fixture,'payload.msgpack')),payload=require('../web/vendor/msgpack.min.js').decode(bytes);schema.defaults=schema.values;
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({channel:'chrome',headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1600,height:1100}}),page=await context.newPage(),checks=[],errors=[],requests=[];page.setDefaultTimeout(60000);page.on('pageerror',error=>errors.push(error.stack));
 const origin='http://127.0.0.1:43979';await context.route(origin+'/**',route=>{const p=new URL(route.request().url()).pathname;
  if(p.startsWith('/api/'))requests.push(p);
  if(p==='/api/input')return route.fulfill({json:{...schema,ok:true,input_file:'SI saved Study regression',units:'SI'}});
  if(['/api/restore_workspace','/api/validate_workspace'].includes(p))return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
  if(['/api/prepare_workspace','/api/generate'].includes(p))return route.fulfill({body:bytes,contentType:'application/msgpack'});
  if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(p.startsWith('/api/'))return route.fulfill({status:404,json:{error:'No solver or external side effects in unit-entry regression'}});
  return route.fulfill({path:p==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,p==='/'?'index.html':p)});
 });
 try{
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await page.waitForFunction(()=>state.studyEpoch>0&&!state.workspaceBusy);await page.locator('#btn-create').click();await page.waitForFunction(()=>state.data&&!state.meshRequestInFlight&&!state.buildingScene&&!state.workspaceBusy);await page.locator('#auto-mesh').uncheck();
  const initial=await page.evaluate(()=>{
   const keys=WingParameterUnits.DIMENSION_KEYS.filter(key=>!key.includes('#')),parameters=collectParams();return{keys,parameters,signature:formSignature(),canonicalSignature:formSignature(parameters),fields:keys.map(key=>{const input=document.getElementById('p-'+key);return{key,text:input.value,model:WingParameterUnits.readModel(input,key),unit:input.closest('.row').querySelector('.unit').textContent,step:input.getAttribute('step'),help:input.title};}),geometry:state.schema.filter(s=>s.unit==='m'&&!keys.includes(s.key)).map(s=>({key:s.key,model:parameters[s.key],display:document.getElementById('p-'+s.key)?.value}))};
  });
  assert.equal(initial.fields.length,16);for(const field of initial.fields){assert.equal(field.unit,'mm');assert.match(field.help,/Enter millimetres/);assert(field.step==='0.1'||field.key==='properties.runout_side'&&field.step==='any',field.key+' retains its mm increment or admits an exact off-grid saved minimum');assert.equal(field.model,schema.values[field.key]);assert.equal(initial.parameters[field.key],schema.values[field.key]);}
  assert.equal(initial.fields.find(f=>f.key==='properties.runout_side').text,'2.236');assert.equal(initial.signature,initial.canonicalSignature);
  for(const g of initial.geometry)assert.equal(g.model,schema.values[g.key],g.key+' remains SI geometry');
  checks.push('All16 minimum dimensions display mm with0.1mm increments while untouched saved SI doubles and signatures round-trip exactly, including the irrational runout side. Geometry remains in metres.');
  const upper=payload.stiffened_panels.panels.filter(p=>p.skin==='upper').slice(0,2);assert.equal(upper.length,2);
  await page.evaluate(({upper,token})=>{document.getElementById('p-properties.panels').value=JSON.stringify(upper.map((p,i)=>({key:p.key,layout_token:token,skin:{thickness:i?.004:.0018}})));state.panelTables?.refresh(true);activateWorkspaceTab('shells');},{upper,token:payload.stiffened_panels.layout_token});
  const skin=page.locator('[id="p-properties.t_skin_upper"]');await skin.fill('2.5');await skin.dispatchEvent('change');
  const edited=await page.evaluate(()=>collectParams());assert.equal(edited['properties.t_skin_upper'],.0025);assert.equal(edited['properties.panels'].find(r=>r.key===upper[0].key)?.skin.thickness,.0025);assert.equal(edited['properties.panels'].find(r=>r.key===upper[1].key)?.skin.thickness,.004);
  await page.screenshot({path:path.join(out,'skin-minimum-mm.png')});checks.push('Entering2.5mm raises undersized local skin overrides to0.0025m and retains larger4mm overrides.');
  await page.evaluate(()=>activateWorkspaceTab('sections'));const flange=page.locator('[id="p-properties.stringer_flange_width"]');await flange.fill('35');await flange.dispatchEvent('change');
  const section=await page.evaluate(()=>({parameters:collectParams(),area:Number(document.getElementById('stringer-section-editor').dataset.areaM2),notes:document.querySelector('#stringer-section-editor .section-orientation-note').textContent}));
  const p=section.parameters,b=p['properties.stringer_flange_width'],h=p['properties.stringer_height'],tf=p['properties.stringer_flange_thickness'],tw=p['properties.stringer_web_thickness'];assert.equal(b,.035);assert(Math.abs(section.area-(b*tf+(h-tf)*tw))<1e-14);assert.match(section.notes,/in mm/);
  await page.screenshot({path:path.join(out,'stringer-minimum-mm.png')});checks.push('Section previews interpret35mm as0.035m and retain the correct SI area and minimum-gauge behaviour.');
  await page.evaluate(()=>activateWorkspaceTab('sparproperties'));const cap=page.locator('[id="p-properties.spar_cap_side"]');await cap.fill('25');await cap.dispatchEvent('change');assert.equal(await page.evaluate(()=>collectParams()['properties.spar_cap_side']),.025);
  await cap.blur();const saved=await page.evaluate(()=>JSON.parse(JSON.stringify(collectParams())));await page.evaluate(saved=>buildForm(state.schema,saved),saved);
  const reloaded=await page.evaluate(()=>collectParams());for(const key of initial.keys)assert.equal(reloaded[key],saved[key]);assert.equal(await page.locator('[id="p-properties.t_skin_upper"]').inputValue(),'2.5');assert.equal(await page.locator('[id="p-properties.spar_cap_side"]').inputValue(),'25');
  checks.push('The edited Study remains SI and rebuilding its forms restores mm values without a second conversion.');
  await page.waitForTimeout(800);assert.equal(requests.filter(p=>p==='/api/generate').length,1);assert(!requests.some(p=>/jfem_run|jfem_start|sensitivity\/run/.test(p)));assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,requests,initial,saved,requestedFESolve:false},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors,requests},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
