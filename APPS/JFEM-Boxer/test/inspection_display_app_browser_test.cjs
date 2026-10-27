'use strict';
// node inspection_display_app_browser_test.cjs URL OUTPUT PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [url,out,modulePath='playwright']=process.argv.slice(2),{chromium}=require(modulePath);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']}),page=await browser.newPage({viewport:{width:1800,height:1100}}),errors=[],checks=[];
 page.on('pageerror',e=>errors.push(e.message));
 const ready=()=>page.waitForFunction(()=>state.data?.nodes?.count&&!state.meshRequestInFlight&&!state.workspaceBusy&&!state.loadingInput,null,{timeout:240000});
 try{
  await page.goto(url,{timeout:120000});await page.getByRole('button',{name:'Start new study',exact:true}).click();await ready();
  await page.evaluate(()=>{document.getElementById('auto-save').checked=false;state.autosave?.destroy();document.getElementById('auto-mesh').checked=false;document.getElementById('auto-mesh').dispatchEvent(new Event('change',{bubbles:true}));window.testGPUErrors=[];state.engine._device?.addEventListener('uncapturederror',e=>testGPUErrors.push(e.error.message));});
  await page.locator('#tab-engines').click();await page.locator('#engine-add').click();await page.locator('[data-engine-field=z]').fill('-1.2');await page.locator('#engine-create-fem').click();await ready();
  const engine=await page.evaluate(()=>state.data.engine_structure.engines[0]);assert(engine&&engine.mounts.length===2);
  const rbe3=await page.evaluate(()=>{
   const rows=[...state.elements.values()].filter(e=>e.group.kind==='rbe3');document.getElementById('inspect-entity').value='rbe3';inspectFilterChanged();
   for(const row of rows){if(!inspectionMatches(row.group,'rbe3')||!inspectionMatches(row.group,'connection'))throw Error('Unsupported RBE3 filter');document.getElementById('inspect-id').value=String(row.id);inspectById();if(state.selectedElement!==row.id)throw Error('RBE3 ID inspection failed');}
   return rows.map(e=>({eid:e.id,layer:e.group.name}));
  });assert(rbe3.length>=2);assert.equal(rbe3.filter(e=>e.layer==='ENGINE_ATTACHMENTS').length,2);checks.push('Every RBE3 family is inspectable by ID with both RBE3 and Connections filters');
  await page.evaluate(()=>{for(const[name]of state.layers)setLayerVisible(name,name==='ENGINE_ATTACHMENTS'||name==='ENGINE_BEAMS');fitView();activateWorkspaceTab('inspect');document.getElementById('inspect-entity').value='rbe3';inspectFilterChanged();});
  for(const mount of engine.mounts){
   const point=await page.evaluate(eid=>{
    const e=state.elements.get(eid),p=e.nodes.slice(0,2).map(n=>n),a=Array.from(state.baseline.slice(3*p[0],3*p[0]+3)),b=Array.from(state.baseline.slice(3*p[1],3*p[1]+3)),world=new BABYLON.Vector3(...a.map((v,i)=>v*.6+b[i]*.4));
    const c=state.engine.getRenderingCanvas(),r=c.getBoundingClientRect(),w=state.engine.getRenderWidth(),h=state.engine.getRenderHeight(),screen=BABYLON.Vector3.Project(world,BABYLON.Matrix.Identity(),state.scene.getTransformMatrix(),state.camera.viewport.toGlobal(w,h));
    return{x:r.left+screen.x*r.width/w,y:r.top+screen.y*r.height/h};
   },mount.eid);
   await page.mouse.click(point.x,point.y);await page.waitForFunction(eid=>state.selectedElement===eid,mount.eid);
   const text=await page.locator('#pick-content').innerText();assert(text.includes('RBE3')&&text.includes(String(mount.eid))&&text.includes('Adjacent cap ribs'));
   assert(text.includes('123456')&&!text.includes('[object Object]')&&!text.includes('Minimum reserve factor'),'RBE3 inspection preserves exact component masks and useful records without irrelevant RF sections');
  }
  const metadata=await page.evaluate(()=>({proxies:state.scene.meshes.filter(m=>m.metadata?.wingStrokeSource).every(m=>!m.isPickable),engineColors:state.scene.meshes.filter(m=>m.engineBeamCylinder).map(m=>m.material.diffuseColor.toHexString()),dofs:WingRbe3Labels.candidates(state,currentPositions(),true).filter(r=>state.elements.get(r.id)?.group.name==='ENGINE_ATTACHMENTS').map(r=>r.text)}));
  assert(metadata.proxies);assert.equal(metadata.engineColors.length,2);assert(metadata.engineColors.every(c=>c==='#DC2638'));assert(metadata.dofs.some(s=>s.includes('REFGRID 123456'))&&metadata.dofs.some(s=>s.includes('ind 123')));checks.push('Mouse picking reaches each engine RBE3 through unpickable screen strokes; real GRID roles/weights are labeled and beam cylinders are red');
  await page.screenshot({path:path.join(out,'engine-rbe3-inspection.png')});
  await page.evaluate(()=>{activateWorkspaceTab('displayloads');for(const[name]of state.layers)setLayerVisible(name,name==='SPC');document.getElementById('marker-radius').value='.025';updateMarkerRadii();fitView();});
  const initialRadius=await page.evaluate(()=>state.supportGlyphs.radius);await page.locator('#constraint-marker-size').fill('2.5');await page.locator('#show-constraint-glow').check();
  assert.equal(await page.evaluate(()=>state.supportGlyphs.radius),initialRadius*2.5);assert(await page.evaluate(()=>state.supportGlyphs.glow.isEnabled));assert(await page.locator('#panel-displayloads #constraint-marker-size').isVisible());
  await page.waitForTimeout(400);await page.screenshot({path:path.join(out,'constraint-size-glow.png')});checks.push('Loads&Constraints controls resize all six SPC components and toggle their halo without moving their GRIDs');
  await page.evaluate(()=>{activateWorkspaceTab('displaylabels');fitView();document.getElementById('show-global-axis-labels').checked=true;document.getElementById('show-global-axis-labels').dispatchEvent(new Event('change',{bubbles:true}));});
  await page.waitForTimeout(200);await page.evaluate(()=>state.annotations.render(true));const labels=await page.evaluate(()=>state.annotations.stats.globalAxesShown);assert.deepEqual([...labels].sort(),['x','y','z']);assert(await page.locator('#panel-displaylabels #show-global-axis-labels').isVisible());checks.push('Axes&Labels paints x, y and z at the actual global axis tips');
  await page.screenshot({path:path.join(out,'global-axis-tip-labels.png')});
  const study=await page.evaluate(async()=>{const r=await postParams('/api/validate_workspace',collectParams()),body=await r.json();if(!r.ok)throw Error(body.error);return WingWorkspace.snapshot(body.parameters,state.reference,WingWorkspace.captureView(document,state,workspaceUI),{notes:state.studyNotes});});
  assert.equal(study.view.controls['constraint-marker-size'],'2.5');
  await page.evaluate(async study=>{document.getElementById('show-global-axis-labels').checked=false;document.getElementById('show-constraint-glow').checked=false;document.getElementById('constraint-marker-size').value='1';await loadModelDefinition(new File([JSON.stringify(study)],'display-test.wingfem.json',{type:'application/json'}),{recent:true,source:'snapshot'});},study);
  await ready();await page.evaluate(()=>createFEM({preserveView:true}));await ready();
  assert(await page.locator('#show-global-axis-labels').isChecked());assert(await page.locator('#show-constraint-glow').isChecked());assert.equal(await page.locator('#constraint-marker-size').inputValue(),'2.5');assert(await page.evaluate(()=>state.supportGlyphs.glow.isEnabled));checks.push('Study save/reopen restores the constraint size, glow and global labels and applies them to regenerated geometry');
  const gpuErrors=await page.evaluate(()=>testGPUErrors);assert.deepEqual(errors,[]);assert.deepEqual(gpuErrors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,backend:await page.evaluate(()=>state.engine.isWebGPU?'WebGPU':'WebGL'),checks,rbe3,metadata,labels,errors,gpuErrors},null,2));console.log(checks.join('\n'));
 }catch(e){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,errors,checks},null,2));throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
