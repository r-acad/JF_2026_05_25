'use strict';
// Production native reader, 3D pointer picking, retained RBE and part movement.
// node fe_edit_picking_app_browser_test.cjs URL OUTPUT PLAYWRIGHT_MODULE CHROME
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[url,out,modulePath,chrome]=process.argv.slice(2),{chromium}=require(modulePath);fs.mkdirSync(out,{recursive:true});
function source(){
 const rows=['SOL 101','CEND','SUBCASE 1',' SPC=1',' LOAD=2','BEGIN BULK','MAT1,1,7.0E10,,.3,2700.','PSHELL,1,1,.002'];
 const ring=[[1,1],[-1,1],[-1,-1],[1,-1]];
 for(let x=0;x<=3;x++)for(let i=0;i<4;i++)rows.push(['GRID',1+x*4+i,'',x,ring[i][0]+(x===1?.00004:0),ring[i][1]].join(','));
 for(let x=0;x<3;x++)for(let i=0;i<4;i++)rows.push(['CQUAD4',1+x*4+i,1,1+x*4+i,1+x*4+(i+1)%4,5+x*4+(i+1)%4,5+x*4+i].join(','));
 rows.push('RBE2,103300,1,123,13','SPC1,1,123456,1,2,3,4','FORCE,2,13,0,100.,0.,0.,1.','ENDDATA');return rows.join('\n')+'\n';
}
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:chrome||undefined,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1650,height:1100}}),errors=[],checks=[],rfRequests=[],rfWorkers=[];page.setDefaultTimeout(180000);page.on('pageerror',e=>errors.push(e.stack));
 page.on('request',request=>{if(/\/api\/rf_sections|\/rf_compute_worker\.js/.test(request.url()))rfRequests.push(request.url());});
 page.on('worker',worker=>{if(/rf_compute_worker/.test(worker.url()))rfWorkers.push(worker.url());});
 const panel=page.locator('#panel-feedit'),input=name=>panel.locator('[data-field='+name+']'),button=name=>panel.locator('[data-action='+name+']');
 async function idle(){await page.waitForFunction(()=>!state.workspaceBusy&&!state.feEdit?.busy);}
 async function operation(name){console.log('FE pick workflow: '+name);if(name==='candidates')await panel.locator('[data-role=global-search]').evaluate(el=>el.open=true);await button(name).click();await idle();const error=await panel.locator('[data-role=message]').evaluate(e=>e.dataset.error==='true');assert(!error,await panel.locator('[data-role=message-text]').innerText());}
 async function clickModel(target){
  const p=await page.evaluate(target=>{
   state.camera.getViewMatrix(true);state.scene.updateTransformMatrix(true);
   const index=target.grid?state.nodeIds.indexOf(target.grid):null,e=target.element?state.elements.get(target.element):null;
   const v=index!==null?vec(state.baseline,index):e.nodes.reduce((p,i)=>p.add(vec(state.baseline,i)),BABYLON.Vector3.Zero()).scale(1/e.nodes.length);
   const viewport=state.camera.viewport.toGlobal(state.engine.getRenderWidth(),state.engine.getRenderHeight()),s=state.engine.getHardwareScalingLevel();
   const p=BABYLON.Vector3.Project(v,BABYLON.Matrix.IdentityReadOnly,state.scene.getTransformMatrix(),viewport),rect=document.getElementById('render').getBoundingClientRect();return{x:rect.left+p.x*s,y:rect.top+p.y*s};
  },target);await page.mouse.click(p.x,p.y);
 }
 try{
  await page.goto(url);await page.getByRole('button',{name:'Start new study',exact:true}).waitFor();
  await page.evaluate(()=>{document.getElementById('auto-mesh').checked=false;document.getElementById('auto-save').checked=false;});await page.getByRole('button',{name:'Start new study',exact:true}).click();await page.waitForFunction(()=>state.autoMeshReady&&!state.workspaceBusy);
  assert(await page.evaluate(async text=>await loadReferenceSource({kind:'reference',name:'retained_103300.bdf',text,includes:[]}),source()));
  console.log('FE pick workflow: source loaded');
  await page.locator('#tab-feedit').click();await operation('initialize');
  await page.getByRole('button',{name:'Top view',exact:true}).click();
  await page.evaluate(()=>{
   window.fePickEffects={showElement:0,showNode:0,inspectReserveFactor:0,refreshStressReport:0,requestSizingSections:0,rfCreate:0,rfEvaluate:0};
   for(const name of ['showElement','showNode','inspectReserveFactor','refreshStressReport','requestSizingSections']){
    const original=window[name];window[name]=function(...args){fePickEffects[name]++;return original.apply(this,args);};
   }
   const create=WingRFCompute.create;WingRFCompute.create=function(...args){fePickEffects.rfCreate++;const evaluator=create.apply(this,args),evaluate=evaluator.evaluate;evaluator.evaluate=function(...values){fePickEffects.rfEvaluate++;return evaluate.apply(this,values);};return evaluator;};
   window.resetFEPickEffects=()=>{for(const name of Object.keys(fePickEffects))fePickEffects[name]=0;};
  });
  const camera=await page.evaluate(()=>({a:state.camera.alpha,b:state.camera.beta,r:state.camera.radius,t:state.camera.target.asArray()}));
  await button('pick-plane-point').click();await clickModel({grid:5});await page.waitForFunction(()=>!state.feEditPicking);
  assert.equal(Number(await input('point_x').inputValue()),1);assert.equal(Number(await input('point_y').inputValue()),1.00004);assert.equal(Number(await input('point_z').inputValue()),1);
  await input('side_length').fill('6');await input('side_length').dispatchEvent('change');
  await page.waitForFunction(()=>!!state.scene.getMeshByName('fe-cut-intersection'));
  assert(await page.evaluate(()=>state.scene.getMeshByName('fe-cut-plane-fill-0').material.alpha<1));
  await button('pick-translation-vector').click();await clickModel({grid:1});await page.waitForFunction(()=>state.feEditPicking?.nodes.length===1);await clickModel({grid:5});await page.waitForFunction(()=>!state.feEditPicking);
  assert.equal(Number(await input('move_x').inputValue()),1);assert(Math.abs(Number(await input('move_y').inputValue())-.00004)<1e-12);assert.equal(Number(await input('move_z').inputValue()),0);
  await input('move_y').fill('0');await input('move_y').dispatchEvent('change');assert.equal(Number(await input('move_x').inputValue()),1);
  checks.push('Real 3D GRID picks use exact working-deck coordinates; B−A retains a small native delta, and an individual delta can be zeroed.');
  const beforeCancel=await input('move_x').inputValue();await button('pick-translation-vector').click();await clickModel({grid:1});await page.waitForFunction(()=>state.feEditPicking?.nodes.length===1);await page.keyboard.press('Escape');assert.equal(await input('move_x').inputValue(),beforeCancel);
  const nodePickEffects=await page.evaluate(()=>({...fePickEffects}));assert(Object.values(nodePickEffects).every(count=>count===0),JSON.stringify(nodePickEffects));
  checks.push('FE Utils GRID picks return geometry only: no normal inspection selection, stress-report refresh, RF assessment, section recovery or RF worker is invoked.');
  await page.evaluate(()=>{activateWorkspaceTab('inspect');document.getElementById('inspect-entity').value='nodes';showNode(state.nodeIds.indexOf(5));});
  assert(await page.evaluate(()=>state.selectionMesh.material.alpha>0&&state.selectionMesh.material.alpha<1));
  await page.evaluate(()=>{document.getElementById('inspect-entity').value='all';resetFEPickEffects();});await clickModel({element:9});await page.waitForFunction(()=>state.selectedElement!=null);
  const normalInspectEffects=await page.evaluate(()=>({...fePickEffects}));assert(normalInspectEffects.showElement>0&&normalInspectEffects.inspectReserveFactor>0,JSON.stringify(normalInspectEffects));
  checks.push('The ordinary Inspect element click still selects the element and invokes its reserve-factor inspection.');
  await page.locator('#tab-feedit').click();await operation('cut');
  assert.match(await panel.locator('[data-role=message-text]').innerText(),/103300/);
  await operation('parts');assert.equal(await panel.locator('[data-role=parts-summary] li').count(),2);
  await page.waitForFunction(()=>state.scene.meshes.some(m=>m.name.startsWith('fe-part-fill-')));
  await page.screenshot({path:path.join(out,'01-cut-lines-and-parts.png')});
  await page.evaluate(()=>{resetFEPickEffects();window.fePickPriorReport=state.stressReport;});const requestsBeforePart=rfRequests.length,workersBeforePart=rfWorkers.length;
  await button('pick-part').click();await clickModel({element:9});await page.waitForFunction(()=>!state.feEditPicking);
  assert.match(await panel.locator('[data-role=part-selection-text]').innerText(),/8/);
  const partPickEffects=await page.evaluate(()=>({...fePickEffects}));assert(Object.values(partPickEffects).every(count=>count===0),JSON.stringify(partPickEffects));assert(await page.evaluate(()=>state.stressReport===fePickPriorReport&&state.selectedElement===null&&state.selectedNode===null));assert.equal(rfRequests.length,requestsBeforePart);assert.equal(rfWorkers.length,workersBeforePart);
  checks.push('A real 3D part click identifies the component without calling showElement, RF assessment or section recovery, creating a worker, sending RF requests or changing the Inspect selection.');
  const old13=await page.evaluate(async()=>{const r=await fetch('/api/fe_edit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'node_coordinates',...state.feEditIdentity,node_ids:[13]})});return(await r.json()).nodes[0].xyz;});
  await operation('translate');
  const after=await page.evaluate(async()=>{const r=await fetch('/api/fe_edit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'node_coordinates',...state.feEditIdentity,node_ids:[13]})});return{xyz:(await r.json()).nodes[0].xyz,text:state.importedDeck.source.text,max:state.bbox.max[0],a:state.camera.alpha,b:state.camera.beta,r:state.camera.radius,t:state.camera.target.asArray()};});
  assert.equal(after.max,4);assert.deepEqual(after.xyz,old13);assert.match(after.text,/^RBE2,103300,1,123,13$/m);
  assert(Math.abs(after.a-camera.a)<1e-8&&Math.abs(after.b-camera.b)<1e-8&&Math.abs(after.r-camera.r)<1e-8);after.t.forEach((v,i)=>assert(Math.abs(v-camera.t[i])<1e-8));
  checks.push('Translucent inspection and true cut lines render; two parts are identified, a real face click selects the aft component, and only that component moves while RBE103300 and its original GRID stay fixed.');
  await page.screenshot({path:path.join(out,'02-picked-part-moved-retained-rbe.png')});
  await operation('candidates');await page.evaluate(()=>{const i=state.nodeIds.indexOf(13);showNode(i);});
  assert(await page.evaluate(()=>!state.selectionMesh.isPickable&&state.selectionMesh.material.alpha<1));
  fs.writeFileSync(path.join(out,'retained_rbe_model.bdf'),after.text);assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,nodePickEffects,partPickEffects,normalInspectEffects,rfRequests,rfWorkers},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,errors,checks},null,2));throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
