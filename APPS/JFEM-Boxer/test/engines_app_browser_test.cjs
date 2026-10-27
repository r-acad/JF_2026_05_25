'use strict';
// node engines_app_browser_test.cjs URL OUTPUT PLAYWRIGHT
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const [url,out,modulePath='playwright']=process.argv.slice(2);
if(!url||!out)throw Error('Expected URL and output folder');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const {chromium}=require(modulePath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']}),page=await browser.newPage({viewport:{width:1900,height:1100}}),errors=[],checks=[];
 page.on('pageerror',error=>errors.push(error.message));
 try{
  await page.goto(url,{timeout:120000});await page.getByRole('button',{name:'Start new study',exact:true}).click();
  await page.waitForFunction(()=>state.data?.nodes?.count&&!state.meshRequestInFlight,null,{timeout:180000});
  await page.locator('#auto-mesh').uncheck();await page.evaluate(()=>{document.getElementById('auto-save').checked=false;state.autosave?.destroy();});
  const original=await page.evaluate(()=>({nodes:state.data.nodes.count,params:state.data.model_params,signature:state.modelSignature}));
  assert.equal(await page.evaluate(()=>state.data.engine_structure.engines.length),0);
  await page.locator('#tab-engines').click();assert.equal(await page.evaluate(()=>workspaceUI.activeTab),'engines');
  await page.locator('#engine-add').click();const visible=()=>page.locator('#group-engines .engine-card:not([hidden])');
  await visible().locator('[data-engine-field=name]').fill('Validation engine');
  await visible().locator('[data-engine-field=mass]').fill('650');await visible().locator('[data-engine-field=length]').fill('2.4');
  for(const[key,value]of [['E','68'],['G','25'],['A','.012'],['I1','.00016'],['I2','.00018'],['J','.0003']])await visible().locator('[data-engine-field='+key+']').fill(value);
  await visible().locator('[data-engine-field=x]').fill('0.3');await visible().locator('[data-engine-field=y]').fill('1.2');await visible().locator('[data-engine-field=z]').fill('-1.4');
  assert(await page.evaluate(()=>state.modelDirty&&state.studyDirty));assert.equal(await page.evaluate(()=>state.data.nodes.count),original.nodes);
  const entered=await page.evaluate(()=>collectParams()['engines.items']);assert.equal(entered[0].front_rib,2);
  assert.equal(entered[0].E,68e9);assert.equal(entered[0].G,25e9);assert.equal(entered[0].I1,.00016);
  await page.locator('#engine-create-fem').click();
  await page.waitForFunction(()=>!state.meshRequestInFlight&&state.data?.engine_structure?.engines.length===1,null,{timeout:240000});
  assert(await page.evaluate(()=>formSignature()===state.modelSignature&&formSignature(state.data.model_params)===state.modelSignature));
  const record=await page.evaluate(()=>state.data.engine_structure.engines[0]);assert.equal(record.mass_kg,650);assert.equal(record.length_m,2.4);assert.equal(record.mounts[0].rib,2);assert.equal(record.mounts[1].rib,2);
  assert.deepEqual(record.center_of_gravity_m,[.3,1.2,-1.4]);
  assert.equal(record.mounts[0].ref,record.cg_node);assert.equal(record.cg_node,record.beam_nodes[1]);
  assert.equal(record.mounts[1].ref,record.beam_nodes[2]);
  assert.equal(record.mounts[0].nodes.length,2);assert.equal(new Set(record.mounts[0].nodes).size,2);
  assert.equal(record.mounts[1].nodes.length,3);assert.equal(new Set(record.mounts[1].nodes).size,3);
  for(const mount of record.mounts){
    assert.equal(mount.inboard_cap_nodes.length,1);assert.equal(mount.outboard_cap_nodes.length,1);
    assert.equal(mount.cap_nodes.length,2);assert.deepEqual([...mount.cap_span_indices].sort((a,b)=>a-b),mount.cap_span_indices);
  }
  assert.deepEqual(record.mounts[0].nodes,record.mounts[0].cap_nodes);
  assert.deepEqual(record.mounts[1].nodes,[...record.mounts[1].cap_nodes,record.mounts[1].rib_node]);
  assert.deepEqual(record.mounts[0].cap_span_indices,record.mounts[1].cap_span_indices);
  assert.deepEqual(record.arm_eids,[]);
  assert.deepEqual(await page.evaluate(()=>state.data.model_params['engines.items']),entered);
  checks.push('Model / Engines creates the requested flexible engine with CG, mass, length, editable stiffness and two rib attachments; result identity matches normalized solver parameters');
  const connections=await page.evaluate(()=>{
    const r=state.data.engine_structure.engines[0],collection=state.data.imported_connections.find(c=>c.name==='ENGINE_ATTACHMENTS'),layer=state.layers.get('ENGINE_ATTACHMENTS');
    setLayerVisible('ENGINE_ATTACHMENTS',true);
    const mesh=layer.meshes.find(m=>m instanceof BABYLON.LinesMesh),vertices=Array.from(mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind)),expected=[];
    for(const mount of r.mounts)for(const node of mount.nodes)for(const n of [mount.ref,node])expected.push(...state.baseline.slice(3*n,3*n+3));
    return{elements:collection.elements.map(e=>({eid:e.eid,nodes:e.nodes})),legOwners:mesh.metadata.faceElements,
      picked:mesh.metadata.faceElements.map((_,faceId)=>WingModelEntities.pickedElementId({hit:true,pickedMesh:mesh,faceId})),
      verticesMatch:vertices.length===expected.length&&vertices.every((v,i)=>Math.abs(v-expected[i])<1e-6),
      upperAboveLower:r.mounts[0].cap_nodes.every((n,i)=>state.baseline[3*n+1]>state.baseline[3*r.mounts[1].cap_nodes[i]+1]),
      visible:mesh.isVisible&&mesh.isEnabled(),hasArmLayer:state.layers.has('ENGINE_MOUNT_ARMS'),
      hasArmCollection:state.data.imported_connections.some(c=>c.name==='ENGINE_MOUNT_ARMS')};
  });
  assert.deepEqual(connections.elements,record.mounts.map(m=>({eid:m.eid,nodes:[m.ref,...m.nodes]})));
  assert.deepEqual(connections.legOwners,[0,0,1,1,1]);
  assert.deepEqual(connections.picked,[...Array(2).fill(record.mounts[0].eid),...Array(3).fill(record.mounts[1].eid)]);
  assert(connections.verticesMatch&&connections.visible&&connections.upperAboveLower);assert(!connections.hasArmLayer&&!connections.hasArmCollection);
  checks.push('Front RBE3 starts at the engine CG with two adjacent-rib cap legs; aft RBE3 starts at the aft beam end with three legs; each rendered leg retains its correct inspection ID and no rigid-arm layer remains');
  const rendering=await page.evaluate(()=>{
    const records=state.deformable.filter(row=>row.engineBeam),B=BABYLON,report=[];
    for(const row of records){const nodes=row.engineBeam.nodes,positions=state.baseline.slice();positions[3*nodes[1]]+=.17;positions[3*nodes[1]+1]-=.23;positions[3*nodes[1]+2]+=.11;
      WingModelEntities.updateEngineBeamMesh(B,row,positions,state.panelExplosion);
      const delta=[0,1,2].map(k=>positions[3*nodes[1]+k]-positions[3*nodes[0]+k]),length=Math.hypot(...delta),rotation=B.Matrix.Identity();row.mesh.rotationQuaternion.toRotationMatrix(rotation);
      const axis=B.Vector3.TransformNormal(B.Axis.Y,rotation).normalize(),alignment=B.Vector3.Dot(axis,new B.Vector3(...delta).normalize());
      report.push({id:row.engineBeam.eid,visible:row.mesh.isEnabled()&&row.mesh.isVisible,lengthError:Math.abs(row.mesh.scaling.y-length),centerError:Math.max(...[0,1,2].map(k=>Math.abs(row.mesh.position.asArray()[k]-(positions[3*nodes[0]+k]+positions[3*nodes[1]+k])/2))),alignment,picked:WingModelEntities.pickedElementId({hit:true,pickedMesh:row.mesh})});
      WingModelEntities.updateEngineBeamMesh(B,row,state.baseline,state.panelExplosion);
    }
    setLayerVisible('ENGINE_BEAMS',false);const hidden=records.every(row=>!row.mesh.isEnabled());setLayerVisible('ENGINE_BEAMS',true);
    return{report,hidden,restored:records.every(row=>row.mesh.isEnabled()),layers:['ENGINE_BEAMS','ENGINE_ATTACHMENTS','ENGINE_MASSES'].map(name=>({name,visible:state.layers.get(name)?.visible}))};
  });
  assert.equal(rendering.report.length,2);for(const row of rendering.report){assert(row.visible);assert(row.lengthError<1e-10);assert(row.centerError<1e-10);assert(row.alignment>1-1e-10);assert.equal(row.picked,row.id);}assert(rendering.hidden&&rendering.restored);
  checks.push('Both engine beam halves render as pickable cylinders, follow unequal endpoint displacement in length and orientation, and respect their visibility layer');
  await page.evaluate(()=>{const id=state.data.engine_structure.engines[0].beam_eids[0];activateWorkspaceTab('inspect');showElement(id);});
  assert.match(await page.locator('#pick-card').textContent(),/Validation engine/);
  await page.screenshot({path:path.join(out,'engine-model-inspection.png')});
  await page.locator('#tab-engines').click();await page.screenshot({path:path.join(out,'engine-form-model.png')});
  await page.evaluate(()=>{
    const r=state.data.engine_structure.engines[0],nodes=[...new Set([...r.beam_nodes,...r.mounts.flatMap(m=>m.nodes)])],p=nodes.map(n=>Array.from(state.baseline.slice(3*n,3*n+3))),min=[0,1,2].map(k=>Math.min(...p.map(v=>v[k]))),max=[0,1,2].map(k=>Math.max(...p.map(v=>v[k]))),center=min.map((v,k)=>(v+max[k])/2),diag=Math.hypot(...max.map((v,k)=>v-min[k]));
    for(const name of ['RBE3','RBE3_NODES','FUEL_RBE3','FUEL_RBE3_NODES','REFERENCE_AERO'])if(state.layers.has(name))setLayerVisible(name,false);
    const mode=document.getElementById('surface-mode');mode.value='translucent';mode.dispatchEvent(new Event('change'));
    state.camera.setTarget(new BABYLON.Vector3(...center));state.camera.alpha=-1.1;state.camera.beta=1.07;state.camera.radius=diag*1.4;syncCameraClipping();
  });
  await page.waitForTimeout(700);await page.locator('#render').screenshot({path:path.join(out,'engine-cap-mounts-closeup.png')});
  const study=await page.evaluate(async()=>{const response=await postParams('/api/validate_workspace',collectParams()),body=await response.json();if(!response.ok)throw Error(body.error);return WingWorkspace.snapshot(body.parameters,state.reference,WingWorkspace.captureView(document,state,workspaceUI),{notes:state.studyNotes});});
  const studyFile=path.join(out,'engine-roundtrip.wingfem.json');fs.writeFileSync(studyFile,JSON.stringify(study,null,2));
  await visible().locator('[data-engine-field=mass]').fill('777');assert(await page.evaluate(()=>state.modelDirty));
  await page.evaluate(study=>loadModelDefinition(new File([JSON.stringify(study)],'engine-roundtrip.wingfem.json',{type:'application/json'}),{recent:true,source:'snapshot'}),study);
  await page.waitForFunction(()=>!state.workspaceBusy&&!state.loadingInput&&!state.meshRequestInFlight,null,{timeout:240000});
  await page.evaluate(()=>createFEM({preserveView:true}));await page.locator('#tab-engines').click();
  assert.deepEqual(await page.evaluate(()=>collectParams()['engines.items']),entered);assert.equal(await page.evaluate(()=>state.data.engine_structure.engines[0].mass_kg),650);
  assert(await page.evaluate(()=>formSignature()===state.modelSignature));
  checks.push('Study save/reopen restores all engine values and regenerates a matching engine FEM; physical mass edits mark prior results stale');
  await visible().locator('[data-engine-field=enabled]').uncheck();await page.evaluate(()=>createFEM({preserveView:true}));
  assert.equal(await page.evaluate(()=>state.data.engine_structure.engines.length),0);assert.equal(await page.evaluate(()=>state.data.nodes.count),original.nodes);
  assert.equal(await page.evaluate(()=>state.deformable.filter(row=>row.engineBeam).length),0);assert.equal(await page.evaluate(()=>collectParams()['engines.items'][0].mass),650);
  checks.push('Disabling the engine removes its generated nodes and graphics without deleting the saved definition or changing the baseline wing mesh');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,rendering,connections,engine:record},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,errors,details:await page.evaluate(()=>({tab:workspaceUI.activeTab,modelError:document.getElementById('model-error-text')?.textContent}))},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
