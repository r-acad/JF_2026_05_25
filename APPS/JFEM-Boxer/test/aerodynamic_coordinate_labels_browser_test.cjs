'use strict';
// node aerodynamic_coordinate_labels_browser_test.cjs OUTPUT PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),out=path.resolve(process.argv[2]),{chromium}=require(process.argv[3]||'playwright');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({channel:'chrome',headless:true}),page=await browser.newPage({viewport:{width:900,height:900}});
 try{
  await page.setContent('<style>section{position:relative;width:700px}svg{width:700px} .aero-plot-tooltip{position:absolute;white-space:pre-wrap;background:white}</style><section id="chart"></section>');
  for(const file of ['numbers.js','aerodynamic_plots.js'])await page.addScriptTag({path:path.resolve(__dirname,'../web',file)});
  await page.evaluate(()=>{
   window.plot={title:'Pressure profile',xlabel:'x/c',ylabel:'ΔCp',series:[{name:'Strip',points:[[.337123456789,1.23456789123]]}]};
   window.before=JSON.stringify(plot);const chart=document.getElementById('chart');chart.innerHTML=WingAerodynamicPlots.svg(plot);WingAerodynamicPlots.installHover(chart.querySelector('svg'),plot);
  });
  await page.locator('circle[data-point-index="0"]').focus();assert.match(await page.locator('.aero-plot-tooltip').innerText(),/x\/c: 0\.3371/);assert.match(await page.locator('.aero-plot-tooltip').innerText(),/ΔCp: 1\.2345679/);assert.equal(await page.locator('circle[data-point-index="0"] title').textContent(),'Strip: (0.3371, 1.2346)');
  assert.equal(await page.evaluate(()=>JSON.stringify(plot)),await page.evaluate(()=>before));assert.equal(await page.evaluate(()=>WingAerodynamicPlots.dataRows([plot])[0].x),.337123456789);
  await page.evaluate(()=>{plot={title:'Spanwise locations',xlabel:'CL',ylabel:'η',series:[{name:'Stations',points:[[.337123456789,.123456789]]}]};const chart=document.getElementById('chart');chart.replaceChildren();chart.innerHTML=WingAerodynamicPlots.svg(plot);WingAerodynamicPlots.installHover(chart.querySelector('svg'),plot);});
  await page.locator('circle[data-point-index="0"]').focus();assert.match(await page.locator('.aero-plot-tooltip').innerText(),/CL: 0\.33712346/);assert.match(await page.locator('.aero-plot-tooltip').innerText(),/η: 0\.1235/);
  const summary={passed:true,checks:['Coordinate x/c and eta tooltip axes use four significant figures in readable decimal form.','Physical coefficient tooltip values retain eight significant figures; SVG/data exports retain their physical values.']};fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(summary,null,2));console.log(JSON.stringify(summary));
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
