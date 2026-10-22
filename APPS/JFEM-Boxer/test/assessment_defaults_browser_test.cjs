'use strict';
// Real Boxer forms: node assessment_defaults_browser_test.cjs SCHEMA_JSON OUT PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [schemaFile,out,modulePath='playwright']=process.argv.slice(2),web=path.resolve(__dirname,'../web'),apps=path.resolve(web,'../..');
(async()=>{
 const {chromium}=require(modulePath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1400,height:1000}}),errors=[],checks=[];page.on('pageerror',error=>errors.push(error.stack));fs.mkdirSync(out,{recursive:true});
 try{
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.setContent(html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,''));
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:file==='shared/jfem_graphics.js'?path.join(apps,'jfem_graphics.js'):path.join(web,file)});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8'),cut=app.indexOf('(async function start()');assert(cut>0);await page.addScriptTag({content:app.slice(0,cut)});
  await page.evaluate(schema=>{
   initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.values=structuredClone(schema.values);state.defaults=structuredClone(schema.values);
   state.values['material.name']='AL2024';state.values['materials.allowables']=[];state.values['materials.library']=[];
   state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;buildForm(state.schema,state.values);
   document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;
  },JSON.parse(fs.readFileSync(schemaFile,'utf8')));
  const initial=await page.evaluate(()=>({rows:collectParams()['materials.allowables'],saved:state.values['materials.allowables']}));
  assert.equal(initial.rows[0].stress,300e6);assert.deepEqual(initial.rows,initial.saved);
  await page.evaluate(()=>activateWorkspaceTab('material'));assert.equal(await page.locator('#allowable-stress').inputValue(),'300');
  const signature=await page.evaluate(()=>formSignature());
  checks.push('Legacy empty allowables acquire300MPa before opening Materials, and the canonical saved parameters agree with the visible editor.');
  await page.locator('#allowable-stress').fill('350');assert.equal(await page.evaluate(()=>collectParams()['materials.allowables'][0].stress),350e6);assert.equal(await page.evaluate(()=>formSignature()),signature);
  await page.locator('#allowable-mode').selectOption('none');await page.evaluate(()=>refreshMaterialAllowableEditor());assert.equal(await page.locator('#allowable-mode').inputValue(),'none');assert.equal(await page.evaluate(()=>collectParams()['materials.allowables'][0].mode),'none');
  await page.evaluate(()=>{state.values=structuredClone(collectParams());buildForm(state.schema,state.values);activateWorkspaceTab('material');});assert.equal(await page.locator('#allowable-mode').inputValue(),'none');
  checks.push('Explicit350MPa and Not assessed persist through form rebuild; editing assessment does not alter the FE signature.');
  await page.evaluate(()=>{document.getElementById('p-materials.allowables').value='[]';document.getElementById('p-material.name').value='AL2024';readMaterialAllowables();document.getElementById('p-material.name').value='Steel';});assert.deepEqual(await page.evaluate(()=>readMaterialAllowables()),[]);
  await page.evaluate(()=>{document.getElementById('p-material.name').value='AL2024';refreshMaterialAllowableEditor();});assert.equal(await page.locator('#allowable-stress').inputValue(),'300');
  await page.locator('#allowable-stress').fill('300');await page.evaluate(()=>{document.getElementById('p-material.name').value='Steel';});assert.equal(await page.evaluate(()=>readMaterialAllowables()[0].stress),300e6);
  checks.push('Renaming removes an untouched alloy default, preserves an explicitly entered300MPa value, and invalidates the catalog-aware cache.');
  for(const imported of ['importedDeck','diskResults']){
   await page.evaluate(key=>{state[key]={};state.data={materials:{library:[{id:1,type:'MAT1',name:'AL2024'}]}};document.getElementById('p-materials.allowables').value='[]';},imported);
   assert.deepEqual(await page.evaluate(()=>readMaterialAllowables()),[]);
   await page.evaluate(()=>{document.getElementById('p-materials.allowables').value=JSON.stringify([{material_id:1,mode:'stress',stress:300e6,origin:'al2024_design_default'},{material_id:2,mode:'stress',stress:275}]);});
   assert.deepEqual(await page.evaluate(()=>readMaterialAllowables()),[{material_id:2,mode:'stress',stress:275}]);
   await page.evaluate(key=>{state[key]=null;state.data=null;},imported);
  }
  checks.push('Imported decks and unrelated result archives never receive an inferred SI allowable.');
  const fixities=await page.evaluate(()=>{
   const keys=['stringers.euler_fixity_coefficient','stringers.skin_fixity_coefficient','properties.spar_web_buckling_fixity','properties.rib_web_buckling_fixity','properties.spar_cap_euler_fixity','properties.rib_stiffener_euler_fixity'];
   return keys.map(key=>{const input=document.getElementById('p-'+key),next=input.nextSibling,parent=input.parentNode;input.remove();delete state.values[key];const absent=readBucklingFixity(key);state.values[key]=null;const nullValue=readBucklingFixity(key);parent.insertBefore(input,next);input.value='';const blank=Number.isNaN(readBucklingFixity(key));input.value='0';const zero=readBucklingFixity(key);input.value='-1';const negative=readBucklingFixity(key);input.value='1';return{key,absent,nullValue,blank,zero,negative};});
  });for(const row of fixities){assert.equal(row.absent,1);assert.equal(row.nullValue,1);assert(row.blank);assert.equal(row.zero,0);assert.equal(row.negative,-1);}
  checks.push('All six coefficients default omitted/null state to1 while preserving explicit blank, zero and negative edits for validation.');
  await page.evaluate(()=>{document.getElementById('p-material.name').value='AL2024';document.getElementById('p-materials.allowables').value='[]';activateWorkspaceTab('material');refreshMaterialAllowableEditor();});
  await page.screenshot({path:path.join(out,'al2024-default.png')});assert.deepEqual(errors,[]);
  const summary={passed:true,checks,fixities,errors};fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(summary,null,2));console.log(JSON.stringify(summary));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
