'use strict';
// Actual Boxer generation endpoint, rendering and Study persistence.
// node rib_bay_filter_browser_test.cjs URL PRIVATE_OUTPUT PLAYWRIGHT_MODULE
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[url,out,modulePath]=process.argv.slice(2),{chromium}=require(modulePath);fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,channel:'chrome',args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1500,height:1000}}),errors=[],checks=[];
 page.on('pageerror',e=>errors.push(e.stack));
 const network=[];page.on('requestfailed',r=>network.push({url:r.url(),error:r.failure()?.errorText}));
 try{
  await page.goto(url,{timeout:120000});await page.getByRole('button',{name:'Start new study',exact:true}).waitFor({timeout:90000});console.log('Loaded application');
  await page.evaluate(()=>{document.getElementById('auto-mesh').checked=false;document.getElementById('auto-save').checked=false;});
  await page.getByRole('button',{name:'Start new study',exact:true}).click();await page.waitForFunction(()=>state.autoMeshReady&&!state.workspaceBusy,null,{timeout:300000});console.log('New study ready');
  await page.evaluate(()=>activateWorkspaceTab('displayfilter'));assert(await page.locator('#show-rib-bay-only').isDisabled());
  assert(await page.evaluate(()=>createFEM()),'Default generated FEM must succeed');console.log('Generated model');
  await page.evaluate(()=>{activateWorkspaceTab('displayfilter');window.__filterData=state.data;window.__filterConnectivity=JSON.stringify(state.data.groups.map(g=>[g.conn,g.eids]));window.__filterLayers=[...state.layers].map(([n,l])=>[n,l.visible]);window.__filterIndices=new Map(state.shellMeshes.concat(state.barMeshes).map(m=>[m,Array.from(m.getIndices())]));});
  const count=await page.locator('#rib-bay-select option').count();assert(count>=2);await page.locator('#rib-bay-select').selectOption('2');await page.locator('#show-rib-bay-only').check();
  const stats=await page.evaluate(()=>{
   syncReserveFactorVisibility();const allowed=state.ribBayFilter.allowed;let drawn=0,bad=0,connections=0;
   for(const layer of state.layers.values())for(const m of layer.meshes){if(!m.elementIds?.length||!m.isVisible)continue;const idx=m.getIndices(),stride=m.getClassName()==='LinesMesh'?2:3,meta=m.metadata;
    for(let p=0;p<idx.length/stride;p++){const e=meta.elementId??m.elementIds[meta.faceElements?.[p]??Math.floor(p/(meta.facesPerElement||1))];drawn++;if(!allowed.has(e))bad++;}
    if(meta.feGroup?.kind==='rbe3')connections+=idx.length/2;
   }
   const ribs=WingAnnotations.physicalLabelCandidates(state,currentPositions(),true,false).map(row=>row.id),view=WingWorkspace.captureView(document,state,workspaceUI);WingWorkspace.validateView(view);
   return{total:state.elements.size,selected:allowed.size,drawn,bad,connections,ribs,filter:view.ribBayFilter,layersUnchanged:__filterLayers.every(([n,v])=>state.layers.get(n).visible===v),sourceUnchanged:state.data===__filterData&&JSON.stringify(state.data.groups.map(g=>[g.conn,g.eids]))===__filterConnectivity};
  });
  assert(stats.selected>0&&stats.selected<stats.total);assert.equal(stats.bad,0);assert(stats.drawn>0&&stats.connections>0);assert(stats.layersUnchanged&&stats.sourceUnchanged);assert(stats.ribs.every(r=>r===2||r===3));assert.deepEqual(stats.filter,{enabled:true,rib:2});
  checks.push('Generated FEM bay2 contains all structural/connection families and bounding ribs; no foreign drawn primitive; connectivity and layer switches unchanged.');
  const selectedNode=await page.evaluate(()=>{const node=visibleNodeIndices().values().next().value;showNode(node);syncReserveFactorVisibility();return{node,visible:state.selectionMesh?.isEnabled()&&state.selectionMesh?.isVisible};});assert(selectedNode.visible);
  const freeNode=await page.evaluate(()=>{const elements=state.elements,markers=state.markers,layer=state.layers.get('NODES'),visible=layer.visible,node=state.ribBayFilter.nodes.values().next().value;try{state.elements=new Map();state.markers=[{node,kind:'NODES'}];layer.visible=true;return visibleNodeIndices().has(node);}finally{state.elements=elements;state.markers=markers;layer.visible=visible;}});assert(freeNode);
  await page.evaluate(()=>{clearInspection();window.__changedLayer=state.data.groups.find(g=>state.layers.get(g.name)?.visible).name;setLayerVisible(__changedLayer,false);syncReserveFactorVisibility();});
  checks.push('Visible GRID picking/highlighting and free in-bay node candidates remain available; layer switches can change while filtered.');
  await page.screenshot({path:path.join(out,'bay2.png')});
  await page.evaluate(()=>{document.getElementById('beam-style').value='sections';applyBeamStyle();document.getElementById('shell-geometry').value='thickness';applyShellGeometry();syncReserveFactorVisibility();});
  assert(await page.evaluate(()=>state.shellMeshes.concat(state.barMeshes).filter(m=>m.isVisible&&m.elementIds?.length).every(m=>{const meta=m.metadata,n=m.getIndices().length/(m.barRepresentation==='lines'?2:3);return Array.from({length:n},(_,p)=>m.elementIds[meta.faceElements?.[p]??Math.floor(p/(meta.facesPerElement||1))]).every(id=>state.ribBayFilter.allowed.has(id));})));
  checks.push('Switching to physical shell thickness and beam sections preserves element-exact filtering.');
  await page.locator('#rib-bay-show-all').click();
  assert(await page.evaluate(()=>!state.ribBayFilter.active&&!state.rfVisibleElementIds&&[...__filterIndices].every(([m,indices])=>JSON.stringify(Array.from(m.getIndices()))===JSON.stringify(indices))));
  assert.equal(await page.evaluate(()=>state.layers.get(__changedLayer).visible),false);
  await page.evaluate(()=>{state.ribBayFilter.restore({enabled:true,rib:2});syncReserveFactorVisibility();});assert(await page.locator('#show-rib-bay-only').isChecked());
  await page.evaluate(()=>{state.ribBayFilter.restore();syncReserveFactorVisibility();});assert.equal(await page.locator('#show-rib-bay-only').isChecked(),false);
  checks.push('Show all restores exact original draw indices; Study settings restore a bay and new-study defaults clear it.');
  await page.evaluate(()=>{state.data={...state.data,imported_deck:true};state.ribBayFilter.refresh(true);});assert(await page.locator('#show-rib-bay-only').isDisabled());assert.match(await page.locator('#rib-bay-note').innerText(),/no generated physical rib-plane metadata/);
  checks.push('Imported models without generated rib metadata disable the filter with an explicit explanation.');assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,stats,errors},null,2));console.log(JSON.stringify({passed:true,checks,stats}));
 }catch(e){await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,errors,network,checks},null,2));throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
