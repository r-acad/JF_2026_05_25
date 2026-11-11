'use strict';
// Production server and native parser. No solver job or user browser is used.
// node fe_edit_app_browser_test.cjs URL OUTPUT PLAYWRIGHT_MODULE
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [url,out,modulePath]=process.argv.slice(2),{chromium}=require(modulePath);fs.mkdirSync(out,{recursive:true});
function fuselage(){
 const lines=['SOL 101','CEND','SUBCASE 1',' SPC=1',' LOAD=2','BEGIN BULK','MAT1,1,7.0E10,,.3,2700.','PSHELL,1,1,.002'];
 const ring=[[1,1],[-1,1],[-1,-1],[1,-1]];
 for(let x=0;x<=3;x++)for(let i=0;i<4;i++)lines.push('GRID,'+(1+x*4+i)+',,'+x+','+ring[i].join(','));
 for(let x=0;x<3;x++)for(let i=0;i<4;i++)lines.push(['CQUAD4',1+x*4+i,1,1+x*4+i,1+x*4+(i+1)%4,5+x*4+(i+1)%4,5+x*4+i].join(','));
 lines.push('CONM2,90,5,0,12.','SPC1,1,123456,1,2,3,4','FORCE,2,13,0,100.,0.,0.,1.','ENDDATA');return lines.join('\n')+'\n';
}
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,channel:process.env.CHROME_PATH?undefined:'chrome',args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1600,height:1100}}),errors=[],checks=[];page.setDefaultTimeout(180000);page.on('pageerror',e=>errors.push(e.stack));
 const panel=page.locator('#panel-feedit'),input=name=>panel.locator('[data-field='+name+']'),action=name=>panel.locator('[data-action='+name+']');
 async function wait(){await page.waitForFunction(()=>!state.workspaceBusy&&!state.feEdit?.busy);}
 async function operation(name){if(name==='copy')await panel.locator('[data-role=repeat-tools]').evaluate(el=>el.open=true);if(name==='candidates')await panel.locator('[data-role=global-search]').evaluate(el=>el.open=true);if(['translate','copy'].includes(name)&&await action(name).isDisabled())await action('clear-part').click();await action(name).click();await wait();const text=await panel.locator('[data-role=message-text]').innerText();assert(!await panel.locator('[data-role=message]').evaluate(e=>e.dataset.error==='true'),text);return text;}
 try{
  await page.goto(url);await page.getByRole('button',{name:'Start new study',exact:true}).waitFor();
  await page.evaluate(()=>{document.getElementById('auto-mesh').checked=false;document.getElementById('auto-save').checked=false;});
  await page.getByRole('button',{name:'Start new study',exact:true}).click();await page.waitForFunction(()=>state.autoMeshReady&&!state.workspaceBusy);
  assert(await page.evaluate(async text=>await loadReferenceSource({kind:'reference',name:'synthetic_fuselage.bdf',text,includes:[]}),fuselage()));
  await page.locator('#tab-feedit').click();
  const camera=await page.evaluate(()=>({alpha:state.camera.alpha,beta:state.camera.beta,radius:state.camera.radius,target:state.camera.target.asArray()}));
  await operation('initialize');assert(await page.evaluate(()=>!!state.importedDeck?.source?.text&&state.studyDirty));
  await input('point_x').fill('1.5');await input('point_y').fill('0');await input('point_z').fill('0');await input('side_length').fill('5');
  await operation('preview');assert(await page.evaluate(()=>!!state.scene.getMeshByName('fe-cut-plane-fill-0')));
  await page.screenshot({path:path.join(out,'01-cut-plane.png')});
  await operation('cut');const cut=await page.evaluate(()=>({nodes:state.nodeIds.length,elements:state.elements.size}));assert(cut.nodes>16&&cut.elements>12);
  await input('move_x').fill('1');await input('move_y').fill('0');await input('move_z').fill('0');await operation('translate');
  assert.equal(await page.evaluate(()=>state.bbox.max[0]),4);checks.push('Read native source, duplicate a mid-element cut, move only the positive half and retain source identity.');
  await page.screenshot({path:path.join(out,'02-translated-part.png')});
  await input('point_x').fill('.5');await input('selection').selectOption('slab');await input('depth').fill('1');await operation('cut');
  await input('copy_count').fill('1');await operation('copy');
  await input('node_tolerance').fill('1e-6');await operation('candidates');
  assert(await panel.locator('[data-role=candidate-rows] tr').count()>0);await input('select_all').check();await operation('equivalence');
  const merged=await page.evaluate(()=>({nodes:state.nodeIds.length,text:state.importedDeck.source.text}));
  assert.match(merged.text,/CONM2/);assert.equal((merged.text.match(/^CONM2,/gm)||[]).length,2);checks.push('Cut a reusable slice, copy it into the stretch gap, merge reviewed overlapping nodes and retain/copy structural lumped masses.');
  await operation('undo');assert(await page.evaluate(()=>state.nodeIds.length)>merged.nodes);await operation('candidates');await input('select_all').check();await operation('equivalence');
  const after=await page.evaluate(()=>({alpha:state.camera.alpha,beta:state.camera.beta,radius:state.camera.radius,target:state.camera.target.asArray()}));
  for(const key of ['alpha','beta','radius'])assert(Math.abs(after[key]-camera[key])<1e-8);after.target.forEach((v,i)=>assert(Math.abs(v-camera.target[i])<1e-8));
  assert(await page.evaluate(()=>!state.results&&!state.resultCases));
  await page.screenshot({path:path.join(out,'03-joined-extension.png')});
  await page.route('**/api/study/pick',route=>route.fulfill({json:{ok:true,available:false,reason:'Browser export fixture'}}));
  await page.evaluate(()=>{window.__exportedDeck=null;window.showSaveFilePicker=async options=>{
    window.__deckPickerOptions=options;
    return{name:'chosen_extension.bdf',createWritable:async()=>({write:async text=>{window.__exportedDeck=text;},close:async()=>{window.__deckWriterClosed=true;}})};
  };});
  await operation('export');
  assert.equal(await page.evaluate(()=>window.__exportedDeck),merged.text);
  assert(await page.evaluate(()=>window.__deckWriterClosed));
  assert.deepEqual(await page.evaluate(()=>window.__deckPickerOptions.types[0].accept),{'text/plain':['.bdf','.dat','.nas']});
  checks.push('Save edited Nastran model uses the chosen destination, correct deck filter and complete current source.');
  const study=await page.evaluate(async()=>await WingWorkspace.snapshot(state.values,state.reference,WingWorkspace.captureView(document,state,workspaceUI),{modelSource:state.importedDeck.source,notes:state.studyNotes,identification:state.studyWatermark?.capture()}));
  fs.writeFileSync(path.join(out,'extended_fuselage.wingfem.json'),JSON.stringify(study,null,2));fs.writeFileSync(path.join(out,'extended_fuselage.bdf'),merged.text);
  const beforeReopen=await page.evaluate(()=>Array.from(state.nodeIds));
  assert(await page.evaluate(async data=>await loadModelDefinition({name:'extended_fuselage.wingfem.json',text:async()=>JSON.stringify(data)},{recent:true}),study));
  assert.deepEqual(await page.evaluate(()=>Array.from(state.nodeIds)),beforeReopen);checks.push('Undo works, camera is retained, stale results are cleared, and the portable edited Study reopens through the native parser.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,cut,mergedNodes:merged.nodes},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,errors,checks},null,2));throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
