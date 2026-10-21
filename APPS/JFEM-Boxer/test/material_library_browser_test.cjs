'use strict';
// node material_library_browser_test.cjs [PLAYWRIGHT] [OUTPUT]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [modulePath='playwright',output]=process.argv.slice(2),web=path.resolve(__dirname,'../web');
(async()=>{
 const {chromium}=require(modulePath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined});
 const page=await browser.newPage({viewport:{width:1200,height:1050}}),checks=[],errors=[];page.on('pageerror',error=>errors.push(error.stack));
 try{
  await page.setContent('<main id="workspace-content" style="width:360px;overflow:auto;height:1000px"><section id="group-materials"></section><section id="imported-materials" hidden></section></main>');
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  for(const[,file]of html.matchAll(/<link[^>]+rel="stylesheet"[^>]+href="([^"?]+)(?:\?[^\"]*)?"/g))await page.addStyleTag({content:fs.readFileSync(path.join(web,file),'utf8')});
  for(const file of ['reference_import.js','workspace.js','materials_editor.js','material_allowables.js'])await page.addScriptTag({path:path.join(web,file)});
  await page.evaluate(()=>{
   const params={'material.name':'Aluminium','material.E':71,'material.nu':.33,'material.rho':2780,'materials.library':[{id:2,name:'Steel',E:210e9,nu:.3,rho:7850},{id:3,name:'Core',E:100e6,nu:.3,rho:80}],'materials.shells':[],'materials.bars':[]};
   for(const[key,value]of Object.entries(params)){const row=document.createElement('label');row.className='row';row.append(key);const input=document.createElement('input');input.id='p-'+key;input.value=Array.isArray(value)?JSON.stringify(value):String(value);row.append(input);document.getElementById('group-materials').append(row);}
   window.savedRows=[];window.edits=[];
   window.install=()=>{
    window.materialEditor=WingMaterialsEditor.install({document,onEdit:key=>edits.push(key)});
    window.allowableEditor=WingMaterialAllowables.editor({document,host:materialEditor.allowablesHost,materialLibrary:materialEditor,
     readMaterials:()=>[{id:1,type:'MAT1',name:document.getElementById('p-material.name').value},...materialEditor.readDrafts()['materials.library'].map(row=>({...row,type:'MAT1'}))],readRows:()=>savedRows,onChange:rows=>savedRows=rows});
   };install();
  });
  const material=page.locator('#material-library-select');
  assert.equal(await material.inputValue(),'1');assert(await page.locator('[id="p-material.name"]').isVisible());assert(await page.locator('#allowable-material').isHidden());assert.equal(await page.locator('.material-library-row:visible').count(),1);
  await page.locator('#allowable-mode').selectOption('stress');await page.locator('#allowable-stress').fill('320');
  assert.deepEqual(await page.evaluate(()=>savedRows),[{material_id:1,mode:'stress',stress:320e6}]);assert.match(await page.locator('#material-library-allowables').textContent(),/MPa/);
  await material.selectOption('2');assert(await page.locator('[id="p-material.name"]').isHidden());assert.equal(await page.locator('#allowable-mode').inputValue(),'none');
  await page.getByLabel('Material 2 name',{exact:true}).fill('Steel updated');await page.locator('.material-library-row:visible').getByLabel('E (GPa)',{exact:true}).fill('205');
  await page.locator('#allowable-mode').selectOption('stress');await page.locator('#allowable-stress').fill('500');
  assert.equal(await page.evaluate(()=>materialEditor.readDrafts()['materials.library'][0].E),205e9);
  await material.selectOption('1');assert.equal(await page.locator('#allowable-stress').inputValue(),'320');assert.equal(await page.locator('.material-library-row:visible').count(),1);
  checks.push('One material selector links each visible elastic definition and its MPa allowable; switching preserves independent limits and moduli remain GPa');

  const persisted=await page.evaluate(async()=>{
   const parameters={...materialEditor.readDrafts(),'materials.allowables':savedRows};
   const view={controls:{},layers:{},camera:{target:[0,0,0],alpha:0,beta:1,radius:2},workspace:{activeTab:'material',width:360,collapsed:false},activeCase:1};
   const study=await WingWorkspace.snapshot(parameters,null,view),reopened=WingWorkspace.parse(JSON.stringify(study)).data;
   materialEditor.destroy();allowableEditor.destroy();for(const key of ['materials.library','materials.shells','materials.bars'])document.getElementById('p-'+key).value=JSON.stringify(reopened.parameters[key]);savedRows=reopened.parameters['materials.allowables'];install();return reopened.parameters;
  });
  assert.deepEqual(persisted['materials.allowables'],[{material_id:1,mode:'stress',stress:320e6},{material_id:2,mode:'stress',stress:500e6}]);
  assert.equal(await page.locator('#material-library-select').count(),1);assert.equal(await page.locator('[id="p-material.name"]').count(),1);assert.equal(await page.locator('#allowable-stress').inputValue(),'320');
  await material.selectOption('2');assert.equal(await page.locator('#allowable-stress').inputValue(),'500');assert.equal(await page.getByLabel('Material 2 name',{exact:true}).inputValue(),'Steel updated');
  checks.push('Real Study serialization and parse retain canonical Pa limits and material definitions; reconstruction restores MPa without duplicate controls');

  await page.evaluate(()=>{savedRows.push({material_id:77,mode:'stress',stress:275e6});allowableEditor.refresh();});await material.selectOption('77');assert.match(await page.locator('#material-library-allowables .material-error').textContent(),/incompatible with Unavailable/);assert.equal(await page.locator('#allowable-stress').inputValue(),'275');await page.locator('#allowable-mode').selectOption('none');await page.evaluate(()=>allowableEditor.refresh());assert.equal(await material.locator('option[value="77"]').count(),0);
  await page.getByRole('button',{name:'+ Add material',exact:true}).click();assert.equal(await material.inputValue(),'4');assert(await page.getByLabel('Material 4 name',{exact:true}).isVisible());assert.equal(await page.locator('#allowable-mode').inputValue(),'none');
  checks.push('New materials become the active definition; saved orphan allowables remain accessible and can be removed explicitly');

  const widths=[];for(const width of [280,360,1000]){await page.locator('#workspace-content').evaluate((node,w)=>node.style.width=w+'px',width);const overflow=await page.evaluate(()=>{const box=document.getElementById('workspace-content').getBoundingClientRect();return[...document.querySelectorAll('.materials-library input,.materials-library select')].filter(node=>node.getClientRects().length).filter(node=>{const rect=node.getBoundingClientRect();return rect.left<box.left-1||rect.right>box.right+1}).map(node=>node.id||node.getAttribute('aria-label'));});assert.deepEqual(overflow,[]);widths.push(width);}
  await material.selectOption('1');await page.locator('#workspace-content').evaluate(node=>node.style.width='360px');
  if(output){fs.mkdirSync(output,{recursive:true});await page.locator('.materials-library').screenshot({path:path.join(output,'unified-material-library.png')});}
  checks.push('Grouped material definition and allowable inputs remain inside 280, 360 and 1000 pixel panes');

  await page.evaluate(()=>{
   materialEditor.destroy();allowableEditor.destroy();document.getElementById('group-materials').hidden=true;const host=document.getElementById('imported-materials');host.hidden=false;savedRows=[];
   window.allowableEditor=WingMaterialAllowables.editor({document,host,showDefinition:true,sourceUnits:()=>true,readMaterials:()=>[{id:41,type:'MAT1',name:'Source steel',E:210000,G:80769,nu:.3,rho:7.85e-9},{id:93,MID:93,type:'MAT8',name:'Source composite',E_Pa:135000,E1_Pa:135000,E2_Pa:10000,nu12:.3,G12_Pa:5000,rho_kg_m3:1.6e-9}],readRows:()=>savedRows,onChange:rows=>savedRows=rows});
  });
  assert.equal(await page.locator('#imported-materials .material-imported-definition input').count(),0);assert.match(await page.locator('.material-imported-definition').innerText(),/210000/);
  await page.locator('#allowable-mode').selectOption('stress');await page.locator('#allowable-stress').fill('275');assert.deepEqual(await page.evaluate(()=>savedRows),[{material_id:41,mode:'stress',stress:275}]);assert.match(await page.locator('#allowable-stress').locator('..').textContent(),/source stress units/);
  await page.locator('#allowable-material').selectOption('93');assert.match(await page.locator('.material-imported-definition').innerText(),/135000/);assert.match(await page.locator('.material-imported-definition').innerText(),/MAT8/);await page.locator('#allowable-mode').selectOption('strain');await page.locator('#allowable-strain_tension').fill('.01');await page.locator('#allowable-strain_compression').fill('.008');
  assert.deepEqual(await page.locator('.material-definition-values dt').allTextContents(),['Longitudinal modulus E1','Transverse modulus E2','Poisson ratio '+String.fromCharCode(957)+'12','Shear modulus G12','Density']);
  if(output)await page.locator('#imported-materials').screenshot({path:path.join(output,'imported-material-definition-allowables.png')});
  checks.push('Imported catalogue has one selector with read-only source elastic constants and editable stress/strain limits; source stress units are not inferred');
  assert.deepEqual(errors,[]);const summary={passed:true,checks,widths,errors};if(output)fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify(summary,null,2));console.log(JSON.stringify(summary));
 }catch(error){if(output){fs.mkdirSync(output,{recursive:true});await page.screenshot({path:path.join(output,'failure.png')});fs.writeFileSync(path.join(output,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));}throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
