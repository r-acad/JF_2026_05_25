'use strict';
// Generated cross-sections with declared synthetic forces exercise UI ownership,
// assessment settings and freshness. This test is not solver validation.
// node euler_report_browser_test.cjs FIXTURE_DIR OUTPUT_DIR PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [fixtureArg,outArg,modulePath='playwright']=process.argv.slice(2),fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
const {chromium}=require(modulePath),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));schema.defaults??=schema.values;
const payload=fs.readFileSync(path.join(fixture,fs.existsSync(path.join(fixture,'payload.msgpack'))?'payload.msgpack':'mesh_payload.msgpack'));
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[];
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1570,height:1080},acceptDownloads:true}),page=await context.newPage();let popup;
 context.on('page',p=>p.on('pageerror',e=>errors.push(e.stack)));page.on('pageerror',e=>errors.push(e.stack));
 const origin='http://127.0.0.1:43972';await context.route(origin+'/**',route=>{const p=new URL(route.request().url()).pathname;
  if(p==='/api/input')return route.fulfill({json:{...schema,ok:true,input_file:'Euler UI fixture',units:'SI'}});
  if(['/api/prepare_workspace','/api/generate'].includes(p))return route.fulfill({body:payload,contentType:'application/msgpack'});
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated UI test'}});
  return route.fulfill({path:p==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,p==='/'?'index.html':p)});
 });
 try{
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await page.waitForFunction(()=>state.data&&state.autoMeshReady&&!state.workspaceBusy);
  const prepared=await page.evaluate(()=>{
   state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();state.engine.stopRenderLoop();
   const columns=state.data.stiffened_panels?.euler_columns;if(!columns?.length)throw Error('Fixture must include generated Euler column sections.');
   window.setSyntheticForce=(zero=false,missing=false)=>{const records={};for(const[eid]of state.elements)records[eid]={forces:{axial:zero?0:-10000,fx:zero?0:-20000,fy:zero?0:-20000,fxy:0},stress:{z1:{von_mises:100e6},z2:{von_mises:120e6}}};if(missing){const term=columns.find(c=>!c.reason)?.stations?.[0]?.force_terms?.[0];if(term)delete records[term.eid];}state.resultCases=new Map(modelCases().map(c=>[Number(c.id),{analysis:'SOL101_STATIC',available:true,status:'complete',matches:true,static:{},signature:state.modelSignature,meshIdentity:state.meshIdentity,elementResults:records}]));setModelDirty(false);refreshStressReport();};
   const mats=WingMaterialAllowables.materialsFromGroups(state.data.groups).filter(m=>m.type==='MAT1');state.values['materials.allowables']=mats.map(m=>({material_id:m.id,mode:'stress',stress:300e6}));document.getElementById('p-materials.allowables').value=JSON.stringify(state.values['materials.allowables']);activateWorkspaceTab('stressreport');setSyntheticForce();return{columns:columns.length,params:state.values['stringers.euler_fixity_coefficient'],signature:formSignature()};
  });
  await page.locator('#stress-report-method').selectOption('trimmed_mean');await page.locator('#stress-report-percentile').fill('0');await page.locator('#stress-report-percentile').blur();
  await page.locator('#stress-report-failure-mode').selectOption('euler_column');assert(await page.locator('#stress-report-method').isDisabled());assert(await page.locator('#stress-report-stress').isDisabled());
  const report=await page.evaluate(()=>state.stressReport.report);assert.equal(report.failureMode,'euler_column');assert.equal(report.rows.length,prepared.columns);assert(report.rows.some(r=>r.reserveFactor!==null),JSON.stringify(report.rows.map(r=>r.reserveFactorReason)));assert(report.rows.every(r=>r.rowKey&&r.euler));
  const pending=page.waitForEvent('popup');await page.locator('#btn-reserve-factor-table').click();popup=await pending;await popup.waitForLoadState();await popup.waitForFunction(()=>document.querySelector('#failure-mode').value==='euler_column');
  assert.match(await popup.locator('#coverage').textContent(),/section-cut\/case/);const group=await popup.locator('#structural-group').inputValue();assert(['upper','lower'].includes(group));
  const count=report.rows.filter(r=>r.locations.some(l=>l.group===group)).length;assert.equal(await popup.locator('.rf-cell').count(),count,'One RF cell per physical stringer; skin cells must not receive Euler RFs.');
  const exports=[];for(const format of['csv','markdown','html']){const pending=page.waitForEvent('download');await page.locator('#stress-report-export-'+format).click();const download=await pending,file=path.join(out,download.suggestedFilename());await download.saveAs(file);const text=fs.readFileSync(file,'utf8');assert.match(text,/Euler/);assert.match(text,/fixity/);exports.push(download.suggestedFilename());}
  checks.push('Full Boxer startup uses actual generated column sections; failure mode switches to force-based RF, disables stress averaging and exports even if a prior stress percentile was invalid.');
  await page.screenshot({path:path.join(out,'euler-parent.png')});await popup.screenshot({path:path.join(out,'euler-columns-grid.png')});
  const reference=report.rows.filter(r=>r.reserveFactor!==null),coefficient=page.locator('[id="p-stringers.euler_fixity_coefficient"]');assert.equal(await coefficient.count(),1);await page.evaluate(()=>activateWorkspaceTab('sections'));await coefficient.fill('4');await coefficient.dispatchEvent('change');
  await page.waitForFunction(()=>state.stressReport.report.rows.some(r=>r.euler?.endFactor===4));const changed=await page.evaluate(()=>({signature:formSignature(),dirty:state.modelDirty,report:state.stressReport.report}));assert.equal(changed.signature,prepared.signature);assert.equal(changed.dirty,false);
  for(const row of reference){const updated=changed.report.rows.find(r=>r.rowKey===row.rowKey);assert(Math.abs(updated.reserveFactor/row.reserveFactor-4/(row.euler.endFactor||1))<1e-10);}
  await popup.waitForFunction(()=>Array.from(document.querySelectorAll('.rf-cell small')).some(n=>n.textContent.includes('c = 4')));checks.push('Changing c to 4 updates parent and detached reserve factors without changing the FE signature or marking the solved model dirty.');
  await page.evaluate(()=>setSyntheticForce(true));await popup.waitForFunction(()=>Array.from(document.querySelectorAll('.rf-value[data-value]')).filter(n=>n.dataset.value).every(n=>n.dataset.value==='99'));
  const sentinel=await page.evaluate(()=>state.stressReport.report.rows);assert(sentinel.some(r=>r.reserveFactor===99));assert(sentinel.filter(r=>r.complete).every(r=>r.reserveFactor===99&&r.euler.noCompression));
  assert.equal(await popup.locator('.rf-high-number').first().evaluate(el=>getComputedStyle(el).color),'rgb(150, 62, 0)');assert.match(await popup.locator('.rf-value[data-value="99"]').first().getAttribute('title'),/No compression/);await popup.screenshot({path:path.join(out,'euler-no-compression-99.png')});
  await page.evaluate(()=>setSyntheticForce(true,true));await page.waitForFunction(()=>state.stressReport.report.rows.some(r=>r.reserveFactor===null&&!r.complete));assert((await page.evaluate(()=>state.stressReport.report.rows)).filter(r=>!r.complete).every(r=>r.reserveFactor===null));
  checks.push('RF 99 appears only for completely recovered noncompressive columns, retains readable dark-orange text with the ordinary palette or confirmed-minimum yellow, and is withheld if required force recovery is missing.');
  await popup.locator('#failure-mode').selectOption('von_mises');await popup.waitForFunction(()=>!document.getElementById('table-error').hidden&&!document.getElementById('failure-mode').disabled);assert.match(await popup.locator('#table-error').textContent(),/percentile/);assert.equal(await popup.locator('#failure-mode').inputValue(),'von_mises');assert.equal(await page.evaluate(()=>state.stressReport.report),null);assert.equal(await popup.locator('.rf-value[data-value]:not([data-value=""])').count(),0);assert(await popup.locator('#export-csv').isDisabled());
  await page.evaluate(()=>{document.getElementById('stress-report-percentile').value='95';setSyntheticForce();});await popup.locator('#failure-mode').selectOption('von_mises');await page.waitForFunction(()=>document.getElementById('stress-report-failure-mode').value==='von_mises');await popup.waitForFunction(()=>document.querySelector('#failure-mode').value==='von_mises'&&!document.querySelector('#failure-mode').disabled);assert(await page.locator('#stress-report-stress').isEnabled());
  await popup.locator('#failure-mode').selectOption('euler_column');await page.waitForFunction(()=>state.stressReport.report.failureMode==='euler_column');checks.push('Detached failure-mode selection synchronizes the parent report in both directions.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,prepared,exports,columns:report.rows.map(r=>({rowKey:r.rowKey,pid:r.pid,rf:r.reserveFactor,euler:r.euler,coverage:r.coverage})),errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure-parent.png')});if(popup)await popup.screenshot({path:path.join(out,'failure-popup.png')});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
