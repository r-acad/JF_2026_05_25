'use strict';
// Live Boxer backend; synthetic membrane resultants provide exact RF UI oracles.
// node workflow_cleanup_browser_test.cjs URL OUTPUT PLAYWRIGHT_MODULE
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [url,out,modulePath='playwright']=process.argv.slice(2),{chromium}=require(modulePath);
fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1750,height:1100}}),errors=[],requests=[],checks=[];
 page.setDefaultTimeout(45000);page.on('pageerror',e=>errors.push(e.stack));page.on('response',async r=>{if(r.url().endsWith('/api/rf_sections')){const body=r.request().postDataJSON();fs.writeFileSync(path.join(out,'section-request.json'),JSON.stringify(body,null,2));if(!r.ok())console.log('Changed keys',Object.keys(body.parameters).filter(k=>JSON.stringify(body.parameters[k])!==JSON.stringify(body.baseline[k])).map(k=>[k,body.baseline[k],body.parameters[k]]));}});page.on('request',r=>{if(r.method()==='POST')requests.push(new URL(r.url()).pathname);});
 const ready=async()=>{await page.waitForFunction(()=>!state.workspaceBusy&&!state.loadingInput,null,{timeout:180000});if(!await page.evaluate(()=>!!state.data?.nodes?.count))await page.locator('#btn-create').click();await page.waitForFunction(()=>state.data?.nodes?.count&&!state.meshRequestInFlight&&!state.workspaceBusy&&!state.loadingInput,null,{timeout:180000});};
 await page.route('**/api/input',async route=>{
  const response=await route.fetch(),schema=await response.json();
  Object.assign(schema.defaults,{'planform.area':2,'planform.aspect_ratio':2,'planform.taper_ratio':1,'planform.sweep':0,'planform.dihedral':0,'planform.twist_tip':0,
   'airfoil.root':'NACA0012','airfoil.tip':'NACA0012','airfoil.n_points':21,'box.rib_pitch':.25,'box.stringer_pitch':.08,
   'mesh.elements_between_ribs':2,'mesh.elements_between_stringers':1,'mesh.elements_spar_height':2,'mesh.aero_chord_points':9,
   'fuel.enabled':false,'leading_edge.enabled':false,'loads.structure_inertia':false,'loads.cases':[],'output.solution':'101'});
  await route.fulfill({json:schema});
 });
 try{
  await page.goto(url);await page.getByRole('button',{name:'Start new study',exact:true}).click();await ready();
  await page.evaluate(()=>{document.getElementById('auto-save').checked=false;state.autosave?.destroy();state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();});
  // Build genuine movable-structure actuators, then replace the entire Study.
  await page.evaluate(()=>activateWorkspaceTab('movablesurfaces'));await page.locator('#movable-add').click();
  await page.locator('[data-movable-field=name]').fill('Cleanup actuator test');
  for(const field of ['hinge_z_start','hinge_z_end'])await page.locator('[data-movable-field='+field+']').fill('-0.8');
  await page.evaluate(()=>activateWorkspaceTab('movablestructure'));await page.locator('#movable-structure-add').click();
  await page.locator('#btn-create').click();await ready();
  const before=await page.evaluate(()=>({actuators:state.scene.meshes.filter(m=>m.actuatorCylinder).length,connections:state.data.imported_connections.map(c=>c.name)}));
  assert(before.actuators>0,'The loaded Study must contain real actuator cylinders');
  assert(await page.evaluate(()=>state.scene.meshes.filter(m=>m.actuatorCylinder).every(m=>state.layers.get('MOVABLE_HINGES')?.meshes.includes(m))),'Actuators must remain owned by their FE layer when the movable preview is rebuilt');
  await page.evaluate(()=>newStudy());await ready();
  assert.deepEqual(await page.evaluate(()=>({actuators:state.scene.meshes.filter(m=>m.actuatorCylinder).length,connections:state.data.imported_connections?.length||0,results:state.resultCases?.size||0,tab:workspaceUI.activeTab,selection:state.selectedElement})),{actuators:0,connections:0,results:0,tab:'planform',selection:null});
  checks.push('New Study removes real actuator meshes, old connections, results and selection and restores the fresh planform view.');
  await page.screenshot({path:path.join(out,'new-study-clean.png')});
  await page.evaluate(()=>{
   const masters=[.3,.6].map(eta=>({eta,mode:'flight_direction',angle:90,pitch:.25}));document.getElementById('p-ribs.masters').value=JSON.stringify(masters);state.ribEditor.refresh();parameterEdited('ribs.masters');
   const ref=document.getElementById('p-box.stringer_angle_reference');ref.value='global_y';parameterEdited('box.stringer_angle_reference');activateWorkspaceTab('stringerlayout');
  });
  assert.equal(await page.locator('input[data-master-segment]').count(),3);
  assert.match(await page.locator('[id="p-box.stringer_angle_reference"] option:checked').textContent(),/Angle from Y axis/);
  for(const [i,a]of [3,-2,5].entries()){await page.locator('[data-master-segment="'+i+'"]').fill(String(a));await page.locator('[data-master-segment="'+i+'"]').dispatchEvent('change');}
  const angles=await page.evaluate(()=>({values:collectParams()['box.stringer_segment_angles'],directions:state.stringerLayout.data().geometry.stringerSegments.filter(s=>s.active).map(s=>s.absoluteAngle)}));
  assert.deepEqual(angles.values,[3,-2,5]);assert.deepEqual(angles.directions,[3,-2,5]);
  checks.push('Angle from Y axis exposes and previews an independent angle for each master-rib interval.');
  await page.screenshot({path:path.join(out,'master-segment-angles.png')});
  await page.locator('#btn-create').click();await ready();
  assert.deepEqual(await page.evaluate(()=>state.data.stringer_path.angles_deg.filter((a,i)=>state.data.stringer_path.station_etas[i]<state.values['box.end_eta'])),[3,-2,5]);
  await page.evaluate(()=>{activateWorkspaceTab('box');setWorkspaceMaximized('box');document.querySelector('#group-torsion-box .svgv-image-options').open=true;});
  const widths=await page.locator('#group-torsion-box .svgv-image-options button').evaluateAll(nodes=>nodes.map(n=>({text:n.textContent,width:n.getBoundingClientRect().width,parent:n.parentElement.getBoundingClientRect().width})));
  for(const row of widths.filter(r=>['Original ratio','Reset alignment','Remove image'].includes(r.text)))assert(row.width<200&&row.width<row.parent*.8,JSON.stringify(row));
  checks.push('Maximized spar drawing keeps the three background-image action buttons at content width.');
  await page.screenshot({path:path.join(out,'spar-image-buttons.png')});
  await page.evaluate(()=>newStudy());await ready();
  const baseline=await page.evaluate(()=>{
   const records={};for(const[eid,e]of state.elements){const t=e.group.properties?.thickness_m||.002,stress=600e6;
    records[eid]=e.group.kind==='bar'?{stress:{axial:stress,von_mises:stress},stress_units:'Pa',forces:{axial:stress*(e.group.properties?.section?.area_m2||.0001),moment_a1:0,moment_a2:0,moment_b1:0,moment_b2:0,shear_1:0,shear_2:0,torque:0}}:
     {stress:{z1:{normal_x:stress,normal_y:0,shear_xy:0,von_mises:stress,fiber_dist:-t/2},z2:{normal_x:stress,normal_y:0,shear_xy:0,von_mises:stress,fiber_dist:t/2}},stress_units:'Pa',forces:{fx:stress*t,fy:0,fxy:0,mx:0,my:0,mxy:0,qx:0,qy:0}};
   }
   state.data.load_cases=[{id:1,label:'Exact fixed membrane UI oracle',solution:101}];state.loadCases=[];state.modelSignature=formSignature();
   const result={analysis:'SOL101',available:true,status:'complete',matches:true,modes:[],contours:[],summary:[],static:{disp:new Float32Array(state.nodeIds.length*3),maxDisp:0},signature:state.modelSignature,meshIdentity:state.meshIdentity,elementResults:records};
   state.resultCases=new Map([[1,result]]);setModelDirty(false);window.originalSizingModel=state.data;window.originalSizingResult=result;window.originalSizingForces=JSON.stringify(records);
   const e=[...state.elements.values()].find(e=>e.group.name.startsWith('UPPER_SKIN')&&e.group.kind==='quad');
   window.rfActivitySeen=[];new MutationObserver(()=>{const n=document.getElementById('activity-status');if(!n.hidden&&/reserve factors/i.test(n.textContent))rfActivitySeen.push(n.textContent);}).observe(document.getElementById('activity-status'),{subtree:true,childList:true,attributes:true});
   activateWorkspaceTab('stressreport');return{pid:e.group.pid,eid:e.id,thickness:state.values['properties.t_skin_upper'],meshIdentity:state.meshIdentity};
  });
  await page.waitForFunction(()=>state.stressReport?.report&&!state.stressReport.pending);
  assert(await page.evaluate(()=>rfActivitySeen.length>0),'RF calculation must display an explanatory activity message');
  await page.locator('#stress-report-field-kind').selectOption('rf:von_mises');await page.locator('#stress-report-show-field').click();
  await page.waitForFunction(()=>state.rfField?.contour.available>0);
  const originalColor=await page.evaluate(eid=>state.rfField.contour.colorById.get(eid),baseline.eid),generateBefore=requests.filter(p=>p==='/api/generate').length;
  for(const factor of [1.5,3]){
   await page.evaluate(({thickness,factor})=>{const input=document.getElementById('p-properties.t_skin_upper');input.value=String(thickness*factor);parameterEdited('properties.t_skin_upper');}, {...baseline,factor});
   await page.waitForFunction(({pid,expected})=>state.stressReport?.report?.estimated&&!state.stressReport.pending&&Math.abs(state.stressReport.report.rows.find(r=>r.pid===pid)?.reserveFactor-expected)<1e-8,{pid:baseline.pid,expected:.5*factor});
   await page.waitForFunction(({eid,expected})=>state.rfField?.contour.estimated&&Math.abs(state.rfField.contour.byId.get(eid)-expected)<1e-8,{eid:baseline.eid,expected:.5*factor});
   const rendered=await page.evaluate(eid=>{const c=rawContourValues(),m=state.shellMeshes.find(m=>Array.from(m.elementIds).includes(eid)),i=Array.from(m.elementIds).indexOf(eid),rgb=m.getVerticesData(BABYLON.VertexBuffer.ColorKind);return{stale:c.stale,expected:c.colorById.get(eid),actual:Array.from(rgb.slice(i*m.nodesPerElement*4,i*m.nodesPerElement*4+3))};},baseline.eid);
   assert(!rendered.stale,'A certified fixed-load estimate must reach the actual rendered contour');rendered.expected.forEach((v,i)=>assert(Math.abs(v-rendered.actual[i])<1e-6,'Rendered vertex color must match the estimated RF'));
   assert.deepEqual(await page.evaluate(meshIdentity=>({sameModel:state.data===originalSizingModel,sameResult:state.resultCases.get(1)===originalSizingResult,sameForces:JSON.stringify(originalSizingResult.elementResults)===originalSizingForces,sameMesh:state.meshIdentity===meshIdentity,dirty:state.modelDirty,pending:state.autoMeshPending}),baseline.meshIdentity),{sameModel:true,sameResult:true,sameForces:true,sameMesh:true,dirty:true,pending:false});
  }
  assert.equal(requests.filter(p=>p==='/api/generate').length,generateBefore,'Sizing edits must not remesh');
  assert.notDeepEqual(await page.evaluate(eid=>state.rfField.contour.colorById.get(eid),baseline.eid),originalColor);
  assert(await page.locator('#stress-report-stale').isVisible());
  checks.push('Repeated property edits update RF 0.5 -> 0.75 -> 1.5 and field colors at unchanged internal loads, without remeshing or replacing source results; out-of-sync warning remains visible.');
  checks.push('First RF calculation paints an explanatory progress message before evaluating checks.');
  await page.screenshot({path:path.join(out,'fixed-load-sizing.png')});
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,requests,widths},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,errors,requests,diagnostics:await page.evaluate(()=>({meshStatus:document.getElementById('mesh-status')?.textContent,modelDirty:state.modelDirty,rfUpdate:!!state.rfSectionUpdate,pending:state.stressReport?.pending,report:state.stressReport?.report?{estimated:state.stressReport.report.estimated,stale:state.stressReport.report.stale,note:state.stressReport.report.note,rows:state.stressReport.report.rows.map(r=>({pid:r.pid,rf:r.reserveFactor}))}:null})).catch(()=>null)},null,2));throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
