'use strict';
// node stringer_conversion_app_browser_test.cjs URL STUDY OUTPUT PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [url,fixture,out,modulePath='playwright']=process.argv.slice(2),{chromium}=require(modulePath);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']}),page=await browser.newPage({viewport:{width:1800,height:1100}}),errors=[],checks=[];
 page.on('pageerror',e=>errors.push(e.message));
 const ready=()=>page.waitForFunction(()=>state.data?.nodes?.count&&workspaceOperationAvailable(),null,{timeout:240000});
 try{
  await page.goto(url,{timeout:120000});await page.getByRole('button',{name:'Start new study',exact:true}).click();await ready();
  await page.evaluate(()=>{document.getElementById('auto-save').checked=false;state.autosave?.destroy();document.getElementById('auto-mesh').checked=false;document.getElementById('auto-mesh').dispatchEvent(new Event('change',{bubbles:true}));window.testGPUErrors=[];state.engine._device?.addEventListener('uncapturederror',e=>testGPUErrors.push(e.error.message));});
  const study=JSON.parse(fs.readFileSync(fixture,'utf8'));
  const loaded=await page.evaluate(async study=>{study.view=WingWorkspace.captureView(document,state,workspaceUI);study.view.controls['auto-mesh']=false;study.view.controls['auto-save']=false;return await loadModelDefinition(new File([JSON.stringify(study)],'blade-conversion.wingfem.json',{type:'application/json'}),{recent:true,source:'snapshot'});},study);
  assert.equal(loaded,true,await page.locator('#model-error').innerText());
  await page.evaluate(()=>createFEM({preserveView:true}));await ready();
  const input=key=>page.locator('[id="p-'+key+'"]');
  await page.evaluate(()=>activateWorkspaceTab('stringerlayout'));
  assert.equal(await input('stringers.model').inputValue(),'shell');
  await input('stringers.model').selectOption('beam');
  assert(await page.locator('[id="row-stringers.orientation"]').isVisible());
  assert(await page.locator('#stringer-model-note').innerText().then(s=>s.includes('von-Mises stress envelope is unavailable')));
  await page.evaluate(()=>createFEM({preserveView:true}));await ready();
  const info=await page.evaluate(()=>{
   const p=collectParams(),groups=state.data.groups.filter(g=>g.base_group==='STRINGERS');
   return{mode:p['stringers.model'],dimensions:['flange_width','height','flange_thickness','web_thickness'].map(f=>p['properties.stringer_'+f]),axis:[p['stringers.orientation'],p['stringers.axis_cid'],p['stringers.axis']],sections:groups.map(g=>g.properties.section),dirty:state.modelDirty};
  });
  assert.equal(info.mode,'beam');assert.equal(info.dirty,false);assert.deepEqual(info.dimensions,[0,.04,0,.002]);assert.deepEqual(info.axis,['coordinate_axis',0,'z']);
  assert(info.sections.length>0);assert(info.sections.every(s=>s.shape==='BAR'&&s.dimensions_m[0]===.002&&s.dimensions_m[1]===.04&&s.offset_y_m===-.02));
  checks.push('Actual app generates zero-flange shell stringers as PBARL BAR, retaining all section dimensions and selected axis');
  await page.evaluate(()=>{activateWorkspaceTab('sections');document.getElementById('beam-style').value='sections';document.getElementById('beam-style').dispatchEvent(new Event('change',{bubbles:true}));document.getElementById('surface-mode').value='translucent';document.getElementById('surface-mode').dispatchEvent(new Event('change',{bubbles:true}));fitView();});
  assert.equal(await page.locator('#stringer-section-editor .section-card-type').innerText(),'PBARL / BAR · blade');assert.equal(await page.locator('#stringer-section-editor.section-editor-invalid').count(),0);
  const rendered=await page.evaluate(()=>state.barMeshes.filter(m=>m.sectionGeometry&&m.metadata?.feGroup?.base_group==='STRINGERS').map(m=>({enabled:m.isEnabled(),shape:m.metadata.feGroup.properties.section.shape,finite:Array.from(m.getVerticesData(BABYLON.VertexBuffer.PositionKind)).every(Number.isFinite)})));
  assert(rendered.length>0&&rendered.every(m=>m.enabled&&m.shape==='BAR'&&m.finite));
  await page.screenshot({path:path.join(out,'blade-beam-3d.png')});checks.push('Physical rectangular beam sections render in 3D with no synthetic flange or nonfinite vertices');
  await page.evaluate(()=>activateWorkspaceTab('stringerlayout'));await input('stringers.model').selectOption('shell');await page.evaluate(()=>createFEM({preserveView:true}));await ready();
  const restored=await page.evaluate(()=>({p:collectParams(),webs:state.data.groups.filter(g=>g.base_group==='STRINGER_WEBS').length,bars:state.data.groups.filter(g=>g.base_group==='STRINGERS').length}));
  assert(restored.webs>0);assert.equal(restored.bars,0);for(const field of ['flange_width','height','flange_thickness','web_thickness'])assert.equal(restored.p['properties.stringer_'+field],study.parameters['properties.stringer_'+field]);checks.push('Switching back regenerates shell blades and retains the original zero-width/zero-thickness flange settings');
  const gpuErrors=await page.evaluate(()=>testGPUErrors);assert.deepEqual(errors,[]);assert.deepEqual(gpuErrors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,backend:await page.evaluate(()=>state.engine.isWebGPU?'WebGPU':'WebGL'),checks,info,rendered,errors,gpuErrors},null,2));console.log(checks.join('\n'));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,errors,checks,modelError:await page.locator('#model-error').innerText().catch(()=>''),log:await page.locator('#log').innerText().catch(()=>'')},null,2));throw error;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
