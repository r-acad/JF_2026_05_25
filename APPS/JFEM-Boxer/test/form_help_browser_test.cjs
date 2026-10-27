'use strict';
// node form_help_browser_test.cjs URL OUTPUT PLAYWRIGHT
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const[url,out,modulePath='playwright']=process.argv.slice(2);fs.mkdirSync(out,{recursive:true});
(async()=>{
 const{chromium}=require(modulePath),browser=await chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']}),page=await browser.newPage({viewport:{width:1700,height:1100}}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(url,{timeout:180000});await page.waitForFunction(()=>typeof state!=='undefined'&&state.schema.length&&document.__boxerFormHelp,null,{timeout:120000});
  await page.waitForFunction(()=>document.querySelectorAll('.boxer-form-help-description').length>500);
  const initial=await page.evaluate(()=>document.__boxerFormHelp.audit());assert.deepEqual(initial.missing,[]);
  const dynamic=await page.evaluate(async()=>{
   const p={...state.values,'engines.items':[{...WingEngines.defaults}],
    'loft.thickness_stations':[{eta:0,tc:.12},{eta:1,tc:.1}],
    'loft.twist_stations':[{eta:0,twist:0},{eta:1,twist:-3}],
    'loft.vertical_shift_stations':[{eta:0,shift_percent:0},{eta:1,shift_percent:2}],
    'movable_surfaces.items':[{name:'Help audit flap',kind:'flap',edge:'trailing',eta_start:.2,eta_end:.8,front_spar_start:.78,front_spar_end:.78,hinge_start:.7,hinge_end:.7,hinge_z_start:0,hinge_z_end:0,deflection:15,color:'#ff8800'}],
    'movable_structure.surfaces':[{...WingMovableStructure.defaults,surface:'Help audit flap'}],
    'movable_structure.attachments':[{...WingMovableStructure.attachmentDefaults,surface:'Help audit flap',eta:.4}],
    'supports.sets':[{rib:1,target:'front_spar',dofs:'123'}]};
   document.getElementById('auto-mesh').checked=false;state.autoMeshReady=false;buildForm(state.schema,p);
   document.__boxerFormHelp.refresh();await new Promise(r=>setTimeout(r,900));return document.__boxerFormHelp.audit();
  });fs.writeFileSync(path.join(out,'dynamic_coverage.json'),JSON.stringify(dynamic,null,2));assert.deepEqual(dynamic.missing,[]);
  // A real field receives both native hover help and a persistent accessible
  // description; existing description tokens and author text are retained.
  await page.evaluate(()=>{
   for(const d of document.querySelectorAll('dialog[open]'))d.close();
   activateWorkspaceTab('planform');
   const input=document.getElementById('planform-dimension-root');input.closest('.planform-direct-fields')?.removeAttribute('hidden');
   const fixture=document.createElement('section');fixture.id='help-regression';fixture.style.cssText='position:fixed;left:480px;top:140px;z-index:20000;background:#fff;padding:20px;color:#123';
   fixture.innerHTML='<label>Poisson ratio<input id="help-repeat" aria-label="Poisson ratio" title="Poisson ratio"></label><span id="help-existing">Existing description.</span><label>Custom<input id="help-author" title="A carefully authored field explanation." aria-describedby="help-existing"></label><label>Density (kg/m³)<input id="help-added" aria-label="Density (kg/m³)"></label>';
   document.body.append(fixture);
  });
  await page.waitForFunction(()=>document.getElementById('help-added').getAttribute('aria-describedby'));
  assert.match(await page.locator('#help-repeat').getAttribute('title'),/transverse contraction/);
  assert.equal(await page.locator('#help-author').getAttribute('title'),'A carefully authored field explanation.');
  assert.match(await page.locator('#help-author').getAttribute('aria-describedby'),/help-existing/);
  await page.keyboard.press('Tab');await page.locator('#help-repeat').focus();
  await page.waitForFunction(()=>!document.querySelector('.boxer-form-help-tooltip').hidden);
  assert.match(await page.locator('.boxer-form-help-tooltip').innerText(),/transverse contraction/);
  await page.screenshot({path:path.join(out,'keyboard-help.png')});await page.keyboard.press('Escape');
  assert(await page.locator('.boxer-form-help-tooltip').evaluate(e=>e.hidden));
  await page.evaluate(()=>{document.getElementById('help-author').title='Updated disabled-state explanation.';document.getElementById('help-author').disabled=true;});
  await page.waitForFunction(()=>document.getElementById(document.getElementById('help-author').getAttribute('aria-describedby').split(' ').at(-1)).textContent==='Updated disabled-state explanation.');
  const stability=await page.evaluate(async()=>{
   const ids=[...document.querySelectorAll('.boxer-form-help-description')].map(e=>e.id),icons=document.querySelectorAll('.help-icon').length;
   for(let i=0;i<5;i++)document.__boxerFormHelp.refresh();await new Promise(r=>setTimeout(r,600));
   const result={unique:new Set(ids).size===ids.length,duplicateDescriptions:[...document.querySelectorAll('input,select,textarea')].some(e=>(e.getAttribute('aria-describedby')||'').split(' ').filter(id=>id.startsWith('boxer-field-help-')).length>1),iconsUnchanged:document.querySelectorAll('.help-icon').length===icons};
   const removedIds=[...document.getElementById('help-regression').querySelectorAll('.boxer-form-help-description')].map(e=>e.id);document.getElementById('help-regression').remove();await new Promise(r=>setTimeout(r,300));result.detachedDescriptionsCleaned=removedIds.every(id=>!document.getElementById(id));return result;
  });assert(stability.unique&&stability.iconsUnchanged&&stability.detachedDescriptionsCleaned&&!stability.duplicateDescriptions);
  const lateEditors=await page.evaluate(async()=>{
   const host=document.createElement('section');document.body.append(host);
   const editor=WingMaterialAllowables.editor({document,host,readMaterials:()=>[{id:8,type:'MAT8',name:'Orthotropic test',E1_Pa:130e9,E2_Pa:10e9,nu12:.3}],readRows:()=>[{material_id:8,mode:'strain',strain_tension:.005,strain_compression:.004}],onChange(){},showDefinition:true});
   document.__boxerFormHelp.refresh(host);await new Promise(r=>setTimeout(r,250));const laminate=document.__boxerFormHelp.audit(host);editor.destroy();host.remove();
   const results=[];
   for(const kind of ['skins','stringers']){
    const values=kind==='skins'?{thickness:.002,kind:'sandwich',material:1,face_material:1,core_material:3,face_thickness:.0005,core_thickness:.01}:{flange_width:.03,height:.04,flange_thickness:.002,web_thickness:.002,material:1};
    const descriptor={editable:true,pid:5000001,kind,key:'test',label:'Help coverage property',note:'Local property help fixture',parameter:'properties.panels',values,inherited:{...values},explicit:{},minimums:[],materialChoices:[{id:1,name:'Face alloy'},{id:3,name:'Core material'}],fields:WingPanelTableData.FIELDS[kind]};
    const api=WingRFPropertyEditor.open({document,descriptor,onApply(){}});document.__boxerFormHelp.refresh(api.element);await new Promise(r=>setTimeout(r,250));results.push({kind,...document.__boxerFormHelp.audit(api.element)});api.close();
   }
   return{laminate,properties:results};
  });assert.deepEqual(lateEditors.laminate.missing,[]);for(const check of lateEditors.properties)assert.deepEqual(check.missing,[]);
  assert.deepEqual(errors,[]);const result={passed:true,initial,dynamic,stability,lateEditors,errors};fs.writeFileSync(path.join(out,'browser_summary.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));
 }catch(error){fs.writeFileSync(path.join(out,'browser_failure.json'),JSON.stringify({error:error.stack,errors},null,2));throw error;}finally{await browser.close();}
})();
