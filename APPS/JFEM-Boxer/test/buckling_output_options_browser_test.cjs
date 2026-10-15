'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
if(process.argv.length<4||process.argv.length>5)throw Error('Usage: node test/buckling_output_options_browser_test.cjs <fixture-dir> <evidence-dir> [playwright-module]');
const fixture=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]),web=path.resolve(__dirname,'../web');
const playwright=process.argv[4]||process.env.WING_PLAYWRIGHT_MODULE;
const {chromium}=require(playwright?path.resolve(playwright):'playwright');
fs.mkdirSync(out,{recursive:true});const errors=[],checks=[];
(async()=>{
 const launch={headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']};if(process.env.CHROME_PATH)launch.executablePath=process.env.CHROME_PATH;
 const browser=await chromium.launch(launch),page=await browser.newPage({viewport:{width:1500,height:1050}});
 try{
  page.on('pageerror',error=>errors.push(error.stack));
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43989/**',route=>new URL(route.request().url()).pathname==='/index.html'?
   route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')}):
   route.fulfill({path:path.join(web,new URL(route.request().url()).pathname)}));
  await page.goto('http://127.0.0.1:43989/index.html');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const source=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:source.slice(0,source.indexOf('(async function start()'))});
  await page.evaluate(({schema,mesh})=>{
   initScene();state.schema=schema.schema;state.data=MessagePack.decode(Uint8Array.from(mesh));state.values=state.data.model_params;
   state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;buildForm(state.schema,state.values);buildModel(state.data);
   document.getElementById('splash').hidden=true;activity()?.end(activity()?.startup);if(activity())activity().startup=null;setBusy(false);activateWorkspaceTab('analysis');
  },{schema:JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8')),mesh:[...fs.readFileSync(path.join(fixture,'payload.msgpack'))]});
  await page.waitForFunction(()=>state.scene.getActiveMeshes().length>0);
  const density=page.locator('[id="p-output.buckling_energy_density"]'),energy=page.locator('[id="p-output.buckling_deformation_energy"]'),compact=page.locator('[id="p-output.buckling_compact"]');
  assert(await density.isHidden()&&await energy.isVisible()&&await compact.isVisible());assert.equal(await compact.isChecked(),false);
  await energy.check();await compact.check();assert(await energy.isDisabled());
  const saved=await page.evaluate(async()=>{
   const view={controls:{},layers:{},camera:{target:[0,0,0],alpha:0,beta:1,radius:10},workspace:{activeTab:'analysis',width:400,collapsed:false},activeCase:1};
   const snapshot=await WingWorkspace.snapshot(collectParams(),null,view);return WingWorkspace.parse(JSON.stringify(snapshot)).data.parameters;
  });
  for(const key of ['buckling_deformation_energy','buckling_compact'])assert.equal(saved['output.'+key],true);
  assert.equal(saved['output.buckling_energy_density'],false);
  await page.screenshot({path:path.join(out,'generated-output-options.png')});
  await compact.uncheck();assert(await energy.isEnabled());
  await page.locator('[id="p-output.solution"]').selectOption('103');assert(await compact.isHidden());
  await page.locator('[id="p-output.solution"]').selectOption('105');await energy.uncheck();
  checks.push('Generated SOL105 offers one combined ESE request; compact output disables it without losing its saved value, and controls hide for other solutions.');
  await page.evaluate(()=>{
   const host=document.createElement('section');host.id='imported-output-test';document.getElementById('group-analysis').append(host);
   window.outputDeck={name:'source.bdf',solution:'105',signature:'source',source:{}};
   window.outputEditor=WingImportedAnalysis.create({host,read:()=>outputDeck,onChange:value=>{outputDeck.source.analysis=value;}});outputEditor.refresh();
  });
  const imported=page.locator('#imported-output-test');assert(await imported.locator('[data-key="buckling_compact"]').isDisabled());
  await imported.locator('[data-key="buckling_output_override"]').check();await imported.locator('[data-key="buckling_deformation_energy"]').check();await imported.locator('[data-key="buckling_compact"]').check();
  assert(await imported.locator('[data-key="buckling_deformation_energy"]').isDisabled());
  assert.equal(await imported.locator('[data-key="buckling_energy_density"]').count(),0);
  assert(await page.evaluate(()=>WingImportedAnalysis.options({buckling_energy_density:true}).buckling_deformation_energy));
  assert(await page.evaluate(()=>WingImportedAnalysis.options(JSON.parse(JSON.stringify(outputDeck.source.analysis))).buckling_compact));
  assert.match(await imported.textContent(),/force × length/);await page.screenshot({path:path.join(out,'imported-output-options.png')});
  await imported.locator('[data-key="buckling_output_override"]').uncheck();assert.equal(await page.evaluate(()=>WingImportedAnalysis.signature(outputDeck)),'source');
  await page.evaluate(()=>document.getElementById('imported-output-test').remove());
  checks.push('Imported source output is preserved by default; explicit override is portable, supports compact/energy choices and resets to source. Units retain the source-deck caveat.');
  async function load(filename){return page.evaluate(async bytes=>{
   state.modelDirty=false;state.modelSignature=formSignature();state.jobSignature=state.modelSignature;
   const original=window.fetch;window.fetch=async()=>({ok:true,arrayBuffer:async()=>Uint8Array.from(bytes).buffer});
   let loaded;try{loaded=await loadJfemResults();}finally{window.fetch=original;}
   activateWorkspaceTab('results');document.getElementById('animate').checked=false;updateAnalysisValidity();state.scene.render();
   return {loaded,matches:state.results.matches,compact:state.results.compactBuckling,modes:state.results.modes.length,available:physicalResultsAvailable(),current:analysisValidity().current};
  },[...fs.readFileSync(path.join(fixture,filename))]);}
  const compactResult=await load('compact-results.msgpack');assert(compactResult.loaded&&compactResult.matches&&compactResult.compact&&compactResult.available&&compactResult.current,JSON.stringify(compactResult));assert.equal(compactResult.modes,0);
  assert(await page.locator('#buckling-compact-results').isVisible());assert(await page.locator('#result-controls').isHidden());
  assert.match(await page.locator('#buckling-compact-results').textContent(),/intentionally omitted/);
  assert.match(await page.locator('#buckling-compact-results').textContent(),/10, 20/);
  assert.match(await page.locator('#buckling-compact-results h3').getAttribute('title'),/normaliz/i);
  const baseline=await page.evaluate(()=>state.shellMeshes.filter(mesh=>mesh.isEnabled()&&mesh.isVisible).map(mesh=>Array.from(mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind))));assert(baseline.length>0);
  assert(await page.evaluate(()=>state.scene.getActiveMeshes().length>0));
  assert.equal(await page.locator('#tab-results').getAttribute('data-analysis-state'),'current');await page.screenshot({path:path.join(out,'compact-eigenvalue-results.png')});
  checks.push('Compact results load successfully as current FE results with eigenvalues and peak GRID/PID table, deliberate omission message and no invented zero vectors or false no-results state.');
  const fullResult=await load('energy-results.msgpack');assert(fullResult.loaded&&fullResult.matches&&!fullResult.compact);assert.equal(fullResult.modes,1);
  const stateInfo=await page.evaluate(()=>{
   const options=contourOptions();state.contourIdx=options.findIndex(row=>row.name==='Element deformation energy');document.getElementById('contour-select').value=String(state.contourIdx);applyContour();state.scene.render();
   const mode=rawContourValues(),modeValues=Array.from(mode.values);selectMode(-1);const preload=rawContourValues();
   return {options:options.map(row=>row.name),modeNote:mode.note,preloadNote:preload.note,modeValues,preloadValues:Array.from(preload.values),unit:preload.unit};
  });
  assert(stateInfo.options.includes('Element energy density'));assert.match(stateInfo.modeNote,/arbitrary amplitude/);assert.match(stateInfo.preloadNote,/physical displacement/);assert.equal(stateInfo.unit,'J');
  assert.deepEqual(stateInfo.modeValues,stateInfo.preloadValues.map(value=>2*value));
  assert(await page.locator('#buckling-compact-results').isHidden());await page.screenshot({path:path.join(out,'energy-contour-preload.png')});
  checks.push('Normal outputs retain mode vectors; requested energy/density contours follow the selected mode or physical preload with explicit normalization and SI units.');
  await load('compact-results.msgpack');
  const restored=await page.evaluate(()=>state.shellMeshes.filter(mesh=>mesh.isEnabled()&&mesh.isVisible).map(mesh=>Array.from(mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind))));assert.deepEqual(restored,baseline);
  assert(await page.evaluate(()=>state.scene.getActiveMeshes().length>0));
  const longList=await page.evaluate(()=>{
   const host=document.createElement('div'),nodes=Array.from({length:100},(_,i)=>({node_id:i+1,property_ids:[i+1]}));
   WingBucklingOutputs.render(host,{compactBuckling:true,bucklingRoots:[{mode:1,eigenvalue:1,peak_translation:{nodes}}]});
   return [...host.querySelectorAll('td')].slice(2).map(cell=>({text:cell.textContent,title:cell.title}));
  });
  assert(longList.every(cell=>cell.text.length<75&&cell.text.includes('100 total')&&cell.title.endsWith('99, 100')));
  await page.screenshot({path:path.join(out,'compact-after-energy.png')});
  checks.push('Compact results retain the visible undeformed mesh, restore baseline positions after a full vector result, and bound long tied-peak lists while preserving all IDs in tooltips.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'browser-summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(checks.join('\n'));
 }catch(error){fs.writeFileSync(path.join(out,'browser-failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'browser-failure.png')});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
