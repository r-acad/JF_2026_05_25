'use strict';
// node movable_meshed_preview_browser_test.cjs URL OUTPUT PLAYWRIGHT
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const [url,out,modulePath='playwright']=process.argv.slice(2);
if(!url||!out)throw Error('Expected URL and output folder');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const {chromium}=require(modulePath),browser=await chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']}),page=await browser.newPage({viewport:{width:1800,height:1100}}),errors=[],checks=[];
 let generated=0;page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(new URL(r.url()).pathname==='/api/generate')generated++;});
 const ready=()=>page.waitForFunction(()=>state.data?.nodes?.count&&!state.meshRequestInFlight&&!state.workspaceBusy&&!state.loadingInput,null,{timeout:240000});
 try{
  await page.goto(url,{timeout:180000});await page.getByRole('button',{name:'Start new study',exact:true}).click();await ready();
  await page.evaluate(async()=>{
   document.getElementById('auto-save').checked=false;state.autosave?.destroy();document.getElementById('auto-mesh').checked=false;
   const params={...collectParams(),'planform.area':2,'planform.aspect_ratio':2,'planform.taper_ratio':.8,'planform.sweep':12,'planform.dihedral':2,'planform.twist_tip':-3,
    'box.end_eta':1,'box.rib_pitch':.25,'box.stringer_pitch':.2,'mesh.elements_between_ribs':2,'mesh.elements_spar_height':2,'mesh.aero_chord_points':9,'airfoil.n_points':31,
    'loads.method':'analytic','loads.lift_total':1,'loads.structure_inertia':false,'fuel.enabled':false,'loads.cases':[],
    'movable_surfaces.items':[{name:'Meshed flap',kind:'flap',edge:'trailing',eta_start:.05,eta_end:.95,front_spar_start:.78,front_spar_end:.8,hinge_start:.7,hinge_end:.72,hinge_z_start:0,hinge_z_end:0,deflection:0,color:'#ec751c'}],
    'movable_structure.surfaces':[{...WingMovableStructure.defaults,surface:'Meshed flap',span_bays:4,span_elements:2,chord_elements:4,height_elements:2,mesh_deflected:false}],
    'movable_structure.attachments':[.26,.74].map(eta=>({...WingMovableStructure.attachmentDefaults,surface:'Meshed flap',eta,fitting:'shell_lugs',actuator:true}))};
   const response=await postParams('/api/validate_workspace',params),body=await response.json();if(!response.ok)throw Error(body.error);
   const study=await WingWorkspace.snapshot(body.parameters,state.reference,WingWorkspace.captureView(document,state,workspaceUI),{notes:state.studyNotes});
   if(!await loadModelDefinition(new File([JSON.stringify(study)],'meshed-preview.wingfem.json',{type:'application/json'}),{recent:true}))throw Error('Fixture load failed');
  });
  await ready();await page.evaluate(async()=>{if(!await createFEM({preserveView:true}))throw Error('Fixture FEM generation failed');activateWorkspaceTab('movablesurfaces');});await ready();
  await page.waitForFunction(()=>state.data.movable_structure?.surfaces.length===1&&state.movablePreview?.meshes.length===2,null,{timeout:120000});
  assert.equal(await page.evaluate(()=>state.data.movable_structure.surfaces[0].mesh_deflected),false);
  await page.locator('#movable-preview-style').selectOption('solid');
  await page.evaluate(()=>{applyBackgroundColor('#ffffff',false);fitView();document.getElementById('auto-mesh').checked=true;});
  const initial=await page.evaluate(()=>({baseline:Array.from(state.baseline),signature:state.modelSignature,camera:[state.camera.alpha,state.camera.beta,state.camera.radius,...state.camera.target.asArray()],
   vertices:Array.from(state.movablePreview.meshes[0].getVerticesData(BABYLON.VertexBuffer.PositionKind)),hinge:Array.from(state.movablePreview.meshes[1].getVerticesData(BABYLON.VertexBuffer.PositionKind))}));
  const requestBaseline=generated,angles=[];const angleInput=page.locator('#group-movable-surfaces [data-movable-field=deflection]').first();
  for(const angle of [0,45,-45,180,360]){
   if(angle!==0){const old=await page.evaluate(()=>state.movablePreview.meshes[0].uniqueId);await angleInput.fill(String(angle));await page.waitForFunction(old=>state.movablePreview?.meshes.length===2&&state.movablePreview.meshes[0].uniqueId!==old&&document.querySelector('#movable-status')?.textContent.startsWith('1 movable'),old,{timeout:120000});}
   assert(await angleInput.evaluate(e=>e.validity.valid));
   const report=await page.evaluate(({initial,angle})=>{
    const p=state.movablePreview.meshes[0].getVerticesData(BABYLON.VertexBuffer.PositionKind),origin=initial.hinge.slice(0,3),axis=initial.hinge.slice(3).map((v,i)=>v-origin[i]),len=Math.hypot(...axis);axis.forEach((v,i)=>axis[i]=v/len);
    const c=Math.cos(angle*Math.PI/180),s=Math.sin(angle*Math.PI/180);let maxError=0;
    for(let i=0;i<p.length;i+=3){const v=initial.vertices.slice(i,i+3).map((x,j)=>x-origin[j]),d=v.reduce((a,x,j)=>a+x*axis[j],0),cross=[axis[1]*v[2]-axis[2]*v[1],axis[2]*v[0]-axis[0]*v[2],axis[0]*v[1]-axis[1]*v[0]];for(let j=0;j<3;j++)maxError=Math.max(maxError,Math.abs(p[i+j]-(origin[j]+c*v[j]+s*cross[j]+(1-c)*d*axis[j])));}
    return{angle,maxError,enabled:state.movablePreview.meshes.every(m=>m.isEnabled()),baselineUnchanged:initial.baseline.every((v,i)=>v===state.baseline[i]),camera:[state.camera.alpha,state.camera.beta,state.camera.radius,...state.camera.target.asArray()],signatureUnchanged:state.modelSignature===initial.signature&&!state.modelDirty};
   },{initial,angle});
   assert(report.maxError<2e-6,JSON.stringify(report));assert(report.enabled&&report.baselineUnchanged&&report.signatureUnchanged,JSON.stringify(report));assert.deepEqual(report.camera,initial.camera);angles.push(report);
   if(angle===45||angle===180){await page.waitForTimeout(350);await page.screenshot({path:path.join(out,'meshed-preview-'+angle+'.png')});}
  }
  checks.push('Structurally meshed surface remains visible at 0, +45, -45, 180 and 360 degrees, with the expected rigid rotation about its actual hinge');
  for(const style of ['translucent','solid','wireframe','metallic']){
   await page.locator('#movable-preview-style').selectOption(style);assert.equal(await page.evaluate(()=>state.movablePreview.style),style);
   await page.locator('#show-movable-preview').uncheck();assert(await page.evaluate(()=>state.movablePreview.surfaceMeshes.every(m=>!m.isEnabled())&&state.movablePreview.hingeMeshes.every(m=>m.isEnabled())));
   await page.locator('#show-movable-preview').check();assert(await page.evaluate(()=>state.movablePreview.meshes.every(m=>m.isEnabled())));
  }
  await page.evaluate(()=>{setLayerVisible('MOVABLE_PREVIEW',false);setLayerVisible('MOVABLE_PREVIEW_HINGES',false);});
  assert(await page.evaluate(()=>!document.getElementById('show-movable-preview').checked&&!document.getElementById('show-movable-hinges').checked&&state.movablePreview.meshes.every(m=>!m.isEnabled())));
  await page.evaluate(()=>{setLayerVisible('MOVABLE_PREVIEW_HINGES',true);});
  assert(await page.evaluate(()=>state.movablePreview.surfaceMeshes.every(m=>!m.isEnabled())&&state.movablePreview.hingeMeshes.every(m=>m.isEnabled())));
  await page.evaluate(()=>{setLayerVisible('MOVABLE_PREVIEW',true);});
  assert.equal(await page.locator('#entity-group-aerodynamics [data-component="MOVABLE_PREVIEW"]').count(),1);
  assert.equal(await page.locator('#entity-group-aerodynamics [data-component="MOVABLE_PREVIEW_HINGES"]').count(),1);
  checks.push('Aerodynamic geometry independently controls movable previews and hinge lines, synchronized with Geometry controls');
  await page.waitForTimeout(1000);
  assert.equal(generated,requestBaseline,'Preview-only angles must not regenerate a neutral structural mesh, even with Live mesh on');
  const final=await page.evaluate(()=>({baseline:Array.from(state.baseline),camera:[state.camera.alpha,state.camera.beta,state.camera.radius,...state.camera.target.asArray()]}));assert.deepEqual(final.baseline,initial.baseline);assert.deepEqual(final.camera,initial.camera);
  checks.push('All four finishes and the preview toggle leave FE nodes and camera unchanged; preview-only angle edits do not generate a new FEM');
  const wire=await page.evaluate(()=>{
   refreshStressReport(true);showReserveFactorField({kind:'failure_rf',failureMode:'skin_buckling',caseId:'all',method:'maximum',percentile:95,palette:'signed',onlyBelowOne:false});
   const meshes=state.shellMeshes.filter(m=>m.metadata?.feGroup?.properties?.movable_surface||/^MOVABLE_/.test(m.metadata?.feGroup?.name||''));
   return{count:meshes.length,wire:meshes.every(m=>m.material.wireframe&&m.material.zOffset===0&&m.material.zOffsetUnits===0),preview:state.movablePreview.style};
  });assert(wire.count>0&&wire.wire);assert.equal(wire.preview,'wireframe');
  await page.waitForTimeout(500);await page.screenshot({path:path.join(out,'unassessed-movable-wireframe.png')});
  await page.evaluate(()=>clearReserveFactorField());
  assert(await page.evaluate(()=>state.shellMeshes.filter(m=>m.metadata?.feGroup?.properties?.movable_surface||/^MOVABLE_/.test(m.metadata?.feGroup?.name||'')).every(m=>!m.material.wireframe)));
  assert.equal(await page.evaluate(()=>state.movablePreview.style),'metallic');
  checks.push('RF views render unassessed movable shells and geometry previews as wireframe and restore normal styling on clear');
  assert.deepEqual(errors,[]);const result={passed:true,checks,angles,wire,generateRequests:generated-requestBaseline,errors};fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors,detail:await page.evaluate(()=>({status:document.querySelector('#movable-status')?.textContent,modelError:document.querySelector('#model-error-text')?.textContent,log:document.querySelector('#log')?.textContent?.slice(-3000)}))},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
