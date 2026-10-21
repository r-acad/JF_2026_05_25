'use strict';
// Real generated section metadata with synthetic sign/coverage scenarios.
// Optional recovered SOL101/SOL106 replay checks UI RFs against independently
// computed critical stresses and arithmetic means; it does not rerun the solver.
// node stringer_blade_report_browser_test.cjs FIXTURE_DIR OUTPUT_DIR PLAYWRIGHT [RECOVERED_FIXTURE_DIR]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [fixtureArg,outArg,modulePath='playwright',recoveredArg]=process.argv.slice(2),fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
const {chromium}=require(modulePath),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));schema.defaults??=schema.values;
const payload=fs.readFileSync(path.join(fixture,'payload.msgpack'));
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[];
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1570,height:1080},acceptDownloads:true}),page=await context.newPage();let popup;
 context.on('page',p=>p.on('pageerror',e=>errors.push(e.stack)));page.on('pageerror',e=>errors.push(e.stack));
 const origin='http://127.0.0.1:43973';await context.route(origin+'/**',route=>{const p=new URL(route.request().url()).pathname;
  if(p==='/api/input')return route.fulfill({json:{...schema,ok:true,input_file:'Blade UI fixture',units:'SI'}});
  if(['/api/prepare_workspace','/api/generate'].includes(p))return route.fulfill({body:payload,contentType:'application/msgpack'});
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated UI test'}});
  return route.fulfill({path:p==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,p==='/'?'index.html':p)});
 });
 try{
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await page.waitForFunction(()=>state.data&&state.autoMeshReady&&!state.workspaceBusy);
  const prepared=await page.evaluate(()=>{
   state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();state.engine.stopRenderLoop();
   const blades=state.data.stiffened_panels?.blade_columns;if(!blades?.length)throw Error('Fixture requires generated blade_columns metadata.');
   state.data.load_cases=[{id:1,label:'Compression SOL101',solution:101},{id:2,label:'Compression SOL106',solution:106}];
   window.setSyntheticBladeStress=(kind='compression')=>{
    const cases=new Map();for(const c of modelCases()){
     const records={};for(const[eid]of state.elements)records[eid]={forces:{axial:-1000,fx:-20000,fy:-20000,fxy:0},stress:{axial:-20e6,z1:{von_mises:100e6},z2:{von_mises:120e6}}};
     for(const blade of blades){const total=blade.bars?.length||0;for(const [i,bar]of(blade.bars||[]).entries()){
      const mean=kind==='no-compression'?(i===0?-20e6:40e6):-(20+i*10)*1e6*(c.id===2?2:1);
      records[bar.eid]={forces:{axial:-1000},stress:{axial:999e6,axial_end_a:mean-2e6,axial_end_b:mean+2e6,z1:{von_mises:900e6}}};
     }}
     if(kind==='missing'){const bar=blades.find(b=>!b.reason&&b.bars?.length)?.bars[0];if(bar)delete records[bar.eid];}
     cases.set(c.id,{analysis:c.solution===106?'SOL106_NONLINEAR_STATIC':'SOL101_STATIC',available:true,status:'complete',matches:true,static:{},signature:state.modelSignature,meshIdentity:state.meshIdentity,elementResults:records,...(c.solution===106?{convergence:{converged:true,full_load:true},loadScale:1}:{})});
    }state.resultCases=cases;setModelDirty(false);refreshStressReport();
   };
   activateWorkspaceTab('stressreport');setSyntheticBladeStress();return{blades:blades.length,supported:blades.filter(b=>!b.reason&&b.bars?.length).length,signature:formSignature()};
  });
  await page.locator('#stress-report-method').selectOption('trimmed_mean');await page.locator('#stress-report-percentile').fill('0');await page.locator('#stress-report-percentile').blur();await page.locator('#stress-report-failure-mode').selectOption('stringer_blade');
  assert(await page.locator('#stress-report-stress').isDisabled());assert(await page.locator('#stress-report-method').isDisabled());
  const report=await page.evaluate(()=>state.stressReport.report);assert.equal(report.failureMode,'stringer_blade');assert.equal(report.rows.length,prepared.blades);assert.equal(report.stressUnit,'MPa');
  const assessed=report.rows.filter(r=>r.complete);assert.equal(assessed.length,prepared.supported);for(const r of assessed){assert(r.reserveFactor>0);assert.match(r.envelopeCaseLabel,/SOL106/);assert(r.blade.averageStress<0);assert.equal(r.blade.compressionDemand,-r.blade.averageStress);assert.equal(r.blade.sourceCount,r.elementCount);}
  assert.match(await page.locator('#stress-report-table thead').textContent(),/Critical buckling stress \(MPa\).*Average compression \(MPa\)/);
  const pending=page.waitForEvent('popup');await page.locator('#btn-reserve-factor-table').click();popup=await pending;await popup.waitForLoadState();await popup.waitForFunction(()=>document.querySelector('#failure-mode').value==='stringer_blade');
  const group=await popup.locator('#structural-group').inputValue();assert(['upper','lower'].includes(group));assert.equal(await popup.locator('.rf-cell').count(),report.rows.filter(r=>r.locations.some(l=>l.group===group)).length);assert.match(await popup.locator('#coverage').textContent(),/bar-element\/case/);
  checks.push(prepared.supported?'Generated blade regions map once per stringer and bay; the new mode uses signed bar stresses, shows MPa, selects the governing SOL106 case and ignores an invalid dormant stress percentile.':'Generated shell-stringer regions map once per bay; the new blade mode shows MPa headings and ignores an invalid dormant stress percentile without inventing an assessment.');
  await page.screenshot({path:path.join(out,'blade-parent.png')});await page.locator('#btn-max-drawing').click();await page.screenshot({path:path.join(out,'blade-parent-maximized.png')});await page.locator('#btn-max-drawing').click();await popup.screenshot({path:path.join(out,'blade-grid.png')});
  for(const host of[page,popup])for(const format of['csv','markdown','html']){
   const pending=host.waitForEvent('download');await host.locator('#'+(host===page?'stress-report-':'')+'export-'+format).click();const download=await pending,file=path.join(out,(host===page?'parent-':'detached-')+download.suggestedFilename());await download.saveAs(file);const text=fs.readFileSync(file,'utf8');assert.match(text,/Stringer blade instability/i);assert.match(text,/MPa/);assert.match(text,/arithmetic mean/);
  }
  for(const option of await popup.locator('#table-palette option').evaluateAll(nodes=>nodes.map(n=>n.value))){await popup.locator('#table-palette').selectOption(option);assert(await popup.locator('#rf-ramp').evaluate(el=>!!el.style.background));}await popup.locator('#table-palette').selectOption('signed');
  await popup.locator('#table-view').selectOption('flat');assert.match(await popup.locator('#reserve-factor-table thead').textContent(),/Critical buckling stress \(MPa\).*Average compression \(MPa\)/);await popup.screenshot({path:path.join(out,'blade-list.png')});await popup.locator('#table-view').selectOption('grid');
  checks.push('Main and detached CSV/Markdown/HTML exports retain the assessment method and units; all six palettes and both table layouts are available.');
  if(prepared.supported){
   const coefficient=page.locator('[id="p-stringers.euler_fixity_coefficient"]');await page.evaluate(()=>activateWorkspaceTab('sections'));await coefficient.fill('4');await coefficient.dispatchEvent('change');await page.evaluate(()=>activateWorkspaceTab('stressreport'));const updated=await page.evaluate(()=>({signature:formSignature(),dirty:state.modelDirty,rows:state.stressReport.report.rows}));assert.equal(updated.signature,prepared.signature);assert.equal(updated.dirty,false);for(const row of assessed)assert.equal(updated.rows.find(r=>r.rowKey===row.rowKey).reserveFactor,row.reserveFactor);
   await page.locator('#stress-report-case').selectOption('1');await popup.waitForFunction(()=>document.querySelector('#case-scope').textContent.includes('Compression SOL101'));const selected=await page.evaluate(()=>state.stressReport.report);for(const row of assessed)assert(Math.abs(selected.rows.find(r=>r.rowKey===row.rowKey).reserveFactor/row.reserveFactor-2)<1e-12);await page.locator('#stress-report-case').selectOption('all');
   await page.evaluate(()=>setSyntheticBladeStress('no-compression'));await popup.waitForFunction(()=>Array.from(document.querySelectorAll('.rf-value[data-value]')).filter(n=>n.dataset.value).every(n=>n.dataset.value==='99'));
   const noCompression=await page.evaluate(()=>state.stressReport.report.rows);assert(noCompression.some(r=>r.reserveFactor===99));assert(noCompression.filter(r=>r.complete).every(r=>r.reserveFactor===99&&r.blade.noCompression));assert.match(await popup.locator('.rf-value[data-value="99"]').first().getAttribute('title'),/individual bars can still be compressive/);assert.equal(await popup.locator('.rf-high-number').first().evaluate(el=>getComputedStyle(el).color),'rgb(150, 62, 0)');await popup.screenshot({path:path.join(out,'blade-no-average-compression.png')});
   await page.evaluate(()=>setSyntheticBladeStress('missing'));await page.waitForFunction(()=>state.stressReport.report.rows.some(r=>r.reserveFactor===null&&!r.complete));assert((await page.evaluate(()=>state.stressReport.report.rows)).filter(r=>!r.complete).every(r=>r.reserveFactor===null));
   await page.evaluate(()=>{setSyntheticBladeStress();state.modelDirty=true;refreshStressReport();});await popup.waitForFunction(()=>document.querySelectorAll('.rf-value[data-value]:not([data-value=""])').length===0);await page.evaluate(()=>{setModelDirty(false);refreshStressReport();});
   checks.push('Euler fixity does not alter blade RF; case selection changes the governing average. RF99 retains an explicit average-compression caveat, while missing bar stress and stale geometry suppress RF.');
  }else{
   assert(report.rows.every(r=>r.reserveFactor===null&&r.reserveFactorReason));assert.equal(await popup.locator('.rf-value[data-value]:not([data-value=""])').count(),0);assert.match(await popup.locator('#reserve-factor-table').textContent(),/shell|PBARL|beam/i);checks.push('Unsupported shell stringers remain visible and unassessed with a reason; no fabricated RF99 or zero geometry.');
  }
  if(recoveredArg){
   const cases=['axial_blade_fixture.json','axial_sol106_blade_fixture.json'].flatMap(file=>JSON.parse(fs.readFileSync(path.join(path.resolve(recoveredArg),file),'utf8')).cases).map((c,i)=>({...c,id:i+1,label:'Recovered '+c.analysis_type+' · case '+c.case_id}));
   const real=await page.evaluate(cases=>{
    state.data.load_cases=cases.map(c=>({id:c.id,label:c.label,solution:Number(c.analysis_type.replace('SOL',''))}));
    state.resultCases=new Map(cases.map(c=>[c.id,{analysis:c.analysis_type,available:true,status:'complete',matches:true,static:{},signature:state.modelSignature,meshIdentity:state.meshIdentity,elementResults:c.element_results,...(c.analysis_type==='SOL106'?{loadScale:c.load_scale,convergence:{converged:c.nonlinear?.converged===true,full_load:c.nonlinear?.final_load_scale===1,partial:c.nonlinear?.final_load_scale!==1}}:{})}]));
    setModelDirty(false);refreshStressReport();return{blades:state.data.stiffened_panels.blade_columns,report:state.stressReport.report};
   },cases);
   assert.equal(real.report.includedCases.length,cases.length);assert(real.report.complete);const verified=[];
   for(const blade of real.blades){
    const capacities=blade.bars.map(b=>.425*Math.PI*Math.PI*b.young_pa/(12*(1-b.poisson*b.poisson))*(b.web_thickness_m/b.web_height_m)**2),critical=Math.min(...capacities);
    const samples=cases.map(c=>{const stresses=blade.bars.map(b=>{const s=c.element_results[b.eid].stress;return s.axial_end_a!==undefined?(s.axial_end_a+s.axial_end_b)/2:s.axial;});assert(stresses.every(Number.isFinite));const mean=stresses.reduce((a,b)=>a+b,0)/stresses.length;return{case:c.label,mean,rf:mean<0?critical/-mean:null};}),ratios=samples.filter(s=>s.rf!==null),expected=ratios.length?Math.min(...ratios.map(s=>s.rf)):99,row=real.report.rows.find(r=>r.panelKey===blade.key);
    assert(row);assert(Math.abs(row.reserveFactor-expected)<=1e-11*Math.max(1,expected));assert(Math.abs(row.blade.criticalStress-critical)<=1e-11*critical);verified.push({rowKey:row.rowKey,pid:row.pid,expectedRF:expected,actualRF:row.reserveFactor,criticalMPa:critical*1e-6,samples});
   }
   await popup.waitForFunction(count=>document.getElementById('coverage').textContent.startsWith(count+' / '),real.report.coverage.recovered);for(const row of real.report.rows.filter(r=>r.locations.some(l=>l.group===group)))assert.equal(Number(await popup.locator('.rf-cell[data-row-key="'+row.rowKey+'"] .rf-value').getAttribute('data-value')),row.reserveFactor);
   await page.locator('#btn-max-drawing').click();await page.screenshot({path:path.join(out,'blade-actual-recovered-parent.png')});await page.locator('#btn-max-drawing').click();await popup.screenshot({path:path.join(out,'blade-actual-recovered-grid.png')});fs.writeFileSync(path.join(out,'actual_recovery_comparison.json'),JSON.stringify({cases:cases.map(({element_results,nonlinear,...c})=>c),verified},null,2));checks.push('Actual recovered SOL101 and converged SOL106 bar stresses pass through Boxer; every parent and detached RF matches an independent critical-stress and signed arithmetic-mean calculation.');
  }
  await popup.locator('#failure-mode').selectOption('euler_column');await page.waitForFunction(()=>state.stressReport.report.failureMode==='euler_column');await popup.waitForFunction(()=>!document.getElementById('failure-mode').disabled);await popup.locator('#failure-mode').selectOption('stringer_blade');await page.waitForFunction(()=>state.stressReport.report.failureMode==='stringer_blade');await popup.waitForFunction(()=>document.getElementById('failure-mode').value==='stringer_blade'&&!document.getElementById('failure-mode').disabled);
  await popup.locator('#failure-mode').selectOption('von_mises');await popup.waitForFunction(()=>!document.getElementById('table-error').hidden&&!document.getElementById('failure-mode').disabled);assert.equal(await popup.locator('#failure-mode').inputValue(),'von_mises');assert.equal(await page.evaluate(()=>state.stressReport.report),null);assert.equal(await popup.locator('.rf-value[data-value]:not([data-value=""])').count(),0);assert(await popup.locator('#export-csv').isDisabled());await page.evaluate(()=>{document.getElementById('stress-report-percentile').value='95';refreshStressReport();});await popup.locator('#failure-mode').selectOption('von_mises');await page.waitForFunction(()=>state.stressReport.report.failureMode==='von_mises');await popup.waitForFunction(()=>!document.getElementById('failure-mode').disabled);assert(await page.locator('#stress-report-stress').isEnabled());checks.push('All three failure modes synchronize from the detached selector; invalid percentile recovery is preserved when returning to the stress assessment.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,prepared,rows:report.rows,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure-parent.png')});if(popup)await popup.screenshot({path:path.join(out,'failure-popup.png')});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
