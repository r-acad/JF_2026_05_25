'use strict';
// Exercises an actual isolated app server and a synthetic generated model.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [url,fixturePath,outPath,modulePath]=process.argv.slice(2);
if(!url||!fixturePath||!outPath)throw Error('Usage: node sensitivity_progress_browser_test.cjs <server-url> <worker-progress-fixture.json> <evidence-dir> [playwright-module]');
const {chromium}=require(modulePath?path.resolve(modulePath):'playwright'),out=path.resolve(outPath),fixture=JSON.parse(fs.readFileSync(fixturePath,'utf8'));
fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1600,height:1050}}),errors=[],checks=[];
 page.setDefaultTimeout(120000);page.on('pageerror',error=>errors.push(error.stack));
 try{
  await page.goto(url);await page.waitForFunction(()=>typeof state!=='undefined'&&state.schema&&!state.loadingInput);
  await page.getByRole('button',{name:'Start new study',exact:true}).click();
  await page.waitForFunction(()=>state.autoMeshReady&&!!state.data&&!state.loadingInput&&!state.workspaceBusy&&!state.meshRequestInFlight&&!state.busy);
  assert.equal(await page.evaluate(()=>state.importedDeck!==null&&state.importedDeck!==undefined),false);
  console.log('Synthetic FEM ready');
  await page.evaluate(()=>activateWorkspaceTab('sensitivity'));
  await page.locator('#sensitivity-inspect').click();
  assert.equal(await page.locator('#sensitivity-inspect').getAttribute('aria-pressed'),'true');
  const nodePoint=await page.evaluate(()=>{
   const positions=currentPositions(),vp=state.camera.viewport.toGlobal(state.engine.getRenderWidth(),state.engine.getRenderHeight()),transform=state.scene.getTransformMatrix(),scale=state.engine.getHardwareScalingLevel(),rect=state.engine.getRenderingCanvas().getBoundingClientRect(),hidden=inspectionDepthTest();
   for(const i of visibleNodeIndices()){
    const point=vec(positions,i),p=BABYLON.Vector3.Project(point,BABYLON.Matrix.IdentityReadOnly,transform,vp),x=p.x*scale+rect.left,y=p.y*scale+rect.top;
    if(x>530&&x<innerWidth-120&&y>180&&y<innerHeight-180&&p.z>=0&&p.z<=1&&!hidden(point.asArray(),'node',state.nodeIds[i]))return{x,y};
   }return null;
  });assert(nodePoint,'visible pickable structural GRID');
  await page.mouse.click(nodePoint.x,nodePoint.y);
  const pickedNode=await page.evaluate(()=>({tab:workspaceUI.activeTab,id:state.sensitivity.capture().objective.node_id,selected:state.nodeIds[state.selectedNode],armed:state.sensitivity.pickTarget()}));
  assert.equal(pickedNode.tab,'sensitivity');assert.equal(pickedNode.id,pickedNode.selected);assert(pickedNode.id>0);assert.equal(pickedNode.armed,null);
  assert.match(await page.locator('#sensitivity-target-note').textContent(),/selected as the response target/);
  await page.screenshot({path:path.join(out,'sensitivity-direct-grid-pick.png')});checks.push('Inspect picks a physical GRID, fills the response target and stays in Sensitivity.');
  await page.locator('#sensitivity-objective').selectOption('shell_stress');await page.locator('#sensitivity-inspect').click();
  const shellPoint=await page.evaluate(()=>{
   const positions=currentPositions(),vp=state.camera.viewport.toGlobal(state.engine.getRenderWidth(),state.engine.getRenderHeight()),transform=state.scene.getTransformMatrix(),scale=state.engine.getHardwareScalingLevel(),rect=state.engine.getRenderingCanvas().getBoundingClientRect();
   for(const element of state.elements.values()){
    if(!['quad','tria'].includes(element.group.kind))continue;
    const center=element.nodes.reduce((sum,i)=>sum.add(vec(positions,i)),BABYLON.Vector3.Zero()).scale(1/element.nodes.length),p=BABYLON.Vector3.Project(center,BABYLON.Matrix.IdentityReadOnly,transform,vp),x=p.x*scale,y=p.y*scale;
    if(x+rect.left<530||x+rect.left>innerWidth-120||y+rect.top<180||y+rect.top>innerHeight-180)continue;
    const hit=state.scene.pick(x,y,mesh=>mesh.isEnabled()&&mesh.isPickable&&mesh.metadata?.feGroup&&inspectionMatches(mesh.metadata.feGroup,'shells'));
    if(hit?.hit)return{x:x+rect.left,y:y+rect.top};
   }return null;
  });assert(shellPoint,'visible pickable structural shell');await page.mouse.click(shellPoint.x,shellPoint.y);
  const pickedElement=await page.evaluate(()=>({tab:workspaceUI.activeTab,id:state.sensitivity.capture().objective.element_id,selected:state.selectedElement,armed:state.sensitivity.pickTarget()}));
  assert.equal(pickedElement.tab,'sensitivity');assert.equal(pickedElement.id,pickedElement.selected);assert(pickedElement.id>0);assert.equal(pickedElement.armed,null);
  await page.screenshot({path:path.join(out,'sensitivity-direct-element-pick.png')});checks.push('Shell objective restricts direct picking to shell elements and keeps the panel open.');
  await page.locator('#sensitivity-inspect').click();await page.locator('#sensitivity-inspect').click();assert.equal(await page.locator('#sensitivity-inspect').getAttribute('aria-pressed'),'false');
  const setup=await page.evaluate(()=>state.sensitivity.serialize());
  await page.locator('.sensitivity-saved summary').click();await page.waitForFunction(()=>!document.getElementById('sensitivity-saved-refresh').disabled);
  assert.equal(await page.evaluate(()=>state.sensitivity.serialize()),setup);
  assert.match(await page.locator('.sensitivity-saved').textContent(),/without solving again/);assert.match(await page.locator('#sensitivity-saved-open').getAttribute('title'),/does not rerun/);
  await page.screenshot({path:path.join(out,'saved-sensitivity-results-help.png')});checks.push('Saved runs are collapsed by default, explain setup versus derivative storage, and opening the browser preserves the current setup.');
  await page.evaluate(status=>{state.sensitivity.setBusy(true);state.sensitivity.progress(status);window.testActivity=WingActivity.begin('Sensitivity',WingActivity.phase(status.progress,{sensitivity:true}));},fixture.cached);
  const cached=await page.evaluate(()=>({text:document.getElementById('sensitivity-status').textContent,category:document.getElementById('activity-status').dataset.category,color:getComputedStyle(document.getElementById('activity-status')).backgroundColor,textColor:getComputedStyle(document.getElementById('sensitivity-status')).color}));
  assert.match(cached.text,/12 s$/);assert(!/12\.\d/.test(cached.text));assert.equal(cached.category,'loading');assert.equal(cached.color,'rgb(22, 79, 145)');
  const rgb=cached.textColor.match(/[\d.]+/g).map(Number);assert(rgb[2]>rgb[0],'normal running text stays blue');
  await page.screenshot({path:path.join(out,'cached-solver-loading-blue-integer-seconds.png')});checks.push('Actual worker helper cached-load progress is blue and uses integer elapsed seconds; its timing category remains preparation.');
  await page.evaluate(status=>{state.sensitivity.progress(status);WingActivity.update(testActivity,WingActivity.phase(status.progress,{sensitivity:true}));},fixture.operators);
  assert.equal(await page.locator('#activity-status').getAttribute('data-category'),'numerical');
  await page.evaluate(()=>{state.sensitivity.setBusy(false);state.sensitivity.error('Expected regression failure: singular tangent matrix');WingActivity.end(testActivity,{outcome:'error',message:'Expected regression failure: singular tangent matrix'});});
  assert.equal(await page.locator('#activity-status').getAttribute('data-state'),'error');await page.locator('#activity-dismiss').click();assert(await page.locator('#activity-status').isHidden());
  assert(await page.locator('#sensitivity-error').isVisible());await page.evaluate(()=>state.sensitivity.error(''));checks.push('Actual errors remain red; dismissing the terminal activity notice leaves the error details available.');
  await page.evaluate(()=>activateWorkspaceTab('displaymass'));
  await page.locator('#show-structural-inertia').check();
  const mass=await page.evaluate(()=>({groups:state.data.weights.structural_inertia.length,meshes:state.structuralMassDisplay.meshes.filter(m=>m.isEnabled()).length,status:document.getElementById('structural-mass-status').textContent}));
  assert(mass.groups>0&&mass.meshes>0);assert.match(mass.status,/structural property groups/);await page.screenshot({path:path.join(out,'structural-mass-ellipsoids.png')});checks.push('Generated structural mass groups render enabled ellipsoid glyphs with a mass summary.');
  await page.locator('#show-structural-inertia').uncheck();
  await page.evaluate(()=>activateWorkspaceTab('displayenvironment'));await page.locator('#show-ground-plane').check();
  await page.locator('#ground-plane-z').fill('-1');await page.locator('#ground-plane-z').press('Tab');
  await page.getByRole('button',{name:'Isometric view',exact:true}).click();
  await page.waitForTimeout(500);await page.screenshot({path:path.join(out,'ground-shadows-off.png')});
  await page.getByLabel('Shadows',{exact:true}).check();await page.getByLabel('Self shadows',{exact:true}).check();
  await page.waitForTimeout(500);
  const shadows=await page.evaluate(()=>({settings:state.sceneLighting.capture(),receiver:state.scene.meshes.some(m=>m.metadata?.groundShadow&&m.isEnabled()),self:state.scene.meshes.filter(m=>m.metadata?.feGroup&&m.receiveShadows).length}));
  assert(shadows.settings.shadows&&shadows.settings.selfShadows);assert(shadows.receiver&&shadows.self>0);
  await page.screenshot({path:path.join(out,'ground-and-self-shadows.png')});checks.push('Ground shadow receiver and structural self-shadow recipients are enabled through the Environment controls.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,pickedNode,pickedElement,mass,shadows,errors},null,2));console.log(checks.join('\n'));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
