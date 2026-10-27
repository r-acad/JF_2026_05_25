'use strict';
// node movable_te_rib_controls_browser_test.cjs URL OUTPUT PLAYWRIGHT
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const [url,out,modulePath='playwright']=process.argv.slice(2);
if(!url||!out)throw Error('Expected URL and output folder');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const {chromium}=require(modulePath),browser=await chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']}),page=await browser.newPage({viewport:{width:1900,height:1200}}),errors=[];
 page.on('pageerror',error=>errors.push(error.message));
 const ready=()=>page.waitForFunction(()=>state.data?.nodes?.count&&!state.meshRequestInFlight&&!state.workspaceBusy&&!state.loadingInput,null,{timeout:240000});
 try{
  await page.goto(url,{timeout:180000});await page.getByRole('button',{name:'Start new study',exact:true}).click();await ready();
  await page.evaluate(async()=>{
   document.getElementById('auto-save').checked=false;state.autosave?.destroy();document.getElementById('auto-mesh').checked=false;
   const parameters={...collectParams(),'planform.area':2,'planform.aspect_ratio':2,'planform.taper_ratio':1,'planform.sweep':0,'planform.dihedral':0,'planform.twist_tip':0,
    'airfoil.root':'NACA0012','airfoil.tip':'NACA0012','box.end_eta':1,'box.rib_pitch':.25,'box.stringer_pitch':.2,'mesh.elements_between_ribs':1,'mesh.elements_spar_height':2,'mesh.aero_chord_points':9,'airfoil.n_points':31,
    'loads.method':'analytic','loads.lift_total':1,'loads.structure_inertia':false,'fuel.enabled':false,'loads.cases':[],
    'movable_surfaces.items':[{name:'Flap',kind:'flap',edge:'trailing',eta_start:.05,eta_end:.95,front_spar_start:.78,front_spar_end:.78,hinge_start:.7,hinge_end:.7,hinge_z_start:0,hinge_z_end:0,deflection:0,color:'#ec751c'}],
    'movable_structure.surfaces':[{...WingMovableStructure.defaults,surface:'Flap',span_bays:4,span_elements:1,chord_elements:2,height_elements:2,rib_thickness:.0012,mesh_deflected:false}],
    'movable_structure.attachments':[.25,.75].map((eta,i)=>({...WingMovableStructure.attachmentDefaults,surface:'Flap',eta,fitting:'shell_lugs',actuator:true,lug_thickness:.003+i*.001,lateral_stay:true,box_lateral_stay:false,movable_lateral_stay:false}))};
   const response=await postParams('/api/validate_workspace',parameters),body=await response.json();if(!response.ok)throw Error(body.error);
   const study=await WingWorkspace.snapshot(body.parameters,state.reference,WingWorkspace.captureView(document,state,workspaceUI),{notes:state.studyNotes});
   if(!await loadModelDefinition(new File([JSON.stringify(study)],'te-rib-controls.wingfem.json',{type:'application/json'}),{recent:true}))throw Error('Fixture load failed');
  });
  await ready();await page.evaluate(()=>activateWorkspaceTab('movablestructure'));
  const group=page.locator('#group-movable-structures'),thickness=group.locator('[data-movable-structure-field=lug_thickness]');
  assert.equal(await thickness.count(),2);assert.equal(await group.getByText('TE rib thickness (m)',{exact:true}).count(),2);
  assert.equal(await group.locator('[data-movable-structure-field=lateral_stay]').count(),0);
  for(const key of ['box_lateral_stay','movable_lateral_stay']){assert.equal(await group.locator('[data-movable-structure-field='+key+']').count(),2);assert.equal(await group.locator('[data-movable-structure-field='+key+']').first().isChecked(),false);}
  await thickness.first().fill('0.005');await thickness.first().blur();
  await page.evaluate(async()=>{if(!await createFEM({preserveView:true}))throw Error('Fixture FEM generation failed');});await ready();
  const result=await page.evaluate(()=>{
   const a=state.data.movable_structure.attachments,p=collectParams(),groups=state.data.groups;
   return{attachments:a,parameters:p['movable_structure.attachments'],properties:groups.filter(g=>g.properties?.movable_part==='rib'||g.properties?.movable_part==='hinge lugs').map(g=>({pid:g.pid,...g.properties})),connections:(state.data.connections||[]).map(c=>c.name)};
  });
  assert(result.attachments.every(a=>!('lateral_links'in a)&&!('lateral_stay'in a)));
  assert(result.parameters.every(a=>!('lateral_stay'in a)));assert.equal(result.parameters[0].lug_thickness,.005);
  assert(!result.connections.some(name=>/LATERAL/i.test(name)));
  for(let i=0;i<result.attachments.length;i++){
   const a=result.attachments[i],expected=i===0?.005:.004;
   const triangle=result.properties.find(p=>p.pid===a.lug_pid),rib=result.properties.find(p=>p.pid===35001000+a.master_rib_index);
   assert.equal(triangle.thickness_m,expected);assert.equal(rib.thickness_m,expected);assert.equal(rib.thickness_source,'TE rib thickness');
  }
  assert(result.properties.filter(p=>p.movable_part==='rib'&&!p.attachment_rib).every(p=>p.thickness_m===.0012));
  await page.evaluate(()=>{applyBackgroundColor('#ffffff',false);fitView();});await thickness.first().scrollIntoViewIfNeeded();await page.screenshot({path:path.join(out,'te-rib-thickness.png')});
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'browser_summary.json'),JSON.stringify({passed:true,...result,errors},null,2));console.log(JSON.stringify({passed:true,attachments:result.attachments.length,properties:result.properties.length,errors}));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'browser_failure.json'),JSON.stringify({error:error.stack,errors,detail:await page.evaluate(()=>({modelError:document.querySelector('#model-error-text')?.textContent,log:document.querySelector('#log')?.textContent?.slice(-3000)}))},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
