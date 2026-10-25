'use strict';
// node movable_forms_browser_test.cjs OUTPUT PLAYWRIGHT
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const [out,modulePath='playwright']=process.argv.slice(2),web=path.resolve(__dirname,'../web');
if(!out)throw Error('Expected output folder');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const {chromium}=require(modulePath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined}),page=await browser.newPage({viewport:{width:1800,height:1100}}),errors=[],checks=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.setContent('<html><body><div id="canonical" hidden></div><main id="structure"></main><div id="app" class="drawing-maximized"><section id="group-movable-surfaces" class="parameter-section"></section></div></body></html>');
  for(const file of ['style.css','movable_surfaces.css','svg_viewport.css'])await page.addStyleTag({path:path.join(web,file)});
  await page.addStyleTag({content:'body{display:block;overflow:auto;background:#14202c;color:#dceafa;font:14px system-ui;margin:12px}#structure{width:390px;padding:14px;border:1px solid #426078}#app{display:block;height:950px}#group-movable-surfaces{height:950px}'});
  for(const file of ['svg_viewport.js','planform_view.js','spar_view.js','movable_surfaces.js','movable_structure.js'])await page.addScriptTag({path:path.join(web,file)});
  await page.evaluate(()=>{
   window.edits=[];window.locked=false;
   window.geometry=[{name:'Flap',kind:'flap',edge:'trailing',eta_start:.1,eta_end:.5,hinge_start:.7,hinge_end:.7,front_spar_start:.75,front_spar_end:.75,deflection:0,color:'#29b6d1'},{name:'Aileron',kind:'aileron',edge:'trailing',eta_start:.6,eta_end:.95,hinge_start:.7,hinge_end:.75,front_spar_start:.8,front_spar_end:.8,deflection:0,color:'#f5a742'}];
   window.ribs=[{index:1,eta:0},{index:2,eta:.1},{index:3,eta:.3},{index:4,eta:.5},{index:5,eta:.7},{index:6,eta:.9},{index:7,eta:1}];
   const values={'movable_surfaces.items':geometry,'movable_structure.surfaces':geometry.map(s=>({...WingMovableStructure.defaults,surface:s.name})),'movable_structure.attachments':[{...WingMovableStructure.attachmentDefaults,surface:'Flap',eta:.17,rib:99},{...WingMovableStructure.attachmentDefaults,surface:'Aileron',eta:.72,rib:77}]};
   for(const[key,value]of Object.entries(values)){const e=document.createElement('input');e.id='p-'+key;e.value=JSON.stringify(value);document.querySelector('#canonical').append(e);}
   window.installStructure=()=>WingMovableStructure.install(document.getElementById('structure'),{readGeometry:()=>geometry,readRibs:()=>ribs,readMaterials:()=>[{id:1,name:'Aluminium'}],onEdit:key=>edits.push(key),isLocked:()=>locked});
   window.editor=installStructure();window.initial=editor.readDrafts();
  });
  const picker=page.locator('#movable-structure-edit'),visible=()=>page.locator('.movable-structure:not([hidden])');
  assert.equal(await picker.locator('option').count(),2);assert.equal(await visible().count(),1);
  assert.equal(await visible().locator('legend').first().textContent(),'Flap');
  assert.equal(await visible().locator('.movable-rib-select').inputValue(),'2');
  await picker.selectOption('1');assert.equal(await visible().locator('legend').first().textContent(),'Aileron');
  assert.deepEqual(await page.evaluate(()=>editor.readDrafts()),await page.evaluate(()=>initial));assert.equal(await page.evaluate(()=>edits.length),0);
  await page.evaluate(()=>{window.savedRibs=ribs;ribs=[];editor.refresh();});assert.equal(await visible().locator('.movable-rib-select').textContent(),'Pending FEM');assert.deepEqual(await page.evaluate(()=>editor.readDrafts()),await page.evaluate(()=>initial));await page.evaluate(()=>{ribs=savedRibs;editor.refresh();});
  checks.push('Only the selected structure is visible; switching preserves all legacy values without dirtying the Study');
  await visible().locator('[data-movable-structure-field=upper_thickness]').fill('.004');
  await picker.selectOption('0');await visible().locator('[data-movable-structure-field=lower_thickness]').fill('.003');
  let d=await page.evaluate(()=>editor.readDrafts());assert.equal(d['movable_structure.surfaces'][0].lower_thickness,.003);assert.equal(d['movable_structure.surfaces'][1].upper_thickness,.004);
  const eta=visible().locator('[data-movable-structure-field=eta]');await visible().locator('.movable-rib-select').selectOption('4');assert.equal(await eta.inputValue(),'0.5');await eta.fill('.4');await eta.dispatchEvent('change');
  assert.equal(await eta.inputValue(),'0.3');assert.equal(await visible().locator('.movable-rib-select').inputValue(),'3');
  assert.match(await visible().locator('.movable-snap-note').textContent(),/line of flight/);
  d=await page.evaluate(()=>editor.readDrafts());assert.equal(d['movable_structure.attachments'][0].eta,.3);assert.equal(d['movable_structure.attachments'][0].rib,3);
  const bearing=visible().locator('.movable-bearing').first();await bearing.locator('[data-movable-structure-field=fitting]').selectOption('shell_lugs');await bearing.locator('[data-movable-structure-field=actuator]').check();
  assert(await bearing.locator('[data-movable-structure-field=hinge_stiffness]').isHidden());assert(await bearing.locator('[data-movable-structure-field=actuator_stiffness]').isVisible());assert.equal(await bearing.locator('[data-movable-structure-field=actuator_stiffness]').inputValue(),'10000000');
  await bearing.locator('[data-movable-structure-field=actuator_stiffness]').fill('25000000');await visible().locator('[data-movable-structure-field=max_rib_pitch_ratio]').fill('1.25');await bearing.locator('[data-movable-structure-field=actuator]').uncheck();assert(await bearing.locator('[data-movable-structure-field=actuator_stiffness]').isHidden());await bearing.locator('[data-movable-structure-field=actuator]').check();
  d=await page.evaluate(()=>editor.readDrafts());assert.equal(d['movable_structure.attachments'][0].actuator_stiffness,25000000);assert.equal(d['movable_structure.surfaces'][0].max_rib_pitch_ratio,1.25);checks.push('Physical actuator shows axial N/m stiffness separately from legacy hinge torsion; pitch ratio and stiffness persist across toggle changes');
  await visible().getByRole('button',{name:'+ Add attachment',exact:true}).click();
  d=await page.evaluate(()=>editor.readDrafts());const flap=d['movable_structure.attachments'].filter(a=>a.surface==='Flap');assert.equal(new Set(flap.map(a=>a.rib)).size,2);
  await picker.selectOption('1');assert.match(await visible().locator('.movable-snap-note').textContent(),/perpendicular to the true hinge/);
  checks.push('Independent edits persist; direct rib and eta selection agree; eta commits to nearest eligible rib with inboard tie; added attachments avoid occupied ribs');
  await page.evaluate(()=>{locked=true;document.querySelector('#structure').dispatchEvent(new Event('parameterlockchange'));});
  assert(await visible().locator('[data-movable-structure-field=upper_thickness]').isDisabled());assert(!(await picker.isDisabled()));await picker.selectOption('0');
  await page.evaluate(()=>{locked=false;document.querySelector('#structure').dispatchEvent(new Event('parameterlockchange'));});
  await page.locator('#structure').screenshot({path:path.join(out,'structure-picker.png')});
  const saved=await page.evaluate(()=>editor.readDrafts());
  await page.evaluate(saved=>{editor.destroy();document.querySelector('#structure').replaceChildren();for(const[key,value]of Object.entries(saved))document.getElementById('p-'+key).value=JSON.stringify(value);window.editor=installStructure();},saved);
  assert.deepEqual(await page.evaluate(()=>editor.readDrafts()),saved);checks.push('Locked structures remain browsable; serialized editor drafts reload without losing hidden structures or attachments');
  await page.evaluate(()=>{
   window.geomEditor=WingMovableSurfaces.install(document.querySelector('#group-movable-surfaces'),{readValues:()=>({}),onEdit:key=>edits.push(key),requestPreview:async()=>({outline:[[0,0],[0,10],[2,10],[4,0]],surfaces:[]})});
   const group=document.querySelector('#group-movable-surfaces'),drawing=group.querySelector('.movable-preview'),bench=document.createElement('div'),stage=document.createElement('div'),parameters=document.createElement('div');bench.className='drawing-workbench';stage.className='drawing-stage';parameters.className='drawing-parameters';stage.append(drawing);for(const child of Array.from(group.children))parameters.append(child);bench.append(stage,parameters);group.append(bench);
  });
  assert.equal(await page.locator('#group-movable-surfaces .movable-surface:not([hidden])').count(),1);const oldGeometry=await page.evaluate(()=>geomEditor.readDrafts()),editCount=await page.evaluate(()=>edits.length);await page.locator('#movable-surface-edit').selectOption('1');await page.locator('#movable-surface-edit').selectOption('0');assert.deepEqual(await page.evaluate(()=>geomEditor.readDrafts()),oldGeometry);assert.equal(await page.evaluate(()=>edits.length),editCount);
  const first=page.locator('#group-movable-surfaces .movable-surface').first();await first.locator('[data-movable-field=hinge_z_start]').fill('-2');await first.locator('[data-movable-field=hinge_z_end]').fill('.5');
  assert.equal(await first.locator('[data-movable-field=hinge_z_start]').evaluate(e=>e.validity.valid),true);
  assert.equal(await page.evaluate(()=>geomEditor.readDrafts()['movable_surfaces.items'][0].hinge_z_start),-2);assert.equal(await page.evaluate(()=>geomEditor.readDrafts()['movable_surfaces.items'][0].hinge_z_end),.5);
  await page.waitForFunction(()=>document.querySelector('#movable-plan-view polygon'));
  const box=await page.locator('#movable-plan-view').boundingBox(),stage=await page.locator('#group-movable-surfaces .drawing-stage').boundingBox(),parameters=await page.locator('#group-movable-surfaces .drawing-parameters').boundingBox();
  assert(box.height>600,JSON.stringify(box));assert(box.width>1000);assert(parameters.x>=stage.x+stage.width-1);assert.equal(await page.locator('#group-movable-surfaces .drawing-parameters').evaluate(e=>getComputedStyle(e).overflowY),'auto');
  await page.locator('#app').screenshot({path:path.join(out,'movable-maximized.png')});
  await page.evaluate(()=>document.querySelector('#app').classList.remove('drawing-maximized'));assert((await page.locator('#movable-plan-view').boundingBox()).height<=481);
  checks.push('Geometry dropdown preserves every hidden surface; signed hinge z/t inputs accept -2 and +0.5; maximized plan fills the drawing stage beside independently scrolling controls; Restore returns compact height');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,maximizedPlan:box},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(e){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,errors},null,2));throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
