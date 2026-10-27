'use strict';
// node mesh_quality_app_browser_test.cjs URL STUDY CORRECTED_PARAMETERS OUTPUT PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [url,fixture,correctedPath,out,modulePath='playwright']=process.argv.slice(2),{chromium}=require(modulePath);
(async()=>{
 fs.mkdirSync(out,{recursive:true});
 const study=JSON.parse(fs.readFileSync(fixture,'utf8')),corrected=JSON.parse(fs.readFileSync(correctedPath,'utf8'));
 const browser=await chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']});
 const page=await browser.newPage({viewport:{width:1800,height:1100}}),errors=[],checks=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(url,{timeout:120000});await page.getByRole('button',{name:'Start new study',exact:true}).click();
  await page.waitForFunction(()=>state.data?.nodes?.count&&!state.meshRequestInFlight&&!state.workspaceBusy&&!state.loadingInput,null,{timeout:240000});
  await page.evaluate(()=>{document.getElementById('auto-save').checked=false;state.autosave?.destroy();document.getElementById('auto-mesh').checked=false;document.getElementById('auto-mesh').dispatchEvent(new Event('change',{bubbles:true}));});
  const loaded=await page.evaluate(async study=>await loadModelDefinition(new File([JSON.stringify(study)],'mesh-correction.wingfem.json',{type:'application/json'}),{recent:true,source:'snapshot'}),study);
  const repair=await page.evaluate(()=>({loaded:state.studyFile,data:state.data?.nodes?.count||null,dirty:state.modelDirty,results:state.resultCases,title:document.getElementById('model-error-title').textContent,message:document.getElementById('model-error-text').textContent,visible:!document.getElementById('model-error').hidden,spars:collectParams()['box.rear_spar_points']}));
  fs.writeFileSync(path.join(out,'repair-load.json'),JSON.stringify({loaded,repair,errors},null,2));
  assert.equal(loaded,true);assert(repair.data>0);assert.equal(repair.dirty,false);assert.equal(repair.results,null);assert.equal(repair.visible,false);
  assert.equal(repair.spars.length,study.parameters['box.rear_spar_points'].length);
  for(let i=0;i<repair.spars.length;i++)for(const key of ['eta','dxc'])assert(Math.abs(repair.spars[i][key]-study.parameters['box.rear_spar_points'][i][key])<1e-12);
  const quality=await page.evaluate(()=>state.data.mesh_quality);
  const mainIssues=quality.issues.filter(i=>i.rib_reference!=='movable');
  assert.equal(quality.status,'warning');assert.equal(mainIssues.reduce((n,i)=>n+i.count,0),22);assert.equal(mainIssues.length,4);assert.equal(quality.analysis_allowed,true);
  assert.equal(quality.warning_element_count,quality.issues.reduce((n,i)=>n+i.count,0));
  for(const width of [900,1280,1800]){
    await page.setViewportSize({width,height:1100});
    const bounds=await page.evaluate(()=>{const a=document.getElementById('btn-mesh-quality').getBoundingClientRect(),b=document.getElementById('btn-study-information').getBoundingClientRect();return{right:a.right,bottom:a.bottom,left:a.left,top:a.top,b:{left:b.left,right:b.right,top:b.top,bottom:b.bottom},width:innerWidth};});
    assert(bounds.left>=0&&bounds.right<=bounds.width);
    assert(bounds.right<=bounds.b.left||bounds.left>=bounds.b.right||bounds.bottom<=bounds.b.top||bounds.top>=bounds.b.bottom,'Quality action must not overlap the information button');
  }
  await page.screenshot({path:path.join(out,'mesh-visible-with-warnings.png')});
  checks.push('Unchanged Study opens with a generated FEM, original geometry and quality warnings (22 main-box faces plus movable warnings)');
  await page.locator('#btn-mesh-quality').click();
  assert.equal(await page.locator('#mesh-quality-dialog').isVisible(),true);
  assert.equal(await page.locator('#mesh-quality-dialog [data-action="review_geometry_control"] button').count(),2);
  assert.match(await page.locator('#mesh-quality-dialog').innerText(),/17\.464 mm/);
  assert.match(await page.locator('#mesh-quality-dialog').innerText(),/4\.311 mm/);
  await page.screenshot({path:path.join(out,'mesh-quality-guidance.png')});
  await page.locator('#mesh-quality-dialog .mesh-quality-actions button').first().click();
  assert.equal(await page.evaluate(()=>workspaceUI.activeTab),'box');
  assert.equal(await page.locator('#mesh-quality-dialog').isVisible(),false);
  checks.push('Compact review gives two deduplicated physical corrections and opens the relevant spar editor without editing values');
  await page.evaluate(()=>{
   state.parameterLocks?.restore({planform:false,mesh:false});
   document.getElementById('auto-mesh').checked=false;state.autoMeshEnabled=false;cancelAutoMeshTimer();
  });
  for(const [key,label] of [['box.front_spar_points','Front spar'],['box.rear_spar_points','Rear spar']]){
   const input=page.getByLabel(label+' point 2 eta',{exact:true});
   await input.fill(String(corrected[key][1].eta));await input.press('Tab');
  }
  await page.evaluate(()=>createFEM({preserveView:true}));
  const fixed=await page.evaluate(()=>({count:state.data?.nodes?.count,dirty:state.modelDirty,error:document.getElementById('model-error-text').textContent,signature:state.modelSignature}));
  fs.writeFileSync(path.join(out,'corrected-generation.json'),JSON.stringify(fixed,null,2));
  assert(fixed.count>0);assert.equal(fixed.dirty,false);
  assert.equal(await page.evaluate(()=>state.data.mesh_quality.issues.filter(i=>i.rib_reference!=='movable').length),0);
  checks.push('Explicit point alignment removes all main-box warnings while retaining separately identified movable warnings');
  await page.evaluate(()=>{fitView();window.acceptedMesh=state.data;window.acceptedCamera=[state.camera.alpha,state.camera.beta,state.camera.radius,...state.camera.target.asArray()];});
  await page.evaluate(original=>{for(const key of ['box.front_spar_points','box.rear_spar_points']){document.getElementById('p-'+key).value=JSON.stringify(original[key]);state.sparEditor.externalChange(key);parameterEdited(key);}},study.parameters);
  await page.evaluate(()=>createFEM({preserveView:true}));
  const retained=await page.evaluate(()=>({same:state.data===acceptedMesh,camera:[state.camera.alpha,state.camera.beta,state.camera.radius,...state.camera.target.asArray()],before:acceptedCamera,dirty:state.modelDirty,message:document.getElementById('model-error-text').textContent}));
  assert.equal(retained.same,false);assert.equal(retained.dirty,false);assert.deepEqual(retained.camera,retained.before);
  assert.equal(await page.locator('#btn-mesh-quality').isVisible(),true);
  assert.equal(await page.evaluate(()=>state.data.mesh_quality.warning_element_count),quality.warning_element_count);
  assert.equal(await page.locator('#model-error').isVisible(),false);
  checks.push('Restoring the original near-rib geometry regenerates with warnings, preserving camera and allowing inspection');
  assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,backend:await page.evaluate(()=>state.engine.isWebGPU?'WebGPU':'WebGL'),checks,repair,fixed,retained,errors},null,2));
  console.log(checks.join('\n'));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,errors,checks},null,2));throw error;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
