'use strict';
const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs/promises');
const {chromium}=require(process.env.WINGFEGEN_PLAYWRIGHT_MODULE||'playwright');
(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
  try{
    const page=await browser.newPage({acceptDownloads:true});
    await page.setContent(`<html><body><section id="panel-summary"><div id="stats"><p>Create FEM to calculate.</p></div></section><section id="panel-weights"><div id="weights-report"></div></section></body></html>`);
    await page.addScriptTag({path:path.join(__dirname,'../web/summary_export.js')});
    await page.evaluate(()=>{window.context={model:'My model',source:'Study.wingfem.json',caseLabel:'Case 1 · Ground',generatedAt:'2026-10-19T12:00:00Z'};window.exportsUI=WingSummaryExport.create({document,getContext:()=>context});});
    assert.equal(await page.locator('[data-summary-export] button:disabled').count(),6);
    await page.evaluate(()=>{
      document.getElementById('stats').innerHTML='<table><tr><td class="section" colspan="2">Geometry and mesh</td></tr><tr><td>Nodes</td><td>120</td></tr><tr><td class="section" colspan="2">Aerodynamic loads</td></tr><tr><td>Lift</td><td>450 N</td></tr></table>';
      document.getElementById('weights-report').innerHTML='<label>Load case<select><option>Case 1 · Ground</option></select></label><p class="pick-note">Half lifting surface. Fuel uses the selected load case.</p><table><thead><tr><th>Component</th><th>Mass (kg)</th><th>Weight (N)</th></tr></thead><tbody><tr><th>Dry structure</th><td>12.5</td><td>122.583</td></tr></tbody></table><h3>Component breakdown</h3><details><summary>Calculation basis and element counts</summary><p>Ribs: 12 elements, 0.5 m² × 0.002 m.</p></details><p hidden>Hidden prompt must not be exported.</p>';
    });
    await page.waitForFunction(()=>!document.querySelector('[data-summary-export="weights"] button').disabled);
    const exported=await page.evaluate(()=>WingSummaryExport.collect(document.getElementById('weights-report'),{title:'Mass properties',...context}));
    assert.equal(exported.blocks.filter(block=>block.type==='table').length,1);
    assert(exported.blocks.some(block=>block.text==='Calculation basis and element counts'));assert(exported.blocks.some(block=>block.text?.includes('Ribs: 12 elements')));
    assert(!JSON.stringify(exported).includes('Hidden prompt'));assert(!JSON.stringify(exported).includes('Load caseCase'));
    console.log('1: Both Summary toolbars enable only with data; closed calculation details are preserved and controls/prompts are excluded.');
    let awaiting=page.waitForEvent('download');await page.locator('[data-summary-export="summary"] [data-summary-format="csv"]').click();let file=await awaiting;
    assert.equal(file.suggestedFilename(),'My_model_General_model_summary_Case_1_Ground.csv');let content=await fs.readFile(await file.path(),'utf8');
    assert(content.includes('Geometry and mesh'));assert(content.includes('Aerodynamic loads'));assert(content.includes('Lift,450 N'));assert(!content.includes('Create FEM'));
    await page.evaluate(()=>{context.caseLabel='Case 2 · Cruise';context.stale=true;document.querySelector('#stats table tr:last-child td:last-child').textContent='900 N';});
    awaiting=page.waitForEvent('download');await page.locator('[data-summary-export="summary"] [data-summary-format="md"]').click();file=await awaiting;content=await fs.readFile(await file.path(),'utf8');
    assert(content.includes('Case 2 · Cruise'));assert(content.includes('| Lift | 900 N |'));assert(!content.includes('450 N'));assert(content.includes('last-created model'));
    console.log('2: Real downloads reflect the active case and latest displayed values, with stale-data context.');
    await page.evaluate(()=>{document.querySelector('#weights-report tbody th').textContent='<script>window.injected=true</script> | _test_';});
    awaiting=page.waitForEvent('download');await page.locator('[data-summary-export="weights"] [data-summary-format="html"]').click();file=await awaiting;content=await fs.readFile(await file.path(),'utf8');
    assert(content.includes('Mass (kg)'));assert(content.includes('Ribs: 12 elements'));assert(content.includes('&lt;script&gt;'));assert(!content.includes('<script>'));
    const preview=await browser.newPage();await preview.setContent(content);assert.equal(await preview.locator('script').count(),0);assert.equal(await preview.evaluate(()=>window.injected),undefined);
    assert.equal(await preview.locator('table th').first().textContent(),'Component');assert(await preview.locator('body').textContent().then(value=>value.includes('Case 2 · Cruise')));await preview.close();
    console.log('3: HTML opens as a complete, safe document with units, source/case context and calculation notes.');
    await page.evaluate(()=>{document.getElementById('weights-report').replaceChildren(document.createTextNode('Component mass accounting is not available for imported decks.'));});
    await page.waitForFunction(()=>[...document.querySelectorAll('[data-summary-export="weights"] button')].every(button=>button.disabled));
    assert.equal(await page.locator('[data-summary-export="summary"] button:disabled').count(),0);
    await page.evaluate(()=>exportsUI.destroy());assert.equal(await page.locator('[data-summary-export]').count(),0);
    console.log('4: Model replacement disables unavailable summary exports; teardown disconnects observers and removes controls.');
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
