'use strict';
// Exercises the real app mode synchronization with the real panel DOM.
// No solver/server is required. WING_PLAYWRIGHT_MODULE and CHROME_PATH are optional.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require(process.env.WING_PLAYWRIGHT_MODULE||'playwright');
const web=path.resolve(__dirname,'../web');
const source=fs.readFileSync(path.join(web,'app.js'),'utf8');
const start=source.indexOf('function syncImportedModelMode('),end=source.indexOf('\nasync function loadDiskResults(',start);
assert(start>=0&&end>start,'The app imported-mode synchronization is available');
const navigationStart=source.indexOf('function syncModelNavigation('),navigationConstants=source.slice(source.indexOf('const PROPERTY_TABS'),source.indexOf('const WORKSPACE_MAIN_TABS'));
assert(navigationStart>=0&&navigationStart<start,'The app model-navigation synchronization is available');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
 try{
  const page=await browser.newPage({viewport:{width:800,height:1000}}),errors=[];page.on('pageerror',error=>errors.push(error.message));
  await page.setContent(`<main style="width:380px;padding:16px"><div id="form">Generated model settings</div>
   <section id="panel-analysis-actions"><p class="pick-note">Generated analysis</p><div id="imported-analysis"></div></section>
   <details id="imported-deck-info"><summary id="imported-deck-title"></summary><ul id="imported-deck-warnings"></ul></details>
   <input id="auto-mesh" type="checkbox">${['btn-jfem','btn-study-notes','btn-open-plan-view','tab-planform','tab-geometrymenu'].map(id=>`<button id="${id}"></button>`).join('')}</main>`);
  await page.addStyleTag({path:path.join(web,'style.css')});
  await page.addScriptTag({path:path.join(web,'imported_analysis.js')});
  await page.addScriptTag({content:`
   window.state={importedDeck:null,diskResults:null,autoMeshReady:true};
   window.workspaceUI={activeTab:'analysis'};
   window.syncLeadingEdgePropertiesTab=()=>{};
   window.formSignature=()=>JSON.stringify(state.importedDeck?.source.analysis);
   window.markStudyModified=()=>{};window.updateAnalysisValidity=()=>{};window.log=()=>{};
   ${navigationConstants}
   ${source.slice(navigationStart,start)}
   ${source.slice(start,end)}
   window.setSource=(deck,diskResults=null)=>{state.importedDeck=deck;state.diskResults=diskResults;syncImportedModelMode();};
  `});
  const panel=page.locator('#imported-analysis'),solution=panel.locator('[data-key=solution]');
  const bdf={name:'input.bdf',solution:'101',signature:'source',source:{kind:'reference',name:'input.bdf',text:'SOL 101\nCEND\nBEGIN BULK\nENDDATA\n'}};
  await page.evaluate(()=>setSource(null));assert(await panel.isHidden(),'Generated model starts without imported analysis');assert(!(await page.locator('#tab-planform').isDisabled()));
  await page.evaluate(deck=>setSource(deck),bdf);assert(await panel.isVisible());assert.equal(await panel.locator('h2').textContent(),'Analysis of imported model');assert(await page.locator('#tab-planform').isDisabled());assert(await page.locator('#tab-geometrymenu').isDisabled());
  assert.equal(await panel.locator('details[open]').count(),0,'Long help starts collapsed');
  await solution.selectOption('105');assert(await panel.locator('[data-eigen]').isVisible());assert(await panel.locator('[data-buckling-outputs]').isVisible());assert(await panel.locator('[data-nonlinear]').isHidden());
  assert.equal(await page.evaluate(()=>state.importedDeck.source.analysis.solution),'105');
  await panel.locator('[data-key=buckling_output_override]').check();await panel.locator('[data-key=buckling_compact]').check();assert(await panel.locator('[data-key=buckling_deformation_energy]').isDisabled());
  await solution.selectOption('106');assert(await panel.locator('[data-nonlinear]').isVisible());assert(await panel.locator('[data-eigen]').isHidden());assert(await panel.locator('[data-buckling-outputs]').isHidden());
  await page.evaluate(()=>setSource(null));assert(await panel.isHidden(),'Returning to a generated study clears imported analysis');assert(!(await page.locator('#tab-planform').isDisabled()));assert(!(await page.locator('#tab-geometrymenu').isDisabled()));
  await page.evaluate(()=>setSource({name:'archive.jfem',source:{kind:'results',name:'archive.jfem',analysis:{solution:'source'}}},{name:'archive.jfem'}));assert(await panel.isHidden(),'Result archive has no editable source analysis');
  await page.evaluate(deck=>setSource(deck,{name:'archive.jfem'}),bdf);assert(await panel.isHidden(),'An archive flag also protects against a stale source deck');
  await page.evaluate(()=>setSource({name:'missing.bdf',source_format:'reference',solution:'101'}));assert(await panel.isHidden(),'Mesh metadata alone cannot expose an analysis editor');
  await page.evaluate(deck=>setSource({...deck,name:'mesh.inp',source_format:'abaqus',analysis_ready:false,source:{...deck.source,name:'mesh.inp',format:'abaqus'},abaqus:{nsets:{FIXED:[1,2]},elsets:{BODY:[1]}}}),bdf);
  assert(await panel.isVisible());assert(await panel.locator('[data-abaqus-info]').isVisible());assert(await panel.locator('[data-source-controls]').isHidden());assert(await page.locator('#btn-jfem').isDisabled());assert.match(await panel.textContent(),/mesh-only or incomplete/);
  await page.evaluate(deck=>setSource(deck),bdf);assert(await panel.isVisible());assert(await panel.locator('[data-source-controls]').isVisible());assert.equal(await solution.inputValue(),'source','Source-specific choices do not leak into a different import');
  await page.evaluate(()=>{syncImportedModelMode(true);});assert(await solution.isDisabled());await page.evaluate(()=>syncImportedModelMode(false));assert(!(await solution.isDisabled()));
  await page.evaluate(()=>setSource(null));assert(await panel.isHidden());assert.deepEqual(errors,[]);
  console.log('Imported-analysis visibility: generated, BDF, source replacement, saved result archive, incomplete metadata, Abaqus, busy state, and conditional solution/output controls passed.');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
