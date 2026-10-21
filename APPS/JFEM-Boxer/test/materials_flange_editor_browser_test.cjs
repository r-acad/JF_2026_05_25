"use strict";
// node test/materials_flange_editor_browser_test.cjs <evidence-dir> <playwright-module>
const assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path");
const {chromium}=require(process.argv[3]),web=path.resolve(__dirname,"../web"),out=path.resolve(process.argv[2]);
fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
 const page=await browser.newPage({viewport:{width:1150,height:1050}}),errors=[],checks=[];page.on("pageerror",error=>errors.push(error.stack));
 try{
  await page.setContent('<!doctype html><main id="group-materials"></main><main id="group-beam-sections"></main>');
  for(const file of ["style.css","materials_editor.css"])if(fs.existsSync(path.join(web,file)))await page.addStyleTag({path:path.join(web,file)});
  await page.addStyleTag({content:'body{background:#101c29;color:#dfebf5;font:15px system-ui;overflow:auto;margin:16px}main{max-width:720px;padding:12px}.row{display:flex;gap:18px;padding:5px}input,select,button{font:inherit;background:#20364c;color:inherit;padding:5px}[hidden]{display:none!important}.material-cross-section{height:140px;width:420px}'});
  for(const file of ['reference_import.js','svg_viewport.js','workspace.js','materials_editor.js'])await page.addScriptTag({path:path.join(web,file)});
  await page.evaluate(()=>{
   const params={"materials.library":[{id:2,name:"Steel",E:210e9,nu:.3,rho:7850},{id:3,name:"Core",E:1e8,nu:.3,rho:80},{id:4,name:"Titanium",E:110e9,nu:.3,rho:4500}],"materials.shells":[],"materials.bars":[{component:"stringer",material:2}],"properties.panels":[{key:"upper:bay1:stringer1:segment1",layout_token:"fixture",stringer:{material:4}}],"material.name":"Aluminium","stringers.model":"beam","properties.stringer_flange_width":.03,"properties.stringer_flange_thickness":.002,"properties.t_skin_upper":.003,"properties.t_skin_lower":.002,"properties.t_spar_web":.003,"properties.t_rib_web":.002,"leading_edge.t_skin":.002,"leading_edge.t_rib":.002};
   for(const[key,value]of Object.entries(params)){const row=document.createElement('label');row.className='row';row.id='row-'+key;row.append(key);const input=document.createElement('input');input.id='p-'+key;input.value=Array.isArray(value)?JSON.stringify(value):String(value);row.append(input);document.getElementById(key.startsWith('properties.stringer')?'group-beam-sections':'group-materials').append(row);}
   window.edits=[];window.install=()=>window.editor=WingMaterialsEditor.install({onEdit:key=>edits.push(key)});install();
   window.setParam=(key,value)=>{const input=document.getElementById('p-'+key);input.value=typeof value==='object'?JSON.stringify(value):String(value);input.dispatchEvent(new Event('input',{bubbles:true}));};
   window.flange=()=>editor.readDrafts()['materials.shells'].find(row=>row.component==='stringer_flange');
  });
  const card=page.locator('#stringer-flange-material'),inherit=page.locator('#stringer-flange-inherit-material'),construction=page.getByLabel('Attached flange construction',{exact:true}),material=page.getByLabel('Attached flange material',{exact:true});
  assert(await card.isHidden());assert.equal(await page.evaluate(()=>flange()),undefined);
  await page.evaluate(()=>setParam('material.name','Aluminium edited'));assert.equal(await page.evaluate(()=>flange()),undefined);
  await page.evaluate(()=>setParam('stringers.model','shell'));assert(await card.isVisible());assert(await inherit.isChecked());assert(await material.isDisabled());assert.equal(await material.inputValue(),'2');assert.equal(await page.evaluate(()=>flange()),undefined);
  const beforePanels=await page.evaluate(()=>document.getElementById('p-properties.panels').value);
  await page.getByLabel('Stringers material',{exact:true}).selectOption('4');assert.equal(await material.inputValue(),'4');assert.equal(await page.evaluate(()=>flange()),undefined);assert.equal(await page.evaluate(()=>document.getElementById('p-properties.panels').value),beforePanels);
  checks.push('Inherited flange follows the default stringer material without writing an assignment; individual panel material overrides are preserved');
  await inherit.uncheck();assert(!(await material.isDisabled()));assert.equal((await page.evaluate(()=>flange())).material,4);
  await material.selectOption('2');assert.equal((await page.evaluate(()=>flange())).material,2);
  await construction.selectOption('sandwich');await page.getByLabel('Attached flange face material',{exact:true}).selectOption('4');await page.getByLabel('Attached flange core material',{exact:true}).selectOption('3');
  let draft=await page.evaluate(()=>flange());assert.equal(draft.face_thickness,.0005);assert.equal(draft.core_thickness,.001);assert.equal(draft.face_material,4);assert.equal(draft.core_material,3);
  const core=page.getByLabel('Attached flange remaining core (mm)',{exact:true});assert(await core.evaluate(input=>input.readOnly));assert.equal(await core.inputValue(),'1');
  assert(await page.locator('[id="row-properties.stringer_flange_thickness"]').isVisible());
  await page.evaluate(()=>setParam('properties.stringer_flange_thickness',.003));assert.equal((await page.evaluate(()=>flange())).core_thickness,.002);assert.equal(await core.inputValue(),'2');
  checks.push('Independent monolithic and sandwich assignments persist; the flange total stays editable and the sandwich core is derived from total minus two faces');
  await page.getByLabel('Attached flange minimum face thickness (mm)',{exact:true}).fill('1.5');assert.match(await card.locator('.material-error').textContent(),/remaining core/);assert.equal(await card.locator('svg rect[stroke="#10283e"]').count(),0);
  await page.getByLabel('Attached flange minimum face thickness (mm)',{exact:true}).fill('.5');assert(await card.locator('.material-error').isHidden());
  await page.evaluate(()=>setParam('properties.panels',[{key:'upper:bay1:stringer1:segment1',stringer:{flange_thickness:.0008}}]));assert.match(await card.locator('.material-error').textContent(),/upper:bay1:stringer1:segment1.*exceed twice/);
  await page.evaluate(()=>setParam('properties.panels',[{key:'upper:bay1:stringer1:segment1',stringer:{flange_width:0,flange_thickness:0}}]));assert(await card.locator('.material-error').isHidden());
  checks.push('Invalid face/core totals and nonzero-flange panel overrides are rejected; blade-only panel overrides do not impose a flange core');
  await card.screenshot({path:path.join(out,'attached-flange-sandwich.png')});
  const saved=await page.evaluate(()=>editor.readDrafts());await page.evaluate(()=>{editor.destroy();install();});assert(!(await inherit.isChecked()));assert.equal(await construction.inputValue(),'sandwich');assert.equal((await page.evaluate(()=>flange())).face_material,4);assert.deepEqual(await page.evaluate(()=>editor.readDrafts()),saved);
  await page.evaluate(()=>setParam('stringers.model','beam'));assert(await card.isHidden());assert.deepEqual(await page.evaluate(()=>flange()),saved['materials.shells'].find(row=>row.component==='stringer_flange'));
  await page.evaluate(()=>setParam('stringers.model','shell'));await inherit.check();assert.equal(await page.evaluate(()=>flange()),undefined);assert(await material.isDisabled());assert.equal(await material.inputValue(),'4');
  await page.evaluate(()=>setParam('properties.stringer_flange_width',0));assert(await card.isHidden());await page.evaluate(()=>setParam('properties.stringer_flange_thickness',0));assert.equal(await page.evaluate(()=>flange()),undefined);
  await page.evaluate(()=>{editor.destroy();install();});assert.equal(await page.evaluate(()=>flange()),undefined);assert(await card.isHidden());
  checks.push('Study editor reconstruction restores explicit constructions; Use stringer material removes the optional row, and hidden beam/blade cards never create defaults');
  await page.evaluate(()=>setParam('properties.panels',[{key:'upper:bay1:stringer1:segment1',stringer:{flange_width:.03,flange_thickness:.003,material:2}},{key:'lower:bay2:stringer2:segment1',stringer:{flange_width:0,flange_thickness:0}}]));
  assert(await card.isVisible());assert(await inherit.isChecked());assert.equal(await page.evaluate(()=>flange()),undefined);
  await inherit.uncheck();await construction.selectOption('sandwich');
  assert.equal(await core.inputValue(),'Per-panel: 2');assert.match(await card.locator('.material-total').textContent(),/3 mm.*example panel upper:bay1:stringer1:segment1/);assert.equal(await card.locator('svg rect[stroke="#10283e"]').count(),3);
  assert(await card.locator('.material-error').isHidden());assert((await page.evaluate(()=>flange())).core_thickness>0);await page.evaluate(()=>editor.assertValidDraft());
  assert.equal(await page.evaluate(()=>document.getElementById('p-properties.stringer_flange_thickness').value),'0');
  await page.evaluate(()=>setParam('properties.panels',[{key:'upper:bay1:stringer1:segment1',stringer:{flange_width:.03,flange_thickness:.003}},{key:'upper:bay1:stringer2:segment1',stringer:{flange_width:.02,flange_thickness:.004}},{key:'lower:bay2:stringer2:segment1',stringer:{flange_width:0,flange_thickness:0}}]));
  assert.equal(await core.inputValue(),'Per-panel: 2 to 3');assert(await card.locator('.material-error').isHidden());await page.evaluate(()=>editor.assertValidDraft());
  await card.screenshot({path:path.join(out,'attached-flange-panel-overrides.png')});
  await page.evaluate(()=>setParam('properties.panels',[{key:'upper:bay1:stringer1:segment1',stringer:{flange_width:.03,flange_thickness:.0008}}]));assert.match(await card.locator('.material-error').textContent(),/upper:bay1:stringer1:segment1.*exceed twice/);
  await inherit.check();assert.equal(await page.evaluate(()=>flange()),undefined);assert(await card.locator('.material-error').isHidden());await page.evaluate(()=>editor.assertValidDraft());
  await page.evaluate(()=>setParam('properties.panels',[{key:'upper:bay1:stringer1:segment1',stringer:{flange_width:.03,flange_thickness:.003}}]));await inherit.uncheck();await construction.selectOption('sandwich');
  const panelDraft=await page.evaluate(()=>flange());await page.evaluate(()=>{editor.assertValidDraft();editor.destroy();install();});assert.deepEqual(await page.evaluate(()=>flange()),panelDraft);assert.equal(await core.inputValue(),'Per-panel: 2');
  await page.evaluate(()=>setParam('properties.panels',[]));assert(await card.isHidden());assert(await card.locator('.material-error').isHidden());assert.deepEqual(await page.evaluate(()=>flange()),panelDraft);
  checks.push('Default blade width/thickness zero permits real flanges in panel overrides; derived per-panel cores use each active flange total, ignore blade overrides, validate impossible faces, and leave inherited assignments unblocked');
  const persisted=await page.evaluate(async()=>{
   const drawings=WingSVGViewport.captureAll();drawings['material-stringer_flange'].viewport={x:12,y:-3,scale:2};WingSVGViewport.restoreAll(drawings);
   const view={controls:{},layers:{},camera:{target:[0,0,0],alpha:0,beta:1,radius:2},workspace:{activeTab:'properties',width:360,collapsed:false},activeCase:1,drawings:WingSVGViewport.captureAll()};
   const saved=await WingWorkspace.snapshot(editor.readDrafts(),null,view),loaded=WingWorkspace.parse(JSON.stringify(saved)).data;
   WingSVGViewport.restoreAll(loaded.view.drawings);return{saved:saved.view.drawings['material-stringer_flange'],restored:WingSVGViewport.captureAll()['material-stringer_flange'],assignment:loaded.parameters['materials.shells'].find(row=>row.component==='stringer_flange')};
  });assert.deepEqual(persisted.restored,persisted.saved);assert.deepEqual(persisted.assignment,panelDraft);assert.deepEqual(persisted.restored.viewport,{x:12,y:-3,scale:2});
  checks.push('Real material SVG viewport settings and flange assignment survive Save Study serialization, parsing and drawing restoration');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'materials-editor-summary.json'),JSON.stringify({passed:true,checks,errors,saved},null,2));console.log('Flange material browser checks passed: '+checks.length+' groups');
 }catch(error){await page.screenshot({path:path.join(out,'materials-editor-failure.png')}).catch(()=>{});fs.writeFileSync(path.join(out,'materials-editor-failure.json'),JSON.stringify({error:error.stack,errors,checks},null,2));throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
