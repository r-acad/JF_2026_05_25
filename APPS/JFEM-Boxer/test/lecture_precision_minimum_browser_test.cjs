'use strict';
// Real application form regression, isolated native mesh fixture. No solver runs.
// node lecture_precision_minimum_browser_test.cjs FIXTURE OUTPUT PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [fixtureArg,outArg,modulePath='playwright']=process.argv.slice(2),fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
const {chromium}=require(modulePath),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));
schema.values['box.end_eta']=.987654321;
schema.values['planform.twist_axis_xc']=.337123456789;
schema.values['properties.t_spar_web']=.0015;
schema.values['properties.spar_bays']=[{bay:1,front_thickness:.003,rear_thickness:.006}];
schema.values['properties.components']=[{key:'front_web:1',thickness:.003},{key:'rear_web:1',thickness:.006}];
schema.values['loft.twist_stations']=[{eta:0,twist:4},{eta:.337123456789,twist:1},{eta:1,twist:-3}];
schema.defaults=schema.values;
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],browser=await chromium.launch({channel:'chrome',headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1600,height:1000}}),page=await context.newPage();page.on('pageerror',e=>errors.push(e.stack));page.setDefaultTimeout(45000);
 const origin='http://127.0.0.1:43969';
 await context.route(origin+'/**',route=>{const url=new URL(route.request().url()),p=url.pathname;
  if(p==='/api/input')return route.fulfill({json:{...schema,ok:true}});
  if(p==='/api/validate_workspace')return route.fulfill({json:{ok:true,parameters:route.request().postDataJSON()}});
  if(['/api/prepare_workspace','/api/generate'].includes(p))return route.fulfill({body:fs.readFileSync(path.join(fixture,'payload.msgpack')),contentType:'application/msgpack'});
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
  if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated lecture regression'}});
  return route.fulfill({path:p==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,p==='/'?'index.html':p)});
 });
 const collect=()=>page.evaluate(()=>JSON.parse(JSON.stringify(collectParams({includeView:true}))));
 try{
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await page.waitForFunction(()=>state.studyEpoch>0&&!state.workspaceBusy);
  await page.locator('#btn-create').click();await page.waitForFunction(()=>state.data&&!state.meshRequestInFlight);
  await page.evaluate(()=>{state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();state.engine.stopRenderLoop();activateWorkspaceTab('loft');});
  const axis=page.locator('[id="p-planform.twist_axis_xc"]');assert.equal(await axis.inputValue(),'0.3371');
  const initial=await collect();assert.equal(initial['planform.twist_axis_xc'],.337123456789);assert.equal(initial['box.end_eta'],.987654321);assert.equal(initial['loft.twist_stations'][1].eta,.337123456789);
  const eta=page.locator('[aria-label="Twist distribution eta"]').nth(1);assert.equal(await eta.inputValue(),'0.3371');
  await axis.fill('.337987654');await axis.dispatchEvent('change');assert.equal(await axis.inputValue(),'0.338');assert.equal((await collect())['planform.twist_axis_xc'],.338);
  await eta.fill('.337987654');await eta.dispatchEvent('change');assert.equal(await eta.inputValue(),'0.338');assert.equal((await collect())['loft.twist_stations'][1].eta,.338);
  checks.push('Coordinate labels use at most4 significant figures in plain decimal; unchanged saved/snap stations remain exact through collection, while committed scalar and nested edits use4digits.');
  await page.evaluate(()=>activateWorkspaceTab('sparproperties'));
  const minimum=page.locator('[id="p-properties.t_spar_web"]');
  await minimum.fill('4');assert.equal((await page.evaluate(()=>JSON.parse(document.getElementById('p-properties.components').value)))[0].thickness,.003,'an unfinished engineering-notation mantissa must not inflate local gauges');
  await minimum.fill('4e-3');await minimum.dispatchEvent('change');
  const raised=await collect();assert.equal(raised['properties.t_spar_web'],.004);assert.equal(raised['properties.components'][0].thickness,.004);assert.equal(raised['properties.components'][1].thickness,.006);assert.equal(raised['properties.spar_bays'][0].front_thickness,.004);assert.equal(raised['properties.spar_bays'][0].rear_thickness,.006);
  const inline=page.locator('#group-spar-properties .component-properties tbody tr').first();assert.equal(Number(await inline.locator('[data-field="front_thickness"]').inputValue()),4);assert.equal(Number(await inline.locator('[data-field="rear_thickness"]').inputValue()),6);
  await minimum.fill('2e-3');await minimum.dispatchEvent('change');const lowered=await collect();assert.equal(lowered['properties.components'][0].thickness,.004);assert.equal(lowered['properties.spar_bays'][0].front_thickness,.004);
  await minimum.fill('5e-3');const savedDraft=await collect();assert.equal(savedDraft['properties.components'][0].thickness,.005);assert.equal(savedDraft['properties.spar_bays'][0].front_thickness,.005);assert.equal(savedDraft['properties.components'][1].thickness,.006);
  checks.push('Committed family minimum increases synchronize inline and detached/local overrides, preserve thicker dimensions, ignore temporary typing states, and do not reduce sized properties when the minimum is lowered.');
  checks.push('Explicit Study collection/save commits a still-focused family minimum and reconciles its dependent local properties.');
  await page.evaluate(()=>activateWorkspaceTab('shells'));const material=page.locator('[data-material-component="upper_skin"]');await material.locator('select').first().selectOption('sandwich');
  const upper=page.locator('[id="p-properties.t_skin_upper"]');await upper.fill('.012');await upper.dispatchEvent('change');const sandwich=await collect(),assignment=sandwich['materials.shells'].find(row=>row.component==='upper_skin');assert.equal(2*assignment.face_thickness+assignment.core_thickness,.012);assert.equal(Number(await material.getByLabel('Upper skin minimum core thickness (mm)',{exact:true}).inputValue()),11);assert(await material.locator('.material-error').isHidden());
  checks.push('Raising a sandwich total minimum updates the core and material controls coherently without changing its face materials.');
  assert.deepEqual(errors,[]);await page.screenshot({path:path.join(out,'minimum-reconciliation.png')});fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
