'use strict';
const assert=require('node:assert/strict'),path=require('node:path');
const {chromium}=require(process.env.WINGFEGEN_PLAYWRIGHT_MODULE||'playwright');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
 try{
  const page=await browser.newPage();await page.setContent('<html><body><div id="analysis"></div></body></html>');
  await page.addStyleTag({path:path.join(__dirname,'../web/reference_import.css')});
  for(const file of ['reference_import.js','imported_analysis.js'])await page.addScriptTag({path:path.join(__dirname,'../web',file)});
  await page.evaluate(()=>{
   window.requests=[];window.picks=[];
   window.importer=WingReferenceImport.create({pickFile:async request=>{picks.push(request);return{ok:true,path:'C:/meshes/volume.inp.gz'};},onImport:async request=>{requests.push(request);return true;}});
   importer.open({format:'abaqus'});
  });
  await page.waitForFunction(()=>document.querySelector('#reference-local-path').value.endsWith('.inp.gz'));
  assert.equal(await page.locator('h2').first().textContent(),'Read Abaqus input');assert.deepEqual(await page.evaluate(()=>picks),[{path:'',format:'abaqus'}]);
  assert(await page.locator('#abaqus-completion').isVisible());assert(!(await page.locator('#abaqus-completion-enabled').isChecked()));
  assert(await page.locator('[data-completion="E"]').isDisabled());
  await page.locator('#reference-read').click();await page.waitForFunction(()=>requests.length===1);
  assert.deepEqual(await page.evaluate(()=>requests[0]),{path:'C:/meshes/volume.inp.gz',format:'abaqus'});
  console.log('1: Native .inp.gz picker and uncompleted mesh import do not invent physics.');
  await page.evaluate(()=>{importer.open({format:'abaqus'});});await page.locator('#abaqus-completion-enabled').check();
  await page.locator('[data-completion="E"]').fill('0');await page.locator('#reference-read').click();
  assert(await page.locator('#reference-import-error').isVisible());assert.equal(await page.evaluate(()=>requests.length),1);
  await page.locator('[data-completion="E"]').fill('210000000000');await page.locator('[data-completion="rho"]').fill('7850');
  await page.locator('[data-completion="constraint_set"]').fill('BASE');await page.locator('[data-completion="solution"]').selectOption('103');
  await page.locator('[data-completion="modes"]').fill('6');await page.locator('#reference-read').click();await page.waitForFunction(()=>requests.length===2);
  const completion=await page.evaluate(()=>requests[1].completion);assert.equal(completion.solution,'103');assert.equal(completion.E,210e9);assert.equal(completion.rho,7850);assert.equal(completion.constraint_set,'BASE');assert.equal(completion.modes,6);assert.equal(completion.enabled,true);
  console.log('2: Invalid completion is atomic; explicit modal material and constraints reach import request.');
  await page.evaluate(()=>{
   window.deck={name:'mesh.inp',source_format:'abaqus',analysis_ready:false,solution:'',source:WingReferenceImport.source({kind:'reference',name:'mesh.inp',format:'abaqus',text:'*NODE\n1,0,0,0\n2,1,0,0\n3,0,1,0\n4,0,0,1\n*ELEMENT, TYPE=C3D4, ELSET=VOLUME\n41,1,2,3,4\n*NSET, NSET=BASE\n1,2,3\n*NSET, NSET=TIP\n4\n*SURFACE, NAME=TOP, TYPE=ELEMENT\nVOLUME,S1\n'}),abaqus:{nsets:{BASE:[1,2,3],TIP:[4]},elsets:{VOLUME:[41]},surfaces:{TOP:{entries:[{set_or_id:'VOLUME',face:'S1'}]}},diagnostics:[{code:'missing',message:'No solid section assigned.'}]}};
   window.analysis=WingImportedAnalysis.create({host:document.getElementById('analysis'),read:()=>deck,onChange:()=>{throw Error('Abaqus Reference-only overlay must be disabled');}});analysis.refresh();
  });
  assert.equal(await page.locator('#analysis [data-key]:not(:disabled)').count(),0);
  assert.match(await page.locator('[data-abaqus-info]').textContent(),/Node sets.*BASE.*TIP.*Element sets.*VOLUME.*No solid section/s);
  assert.match(await page.locator('[data-note]').textContent(),/unavailable/);
  await page.evaluate(()=>{deck.analysis_ready=true;deck.solution='103';deck.solution_label='SOL 103';analysis.refresh();});
  assert.match(await page.locator('[data-note]').textContent(),/Run SOL 103/);assert(!(await page.locator('[data-eigen-note]').isVisible()));assert(!(await page.locator('[data-key="follower"]').isVisible()));
  console.log('3: Named sets, source diagnostics and analysis readiness are visible; BDF-only controls are disabled.');
  await page.evaluate(()=>importer.destroy());assert.equal(await page.locator('.reference-import-dialog').count(),0);
  assert.deepEqual(await page.evaluate(()=>({picks:picks.length,imports:requests.length})),{picks:2,imports:2});
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
