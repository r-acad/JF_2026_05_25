'use strict';
// node test/structural_mass_bays_browser_test.cjs <fixture-dir> <evidence-dir> [playwright-module]
// Actual generated bay_concentrated_schema.json and bay_concentrated_model.msgpack.
// No mesh-generation or solver requests. CHROME_PATH optionally selects Chrome.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
if(!process.argv[2]||!process.argv[3])throw Error('Pass generated fixture directory, evidence directory and optional Playwright module');
const fixture=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]),web=path.resolve(__dirname,'../web'),{chromium}=require(process.argv[4]||'playwright');
const schema=JSON.parse(fs.readFileSync(path.join(fixture,'bay_concentrated_schema.json'),'utf8'));schema.defaults??=schema.values;
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],requests=[];
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1510,height:1080}});page.on('pageerror',e=>errors.push(e.stack));
 try{
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');await page.route('http://127.0.0.1:43957/**',route=>{const url=new URL(route.request().url());if(url.pathname.startsWith('/api/')){requests.push(url.pathname);return route.fulfill({status:404,json:{error:'Display-only replay'}});}return url.pathname==='/'?route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')}):route.fulfill({path:path.join(web,url.pathname)});});
  await page.goto('http://127.0.0.1:43957/');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:app.slice(0,app.indexOf('(async function start()'))});
  await page.evaluate(({schema,bytes})=>{
   initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.defaults=schema.defaults;state.data=MessagePack.decode(Uint8Array.from(bytes));state.values=state.data.model_params;state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;buildForm(state.schema,state.values);buildModel(state.data);state.modelSignature=formSignature();setModelDirty(false);setBusy(false);markStudySaved();document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;
   window.massDefinition=formSignature();window.massCoordinates=Array.from(state.baseline);activateWorkspaceTab('displaymass');meshStatus('Generated mass fixture ready','current');
  },{schema,bytes:[...fs.readFileSync(path.join(fixture,'bay_concentrated_model.msgpack'))]});
  await page.locator('#show-structural-inertia').check();
  const evidence=await page.evaluate(()=>{
   const bays=state.data.weights.structural_inertia,meshes=state.structuralMassDisplay.meshes,xyz=asF32(state.data.nodes.xyz),toView=p=>[p[1],p[2],p[0]];
   return{representation:state.values['mass.structural_representation'],count:bays.length,status:document.getElementById('structural-mass-status').textContent,tooltip:document.getElementById('structural-mass-status').title,bays:bays.map(b=>{
    const ellipsoid=meshes.find(m=>m.name==='structural-mass-ellipsoid-'+b.index),cg=meshes.find(m=>m.name==='structural-mass-cg-'+b.index),ref=meshes.find(m=>m.name==='structural-mass-reference-'+b.index),offset=meshes.find(m=>m.name==='structural-mass-offset-'+b.index);
    return{bay:b.index,mass:b.mass_kg,referenceGrid:b.reference_grid,gridIndex:state.nodeIds.indexOf(b.reference_grid),referenceNode:b.reference_node,grid:toView(Array.from(xyz.slice(3*b.reference_node,3*b.reference_node+3))),reference:toView(b.reference_m),cgExpected:toView(b.center_of_gravity_m),ellipsoid:ellipsoid?.position.asArray(),marker:ref?.position.asArray(),cg:cg?.position.asArray(),cgColor:cg?.material.emissiveColor.toHexString(),visible:ellipsoid?.isEnabled()&&cg?.isEnabled()&&ref?.isEnabled(),offsetVisible:offset?.isEnabled(),metadata:ellipsoid?.metadata};
   })};
  });
  assert.equal(evidence.representation,'bay_concentrated');assert(evidence.count>=2);assert.match(evidence.status,/structural rib bays/);assert.match(evidence.tooltip,/GRID/);
  for(const b of evidence.bays){assert(b.visible);assert.equal(b.gridIndex,b.referenceNode);assert.equal(b.metadata.reference_grid,b.referenceGrid);assert.equal(b.metadata.inertia_origin,'bay_reference');assert.equal(b.cgColor.toLowerCase(),'#f6b758');
   for(let i=0;i<3;i++){assert(Math.abs(b.ellipsoid[i]-b.reference[i])<1e-12);assert(Math.abs(b.marker[i]-b.reference[i])<1e-12);assert(Math.abs(b.grid[i]-b.reference[i])<1e-6);assert(Math.abs(b.cg[i]-b.cgExpected[i])<1e-12);}
  }
  assert(evidence.bays.some(b=>b.offsetVisible));checks.push('Every physical rib bay has one ellipsoid centered at its actual reference GRID; the orange true-CG marker and offset remain distinct');
  const radii=await page.evaluate(()=>state.structuralMassDisplay.meshes.filter(m=>m.name.startsWith('structural-mass-ellipsoid-')).map(m=>m.scaling.asArray()));
  await page.locator('#structural-inertia-scale').fill('1.5');await page.locator('#structural-inertia-scale').dispatchEvent('change');
  const scaled=await page.evaluate(()=>state.structuralMassDisplay.meshes.filter(m=>m.name.startsWith('structural-mass-ellipsoid-')).map(m=>m.scaling.asArray()));for(let i=0;i<radii.length;i++)for(let j=0;j<3;j++)assert(Math.abs(scaled[i][j]-1.5*radii[i][j])<1e-12);
  await page.locator('#show-structural-inertia').uncheck();assert(await page.evaluate(()=>state.structuralMassDisplay.meshes.every(m=>!m.isEnabled())));await page.locator('#show-structural-inertia').check();
  checks.push('Scale and visibility change the glyphs without changing the physical mass setting');
  await page.evaluate(async()=>{document.getElementById('surface-mode').value='translucent';document.getElementById('surface-mode').dispatchEvent(new Event('change'));document.getElementById('surface-translucency').value='80';document.getElementById('surface-translucency').dispatchEvent(new Event('input'));setLayerVisible('AERO_SURFACE',false);state.engine.resize();await state.scene.whenReadyAsync();state.scene.render();await new Promise(requestAnimationFrame);document.getElementById('workspace-content').scrollTop=0;});
  await page.screenshot({path:path.join(out,'structural-rib-bay-masses.png')});
  await page.locator('#mass-representation-link').click();assert.equal(await page.locator('[id="p-mass.structural_representation"]').inputValue(),'bay_concentrated');assert(await page.locator('#group-mass').isVisible());
  assert(await page.evaluate(()=>!state.studyDirty&&formSignature()===massDefinition&&massCoordinates.every((x,i)=>x===state.baseline[i])));assert.deepEqual(errors,[]);assert.deepEqual(requests,[]);
  checks.push('Display links to the physical Mass setting while retaining an unchanged Study definition and FE coordinates');
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,evidence,errors,requests},null,2));console.log(`Structural bay mass browser: ${checks.length} groups passed.`);
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors,requests},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
