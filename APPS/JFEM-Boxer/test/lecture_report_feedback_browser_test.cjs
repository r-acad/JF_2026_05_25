'use strict';
// node lecture_report_feedback_browser_test.cjs PRIVATE_OUTPUT PLAYWRIGHT_MODULE
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const out=path.resolve(process.argv[2]),{chromium}=require(process.argv[3]),web=path.resolve(__dirname,'../web');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({channel:'chrome',headless:true}),page=await browser.newPage({viewport:{width:1100,height:1300}}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.setContent('<body style="font:14px system-ui;background:#162432;color:white"><h1>Mass properties</h1><div id="weights"></div><h1>Aerodynamic loads</h1><div id="plots" style="width:900px"></div>');
  for(const file of ['numbers.js','weights.js','load_plots.js','summary_export.js'])await page.addScriptTag({path:path.join(web,file)});
  for(const file of ['weights.css','load_plots.css'])if(fs.existsSync(path.join(web,file)))await page.addStyleTag({path:path.join(web,file)});
  await page.evaluate(()=>{
   window.weights=WingWeights.create(document.getElementById('weights'));
   weights.update({scope:'Modeled half lifting surface',gravity_m_s2:9.80665,method:'FE shell and bar mass',note:'',
    totals:{structure_mass_kg:100,structure_weight_N:980.665,fuel_mass_kg:0,fuel_weight_N:0,loaded_mass_kg:100,loaded_weight_N:980.665},
    components:[{id:'movable_surfaces',label:'Movable-surface structures',mass_kg:12,weight_N:117.6798,count:24,kind:'shell',area_m2:2,thickness_m:.002,
      note:'Flap and aileron skins, webs, ribs and fittings. Already included in dry structural and loaded mass totals; do not add this mass again.'}]});
   window.plots=WingLoadPlots.create(document.getElementById('plots'),()=>{});
   window.showCase=e=>plots.update([{id:1,label:'Test aerodynamic case',loads:{summary:{method:'vortex_lattice',CL:.7,CDi:.01,aspect_ratio:8,span_efficiency:e},spanwise:{semispan_m:4,distribution:{y_m:[1,3],cl_chord_m:[.8,.3],elliptical_cl_chord_m:[.75,.35]}}}}],1,false);
   showCase(1.03);
  });
  assert.equal(await page.locator('#weights-movable-summary').isVisible(),true);
  assert.match(await page.locator('#weights-movable-summary').textContent(),/12 kg.*Already included/);
  const exported=await page.evaluate(()=>WingSummaryExport.serialize(WingSummaryExport.collect(document.getElementById('weights'),{title:'Mass properties'}),'html'));
  assert.match(exported,/Movable-surface structures: 12 kg.*Already included/);
  const metric=page.locator('.plot-aero-performance');assert.match(await metric.textContent(),/Inviscid span efficiency e/);
  assert.match(await metric.textContent(),/e > 1.*nonplanar geometry or numerical discretization/);
  assert.doesNotMatch(await metric.textContent(),/Oswald \/ span efficiency/);
  await page.evaluate(()=>showCase(.95));assert.doesNotMatch(await metric.textContent(),/e > 1/);
  assert.equal(await page.locator('[data-metric="span-efficiency"]').getAttribute('data-value'),'0.95');
  assert.deepEqual(errors,[]);await page.screenshot({path:path.join(out,'mass-and-span-efficiency.png'),fullPage:true});
  console.log('PASS visible movable-mass inclusion, exported mass note, correct inviscid span-efficiency label and unclipped >1 diagnostic');
 }finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
