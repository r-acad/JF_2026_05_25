'use strict';
// node material_allowables_editor_browser_test.cjs [PLAYWRIGHT] [OUTPUT]
// Exercises the real editor and stylesheet stack without running a solver.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [modulePath='playwright',output]=process.argv.slice(2),web=path.resolve(__dirname,'../web');
(async()=>{
 const {chromium}=require(modulePath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined});
 const page=await browser.newPage({viewport:{width:1200,height:1000}}),checks=[],errors=[];page.on('pageerror',error=>errors.push(error.stack));
 try{
  await page.setContent('<div id="workspace-content" style="width:360px;height:950px;overflow:auto"><section id="panel-material-allowables" class="workspace-panel"></section></div>');
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  for(const[,file]of html.matchAll(/<link[^>]+rel="stylesheet"[^>]+href="([^"?]+)(?:\?[^\"]*)?"/g))await page.addStyleTag({content:fs.readFileSync(path.join(web,file),'utf8')});
  await page.addScriptTag({path:path.join(web,'material_allowables.js')});
  await page.evaluate(()=>{
   window.setup=({materials=[],rows=[],source=false}={})=>{
    window.allowableEditor?.destroy();window.materialCatalogue=materials;window.savedRows=rows;window.sourceUnits=source;window.changes=0;
    window.allowableEditor=WingMaterialAllowables.editor({document,host:document.getElementById('panel-material-allowables'),readMaterials:()=>structuredClone(materialCatalogue),readRows:()=>savedRows,sourceUnits:()=>sourceUnits,onChange:rows=>{savedRows=rows;changes++;}});
   };
   setup({materials:[{id:1,type:'MAT1',name:'Aluminum'},{id:8,type:'MAT8',name:'UD carbon'}]});
  });
  const rows=()=>page.evaluate(()=>savedRows),status=page.locator('#panel-material-allowables .material-error');
  assert.equal(await page.locator('#allowable-material option').count(),2);assert.equal(await page.locator('#allowable-mode').inputValue(),'none');assert.equal(await page.locator('.allowable-fields input:visible').count(),0);
  assert(await page.locator('#allowable-mode option[value=strain]').evaluate(el=>el.disabled));assert(!(await page.locator('#allowable-mode option[value=stress]').evaluate(el=>el.disabled)));
  await page.locator('#allowable-mode').selectOption('stress');assert.match(await status.textContent(),/Incomplete limits/);
  await page.locator('#allowable-stress').fill('0.25');assert.deepEqual(await rows(),[{material_id:1,mode:'stress',stress:250e6}]);assert(!(await status.isVisible()));
  assert.match(await page.locator('#allowable-stress').locator('..').textContent(),/GPa/);assert.equal(await page.locator('.allowable-fields input:visible').count(),1);
  checks.push('Generated MAT1 uses a single stress limit with GPa to Pa conversion and incompatible strain mode disabled');

  await page.locator('#allowable-material').selectOption('8');assert(await page.locator('#allowable-mode option[value=stress]').evaluate(el=>el.disabled));
  await page.locator('#allowable-mode').selectOption('strain');assert.match(await status.textContent(),/Incomplete limits/);
  const limits={strain_tension:.01,strain_compression:.006};
  for(const[key,value]of Object.entries(limits))await page.locator('#allowable-'+key).fill(String(value));
  assert.equal(await page.locator('.allowable-fields input:visible').count(),2);assert(!(await status.isVisible()));
  assert.deepEqual((await rows())[1],{material_id:8,mode:'strain',...limits});
  await page.locator('#panel-material-allowables summary').click();assert.match(await page.locator('#panel-material-allowables details').innerText(),/engineering shear strain, twice tensor shear/);assert.match(await page.locator('#panel-material-allowables details').innerText(),/every ply uses the same orthotropic MAT8 material ID/);
  await page.locator('#panel-material-allowables summary').click();
  checks.push('MAT8 exposes exactly two dimensionless principal-strain limits, explains tensor shear and the same-material laminate restriction');

  const saved=await rows();await page.locator('#allowable-material').selectOption('1');assert.equal(await page.locator('#allowable-stress').inputValue(),'0.25');
  await page.locator('#allowable-material').selectOption('8');for(const[key,value]of Object.entries(limits))assert.equal(await page.locator('#allowable-'+key).inputValue(),String(value));
  await page.evaluate(()=>{savedRows=JSON.parse(JSON.stringify(savedRows));allowableEditor.refresh();});assert.deepEqual(await rows(),saved);assert.equal(await page.locator('#allowable-material').inputValue(),'8');
  checks.push('Switching materials and restoring serialized rows preserves each material and its selected basis');

  await page.locator('#allowable-strain_tension').fill('-0.01');assert.match(await status.textContent(),/positive/);assert(await page.evaluate(()=>{try{allowableEditor.assertValid();return false}catch{return true}}));
  await page.locator('#allowable-strain_tension').fill('0');assert.match(await status.textContent(),/positive/);
  await page.locator('#allowable-strain_tension').fill('');assert.match(await status.textContent(),/Incomplete/);
  await page.locator('#allowable-strain_tension').pressSequentially('1e');assert(await page.locator('#allowable-strain_tension').evaluate(el=>el.validity.badInput));assert.match(await status.textContent(),/positive/);
  assert.deepEqual((await rows())[1].strain_tension,{raw:'invalid number'});
  await page.locator('#allowable-strain_tension').fill('.01');assert(!(await status.isVisible()));await page.evaluate(()=>allowableEditor.assertValid());
  checks.push('Negative, zero, blank, and unfinished exponent input stay visibly invalid or incomplete and can be corrected');

  const widths=[];
  for(const width of [280,360,1000]){
   await page.locator('#workspace-content').evaluate((el,w)=>el.style.width=w+'px',width);
   const result=await page.evaluate(()=>{const host=document.getElementById('workspace-content').getBoundingClientRect();return{width:host.width,overflow:[...document.querySelectorAll('#panel-material-allowables input,#panel-material-allowables select')].filter(el=>el.getClientRects().length).filter(el=>{const r=el.getBoundingClientRect();return r.left<host.left-1||r.right>host.right+1}).map(el=>el.id)};});
   assert.deepEqual(result.overflow,[]);widths.push(result);
  }
  await page.locator('#workspace-content').evaluate(el=>el.style.width='360px');
  if(output){fs.mkdirSync(output,{recursive:true});await page.locator('#workspace-content').screenshot({path:path.join(output,'generated-strain-allowables.png')});}
  checks.push('All inputs fit narrow, ordinary and maximized panes at 280, 360 and 1000 pixels');

  await page.locator('#allowable-mode').selectOption('none');assert.deepEqual(await rows(),[saved[0]]);assert.equal(await page.locator('.allowable-fields input:visible').count(),0);
  await page.evaluate(()=>allowableEditor.refresh());assert.equal(await page.locator('#allowable-strain_tension').inputValue(),'');
  checks.push('Not assessed removes only the chosen material criterion; refreshing clears its former values');

  await page.evaluate(()=>setup({source:true,materials:[{id:41,type:'MAT1',name:'Imported metal'},{id:93,type:'MAT8',name:'Imported composite'}]}));
  assert.equal(await page.locator('#allowable-material option').count(),2);assert.match(await page.locator('#allowable-material').textContent(),/41.*Imported metal/);
  await page.locator('#allowable-mode').selectOption('stress');await page.locator('#allowable-stress').fill('275');assert.deepEqual(await rows(),[{material_id:41,mode:'stress',stress:275}]);
  assert.match(await page.locator('#allowable-stress').locator('..').textContent(),/source stress units/);assert.match(await page.locator('#panel-material-allowables').textContent(),/no unit conversion is inferred/);
  if(output)await page.locator('#workspace-content').screenshot({path:path.join(output,'imported-stress-allowable.png')});
  await page.locator('#allowable-material').selectOption('93');await page.locator('#allowable-mode').selectOption('strain');for(const[key,value]of Object.entries(limits))await page.locator('#allowable-'+key).fill(String(value));assert.deepEqual((await rows())[1],{material_id:93,mode:'strain',...limits});
  checks.push('Imported material IDs and names are retained; stress uses source units while strains remain dimensionless');

  const legacy={material_id:8,mode:'strain',e1_t:.01,e1_c:.006,e2_t:.004,e2_c:.008,g12:.02};
  await page.evaluate(row=>setup({materials:[{id:8,type:'MAT8',name:'Older Study material'}],rows:[row]}),legacy);
  assert.deepEqual(await rows(),[legacy]);assert.equal(await page.evaluate(()=>changes),0);
  assert.equal(await page.locator('#allowable-strain_tension').inputValue(),'');assert.equal(await page.locator('#allowable-strain_compression').inputValue(),'');
  assert.equal(await page.locator('.allowable-fields input:visible').count(),2);assert.equal(await page.locator('#allowable-e1_t').count(),0);
  assert.match(await status.textContent(),/Saved directional limits are not converted/);
  await page.locator('#allowable-strain_tension').fill('.012');assert.match(await status.textContent(),/Incomplete limits/);
  assert.deepEqual((await rows())[0],{...legacy,strain_tension:.012});
  await page.locator('#allowable-strain_compression').fill('.008');assert(!(await status.isVisible()));
  assert.deepEqual((await rows())[0],{...legacy,strain_tension:.012,strain_compression:.008});
  await page.evaluate(()=>allowableEditor.refresh());assert.equal(await page.locator('#allowable-strain_tension').inputValue(),'0.012');
  if(output)await page.locator('#workspace-content').screenshot({path:path.join(output,'legacy-explicit-principal-limits.png')});
  checks.push('Older directional rows load unchanged and remain unassessed until both new limits are explicitly entered; original fields are retained');

  await page.evaluate(()=>setup({materials:[{id:1,type:'MAT1'}],rows:[{material_id:1,mode:'strain',e1_t:.01,e1_c:.006,e2_t:.004,e2_c:.008,g12:.02}]}));
  assert.equal(await page.locator('#allowable-material option').count(),1);assert.equal(await page.locator('#allowable-mode').inputValue(),'strain');assert.match(await status.textContent(),/incompatible with MAT1/);assert(await page.locator('#allowable-mode option[value=strain]').evaluate(el=>el.disabled));
  await page.locator('#allowable-mode').selectOption('none');assert.deepEqual(await rows(),[]);
  checks.push('A restored incompatible basis is flagged and can be removed without corrupting its saved input');

  await page.evaluate(()=>setup({materials:[],rows:[{material_id:77,mode:'stress',stress:200e6}]}));
  assert.equal(await page.locator('#allowable-material option').count(),1);assert.match(await page.locator('#allowable-material').textContent(),/Saved material not in current model/);assert.match(await status.textContent(),/incompatible with Unavailable/);
  assert(await page.locator('#allowable-mode option[value=stress]').evaluate(el=>el.disabled));assert(await page.locator('#allowable-mode option[value=strain]').evaluate(el=>el.disabled));
  await page.locator('#allowable-mode').selectOption('none');await page.evaluate(()=>allowableEditor.refresh());assert.deepEqual(await rows(),[]);assert.equal(await page.locator('#allowable-material option').count(),0);
  assert(await page.locator('#allowable-material').isDisabled());assert(await page.locator('#allowable-mode').isDisabled());assert.equal(await page.locator('.allowable-fields input:visible').count(),0);
  await page.evaluate(()=>setup());assert.equal(await page.locator('#allowable-material option').count(),0);assert.equal(await page.evaluate(()=>changes),0);assert.equal(await page.locator('#allowable-material').count(),1);assert.equal(await page.locator('#allowable-mode').count(),1);
  if(output)await page.locator('#workspace-content').screenshot({path:path.join(output,'empty-material-catalogue.png')});
  checks.push('Missing saved materials remain visible and removable; an empty catalogue disables editing and reset creates no duplicate controls');

  assert.deepEqual(errors,[]);const summary={passed:true,checks,widths,errors};
  if(output)fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify(summary,null,2));console.log(JSON.stringify(summary));
 }catch(error){if(output){fs.mkdirSync(output,{recursive:true});await page.screenshot({path:path.join(output,'failure.png')});fs.writeFileSync(path.join(output,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));}throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
