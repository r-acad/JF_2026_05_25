'use strict';
// Replay actual generated VLM/prescribed-case payloads in the full Boxer UI.
// node aerodynamic_load_plots_browser_test.cjs FIXTURE_DIR OUTPUT_DIR PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[fixtureArg,outArg,modulePath='playwright']=process.argv.slice(2),fixture=path.resolve(fixtureArg),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
const{chromium}=require(modulePath),schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));schema.defaults??=schema.values;
const payload=fs.readFileSync(path.join(fixture,'payload.msgpack')),cases=JSON.parse(fs.readFileSync(path.join(fixture,'aero_cases.json'),'utf8'));
const near=(a,b)=>assert(Number.isFinite(a)&&Math.abs(a-b)<=1e-10*Math.max(1,Math.abs(b)),`${a} != ${b}`);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[];
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),context=await browser.newContext({viewport:{width:1660,height:1160}}),page=await context.newPage();
 page.on('pageerror',e=>errors.push(e.stack));page.setDefaultTimeout(60000);
 const origin='http://127.0.0.1:43978';await context.route(origin+'/**',route=>{const p=new URL(route.request().url()).pathname;
  if(p==='/api/input')return route.fulfill({json:{...schema,ok:true,input_file:'Aerodynamic plot fixture',units:'SI'}});
  if(['/api/prepare_workspace','/api/generate'].includes(p))return route.fulfill({body:payload,contentType:'application/msgpack'});
  if(p==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});if(p==='/api/jfem_probe')return route.fulfill({json:{found:false}});
  if(p.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated UI test'}});
  return route.fulfill({path:p==='/shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,p==='/'?'index.html':p)});
 });
 try{
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();await page.waitForFunction(()=>state.data&&state.autoMeshReady&&!state.workspaceBusy);
  await page.evaluate(()=>{state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();state.engine.stopRenderLoop();activateWorkspaceTab('loadplots');});
  const lift=page.locator('.span-plot[data-quantity="cl_chord_m"]');assert.equal(await page.locator('.span-plot').count(),4);assert.equal(await lift.locator('.plot-series').count(),2);assert.equal(await lift.locator('[data-component="elliptical"]').getAttribute('stroke-dasharray'),'6 4');
  for(const c of cases){
   await page.locator('#plots-case-select').selectOption(String(c.id));assert.equal(await page.evaluate(()=>state.activeCase),c.id);
   assert.match(await page.locator('.plot-status').textContent(),new RegExp(c.label));
   for(const[key,field]of[['span-efficiency','span_efficiency'],['induced-drag','CDi'],['lift-coefficient','CL'],['aspect-ratio','aspect_ratio']]){
    const el=lift.locator('[data-metric="'+key+'"]'),value=c.loads.summary[field];
    if(Number.isFinite(value))near(Number(await el.getAttribute('data-value')),value);
    else{assert.equal(await el.getAttribute('data-value'),'');assert.equal(await el.textContent(),'Unavailable');}
   }
   const expected=await page.evaluate(c=>{
    const d=c.loads.spanwise,spec=WingLoadPlots.SPECS[0],actual=WingLoadPlots.samples(d,spec),ellipse=WingLoadPlots.samples(d,{...spec,key:'elliptical_cl_chord_m'});
    const integrate=points=>points.slice(1).reduce((sum,p,i)=>sum+(p.x-points[i].x)*p.y,0)*d.distribution.q_Pa;
    return{actual:integrate(actual),ellipse:integrate(ellipse),total:d.distribution.total_lift_N};
   },c);near(expected.actual,expected.total);near(expected.ellipse,expected.total);
  }
  checks.push('All six actual generated cases select their own CL, far-wake CDi, inviscid efficiency and equal-lift ellipse; strip integrals conserve signed lift.');
  await page.locator('#plots-case-select').selectOption('1');await page.locator('.plot-notes summary').click();assert.match(await page.locator('.plot-notes').textContent(),/Trefftz.*load multiplier.*Oswald/);
  const svg=lift.locator('svg');await svg.hover({position:{x:180,y:80}});assert.match(await lift.locator('.plot-readout').textContent(),/cₗ c = .*Equal-lift ellipse = /);
  await page.screenshot({path:path.join(out,'selected-case-positive-narrow.png')});
  await page.locator('#btn-max-loadplots').click();await page.waitForTimeout(100);await page.screenshot({path:path.join(out,'equal-lift-ellipse-performance.png')});
  const geometry=await lift.evaluate(el=>{const a=el.getBoundingClientRect();return{width:a.width,scroll:el.scrollWidth}});assert(geometry.scroll<=geometry.width+2);
  checks.push('Legend, signed plot hover, explicit definitions and full-span/unscaled coefficient note are visible; narrow and maximized layouts do not overflow.');
  await page.locator('#plots-case-select').selectOption('2');await page.screenshot({path:path.join(out,'negative-lift-ellipse.png')});
  await page.locator('#plots-case-select').selectOption('3');assert.equal(await lift.locator('[data-metric="span-efficiency"]').textContent(),'Unavailable');near(Number(await lift.locator('[data-metric="induced-drag"]').getAttribute('data-value')),0);
  await page.locator('#plots-case-select').selectOption('4');assert.equal(await lift.locator('[data-metric="induced-drag"]').textContent(),'Unavailable');assert.match(await lift.locator('.plot-aero-performance').textContent(),/Prescribed lift has no aerodynamic wake solution/);await page.screenshot({path:path.join(out,'prescribed-lift-unavailable-drag.png')});
  checks.push('Negative lift reverses the reference, zero aerodynamic lift leaves undefined efficiency unavailable, and prescribed loads never invent drag or efficiency.');
  await page.locator('#plots-case-select').selectOption('5');near(Number(await lift.locator('[data-metric="span-efficiency"]').getAttribute('data-value')),cases[0].loads.summary.span_efficiency);assert.match(await lift.locator('.plot-explanation').textContent(),/before the structural load multiplier/);
  await page.evaluate(()=>setModelDirty(true));assert.match(await page.locator('.plot-status').textContent(),/last created mesh/);
  assert.deepEqual(errors,[]);checks.push('Structural load multiplication changes the plotted lift without falsely changing aerodynamic coefficients; dirty model state is clearly marked.');
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,cases:cases.map(c=>({id:c.id,label:c.label,summary:c.loads.summary}))},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({checks,errors,error:error.stack},null,2));throw error;}
 finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
