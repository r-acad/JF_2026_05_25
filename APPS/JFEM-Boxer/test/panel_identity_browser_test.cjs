'use strict';
// node panel_identity_browser_test.cjs <url> <out> <playwright> <identity-fixture.json> [study.json]
// identity-fixture.json contains a panel key and legacy/current tokens for the server input.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [url,out,modulePath,fixtureFile,studyFile]=process.argv.slice(2),{chromium}=require(modulePath);
const fixture=JSON.parse(fs.readFileSync(fixtureFile,'utf8'));
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[];
 const browser=await chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']});
 const page=await browser.newPage({viewport:{width:1600,height:1100}});page.setDefaultTimeout(240000);page.on('pageerror',e=>errors.push(e.message));
 const settled=()=>page.waitForFunction(()=>state.data?.nodes?.count&&!state.workspaceBusy&&!state.meshRequestInFlight,null,{timeout:240000});
 const rows=()=>page.evaluate(()=>JSON.parse(document.getElementById('p-properties.panels').value));
 const edit=values=>page.evaluate(values=>{for(const [key,value] of Object.entries(values)){document.getElementById('p-'+key).value=typeof value==='object'?JSON.stringify(value):String(value);parameterEdited(key);}},values);
 const build=()=>page.evaluate(()=>createFEM({preserveView:true}));
 const synchronized=async()=>assert(await page.evaluate(()=>!state.modelDirty&&state.modelSignature===formSignature()&&JSON.stringify(state.values['properties.panels'])===JSON.stringify(state.data.model_params['properties.panels'])), 'form, table rows and generated model are synchronized');
 try{
  await page.goto(url,{waitUntil:'domcontentloaded'});await page.getByRole('button',{name:'Start new study',exact:true}).waitFor();
  await page.evaluate(()=>{state.defaults=JSON.parse(JSON.stringify(state.values));});
  await page.getByRole('button',{name:'Start new study',exact:true}).click();await settled();await page.locator('#auto-mesh').uncheck();
  const initial=await page.evaluate(()=>({token:state.data.stiffened_panels.layout_token,thickness:state.values['properties.skin_upper']}));
  assert.equal(initial.token,fixture.current);
  const override={key:fixture.key,layout_token:fixture.legacy,skin:{thickness:.004}};
  await edit({'properties.panels':[override],'planform.twist_tip':.1});assert.equal(await build(),true);await synchronized();
  assert.deepEqual(await rows(),[{...override,layout_token:fixture.current}]);checks.push('Live legacy override is authenticated against the previous model and canonical token reaches the form, model and future Study saves.');
  await edit({'planform.twist_tip':.2});assert.equal(await build(),true);await synchronized();assert.equal((await rows())[0].skin.thickness,.004);
  checks.push('A second geometry edit builds successfully and retains the edited panel thickness.');
  await edit({'mesh.elements_between_ribs':4,'mesh.elements_between_stringers':2});assert.equal(await build(),true);await synchronized();assert.equal((await rows())[0].layout_token,fixture.current);
  checks.push('Changing both mesh refinements retains physical panel identity and properties.');
  const saved=await page.evaluate(async()=>WingWorkspace.snapshot(collectParams(),state.reference,WingWorkspace.captureView(document,state,workspaceUI),{notes:state.studyNotes}));
  assert.equal(saved.parameters['properties.panels'][0].layout_token,fixture.current);fs.writeFileSync(path.join(out,'panel_identity_saved.wingfem.json'),JSON.stringify(saved,null,2));
  checks.push('Portable Study saves the upgraded identity.');
  await edit({'box.rib_pitch':.25});assert.equal(await build(),false);assert.deepEqual(await rows(),[{...override,layout_token:fixture.current}]);
  checks.push('Changing the physical rib layout is rejected without erasing panel overrides.');
  if(studyFile){
   const text=fs.readFileSync(studyFile,'utf8'),original=JSON.parse(text).parameters['properties.panels'];
   assert.equal(await page.evaluate(text=>loadModelDefinition(new File([text],'existing-study.wingfem.json',{type:'application/json'})),text),true);await settled();await page.locator('#auto-mesh').uncheck();await synchronized();
   const withoutToken=rows=>rows.map(({layout_token,...rest})=>rest).sort((a,b)=>a.key.localeCompare(b.key)),loaded=await rows();assert.deepEqual(withoutToken(loaded),withoutToken(original));assert(loaded.every(row=>row.layout_token!==original[0].layout_token));
   checks.push(`Existing saved study loads with all ${original.length} overrides preserved and authenticated legacy identity migrated.`);
   const twist=await page.evaluate(()=>Number(document.getElementById('p-planform.twist_tip').value));await edit({'planform.twist_tip':twist+.01});assert.equal(await build(),true);await synchronized();assert.deepEqual(await rows(),loaded);
   checks.push('The actual saved-study model rebuilds after a small twist change, retaining every panel material and dimension.');
   await page.evaluate(()=>fitView());await page.waitForTimeout(300);
   await page.screenshot({path:path.join(out,'panel_identity_existing_study.png')});
  }
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'panel_identity_browser.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(e){await page.screenshot({path:path.join(out,'panel_identity_error.png')});fs.writeFileSync(path.join(out,'panel_identity_error.json'),JSON.stringify({error:e.stack,checks,errors},null,2));throw e;}
 finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
