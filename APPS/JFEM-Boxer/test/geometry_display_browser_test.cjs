"use strict";
// Display-only regression using completed mesh fixtures and real Babylon meshes.
// node geometry_display_browser_test.cjs <fixture-dir> <evidence-dir> [playwright-module]
// Fixture: schema.json and payload.msgpack (gaps_ prefixes also accepted),
// with a wet fuel tank, rib datum metadata and at least two airfoil sections.
// CHROME_PATH optionally selects a browser executable; otherwise use Playwright Chromium.
const fs=require("node:fs"),path=require("node:path"),assert=require("node:assert/strict");
if(!process.argv[2]||!process.argv[3])throw Error("Usage: node geometry_display_browser_test.cjs <fixture-dir> <evidence-dir> [playwright-module]");
const web=path.resolve(__dirname,"../web"),fixture=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]);
const fixtureFile=name=>{const file=path.join(fixture,name);return fs.existsSync(file)?file:path.join(fixture,"gaps_"+name);};
const {chromium}=require(process.argv[4]||"playwright");
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],requests=[];
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:["--use-angle=swiftshader","--enable-unsafe-swiftshader"]});
 const page=await browser.newPage({viewport:{width:1550,height:1050}});page.on("pageerror",e=>errors.push(e.stack));
 try{
  const html=fs.readFileSync(path.join(web,"index.html"),"utf8");
  await page.route("http://127.0.0.1:43997/**",async route=>{
   const url=new URL(route.request().url());if(url.pathname.startsWith("/api/")){requests.push(url.pathname);throw Error("Display checks must not request an analysis or model rebuild: "+url.pathname);}
   return url.pathname==="/"?route.fulfill({contentType:"text/html",body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,"").replace(/<link\b[^>]*>/g,"")}):route.fulfill({path:path.join(web,url.pathname)});
  });
  await page.goto("http://127.0.0.1:43997/");
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=="app.js")await page.addScriptTag({path:path.join(web,file)});
  const source=fs.readFileSync(path.join(web,"app.js"),"utf8");await page.addScriptTag({content:source.slice(0,source.indexOf("(async function start()"))});
  await page.evaluate(async({bytes,schema})=>{
   initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.defaults=schema.defaults;state.data=MessagePack.decode(Uint8Array.from(bytes));state.values=state.data.model_params;
   state.autoMeshEnabled=false;document.getElementById("auto-mesh").checked=false;buildForm(state.schema,state.values);buildModel(state.data);state.modelSignature=formSignature();setModelDirty(false);setBusy(false);
   document.getElementById("splash").hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;meshStatus("Geometry display fixture ready","current");
   window.frame=async()=>{state.engine.resize();await state.scene.whenReadyAsync();state.scene.render();await new Promise(requestAnimationFrame);};
   window.materialInfo=key=>{const mesh=state.layers.get(key).meshes[0],m=mesh.material;return{className:m.getClassName(),color:(m.albedoColor||m.diffuseColor).toHexString().toLowerCase(),alpha:m.alpha,wireframe:m.wireframe,vertexColors:mesh.useVertexColors,metallic:m.metallic,enabled:mesh.isEnabled()};};
   window.beforeDefinition=formSignature();window.beforeCoordinates=Array.from(state.baseline);activateWorkspaceTab("displaygeometry");await frame();
  },{bytes:[...fs.readFileSync(fixtureFile("payload.msgpack"))],schema:JSON.parse(fs.readFileSync(fixtureFile("schema.json"),"utf8"))});
  assert(await page.locator("#panel-displaygeometry").isVisible());
  for(const id of ["entity-group-aerodynamics","entity-group-overlays","show-rib-datums","rib-datum-size","show-undeformed","undeformed-color","show-reference-aero","show-deformed-aero"])
   assert.equal(await page.locator('#'+id).evaluate(el=>el.closest('#panel-displaygeometry')?.id),"panel-displaygeometry",id+" must be inside Geometry");
  assert.equal(await page.locator("#tab-reference").count(),0);
  assert.equal(await page.locator("#layer-REFERENCE_AERO").count(),0);
  assert(await page.locator("#show-reference-aero").isHidden());
  assert.equal(await page.locator('#panel-displaygeometry label:visible').evaluateAll(labels=>labels.filter(label=>/^Undeformed aero\s*·/.test(label.textContent.trim())).length),1);
  await page.evaluate(()=>activateWorkspaceTab("reference"));assert.equal(await page.evaluate(()=>workspaceUI.activeTab),"displayreference");assert.equal(await page.locator("#reference-panel").evaluate(el=>el.closest("[data-workspace-panel]").dataset.workspacePanel),"displayreference");assert(await page.locator("#reference-panel").isVisible());
  assert((await page.locator('#reference-panel input[type="file"]').count())>0);
  checks.push("Geometry contains aerodynamic/context groups and structural references; the former Reference tab opens the dedicated Reference Geometry controls");
  const stl="solid reference\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex .4 0 0\nvertex 0 .4 0\nendloop\nendfacet\nendsolid reference";
  await page.locator("#reference-file").setInputFiles({name:"geometry-reference.stl",mimeType:"model/stl",buffer:Buffer.from(stl)});
  await page.waitForFunction(()=>state.reference.entries.length===1&&state.reference.loading===0);
  await page.locator('[data-geometry="REFERENCE_0"] input[type="color"]').evaluate(el=>{el.value="#c85f72";el.dispatchEvent(new Event("input",{bubbles:true}));});
  assert.equal(await page.evaluate(()=>state.reference.entries[0].material.diffuseColor.toHexString().toLowerCase()),"#c85f72");
  assert(await page.locator("#reference-visible").isHidden());assert(await page.locator("#reference-wireframe").isHidden());assert(await page.locator("#reference-opacity").isHidden());
  const referenceAppearance=page.locator('[data-geometry="REFERENCE_0"]');
  await referenceAppearance.locator('.geometry-visibility input').uncheck();assert.equal(await page.evaluate(()=>state.reference.entries[0].root.isEnabled()),false);await referenceAppearance.locator('.geometry-visibility input').check();
  await referenceAppearance.locator('.geometry-reference-wire input').check();await referenceAppearance.locator('input[type="range"]').evaluate(el=>{el.value=".42";el.dispatchEvent(new Event("input",{bubbles:true}));});
  assert(await page.evaluate(()=>state.reference.entries[0].material.wireframe));assert.equal(await page.evaluate(()=>state.reference.entries[0].material.alpha),.42);
  await page.evaluate(()=>{state.reference.setTransform({position:[10,20,30]});state.reference.setMode("off");});
  checks.push("A real local STL imports from Reference Geometry and has working color, visibility, wireframe and opacity controls");
  await page.evaluate(()=>activateWorkspaceTab("displaygeometry"));
  await page.locator("#layer-AIRFOIL_SECTIONS").check();
  const sectionCount=await page.evaluate(()=>state.aeroDisplay.sections.length);assert(sectionCount>=2);
  for(let i=0;i<sectionCount;i++){
   const host=page.locator(`[data-geometry="AIRFOIL_${i}"]`),toggle=host.locator('input[type="checkbox"]'),color=host.locator('input[type="color"]');
   assert(await host.isVisible());await toggle.uncheck();
   assert.equal(await page.evaluate(i=>state.aeroDisplay.meshes[i].isEnabled(),i),false);
   const hex=i%2?"#e38629":"#28b7e2";await color.evaluate((el,value)=>{el.value=value;el.dispatchEvent(new Event("input",{bubbles:true}));},hex);
   await toggle.check();assert.equal(await page.evaluate(i=>state.aeroDisplay.meshes[i].color.toHexString().toLowerCase(),i),hex);
  }
  const first=page.locator('[data-geometry="AIRFOIL_0"] input[type="checkbox"]');await first.uncheck();await page.locator("#layer-AIRFOIL_SECTIONS").uncheck();await page.locator("#layer-AIRFOIL_SECTIONS").check();
  assert.equal(await page.evaluate(()=>state.aeroDisplay.meshes[0].isEnabled()),false);assert.equal(await page.evaluate(()=>state.aeroDisplay.meshes[1].isEnabled()),true);
  await first.check();checks.push("Every defined airfoil has independent visibility/color, and group switches preserve each section's explicit hidden state");
  await page.evaluate(()=>{const disp=new Float32Array(state.baseline.length);for(let i=2;i<disp.length;i+=3)disp[i]=.01;state.results={matches:true,available:true,analysis:"SOL101",modes:[],contours:[],static:{disp,maxDisp:.01}};state.activeMode=-1;state.realScale=true;document.getElementById("animate").checked=false;applyDeformation();syncResultOverlays();buildLayerPanel();});
  assert(await page.locator("#show-reference-aero").isVisible());assert.equal(await page.locator("#layer-REFERENCE_AERO").count(),0);
  await page.locator("#show-deformed-aero").check();await page.locator("#show-reference-aero").check();await page.locator("#show-reference-aero").uncheck();
  assert(await page.evaluate(()=>state.layers.get("AERO_SURFACE").visible&&!state.layers.get("REFERENCE_AERO").visible));
  await page.locator("#show-reference-aero").check();await page.locator("#show-deformed-aero").uncheck();
  assert(await page.evaluate(()=>!state.layers.get("AERO_SURFACE").visible&&state.layers.get("REFERENCE_AERO").visible));
  checks.push("One visible undeformed-loft item remains without results; the single reference toggle appears with a displacement shape and controls its visibility independently");
  const styles=[];
  for(const[key,color]of [["FUEL_TANK","#21dbaa"],["REFERENCE_AERO","#a7b1ed"]]){
   const host=page.locator(`[data-geometry="${key}"]`);assert(await host.isVisible());assert(!(await host.isDisabled()));
   await host.locator('input[type="color"]').evaluate((el,value)=>{el.value=value;el.dispatchEvent(new Event("input",{bubbles:true}));},color);
   for(const style of ["wireframe","metallic","solid","translucent"]){
    await host.locator("select").selectOption(style);
    if(style==="translucent")await host.locator('input[type="range"]').evaluate(el=>{el.value=".37";el.dispatchEvent(new Event("input",{bubbles:true}));});
    const info=await page.evaluate(key=>materialInfo(key),key);styles.push({key,style,...info});assert.equal(info.color,color);assert.equal(info.wireframe,style==="wireframe");assert.equal(info.className,style==="metallic"?"PBRMaterial":"StandardMaterial");assert.equal(info.alpha,style==="translucent"?.37:1);if(style==="metallic")assert.equal(info.metallic,1);
   }
  }
  await page.locator("#show-reference-aero").check();await page.locator("#show-undeformed").check();
  await page.locator("#undeformed-color").evaluate(el=>{el.value="#d678c2";el.dispatchEvent(new Event("input",{bubbles:true}));});
  assert(await page.evaluate(()=>state.layers.get("UNDEFORMED").meshes.some(m=>m.isEnabled())));
  checks.push("Fuel and undeformed aerodynamic surfaces use real solid/wireframe/translucent/metallic materials and colors; structural reference controls remain usable in Geometry");
  await page.locator('#show-rib-datums').check();
  await page.evaluate(()=>activateWorkspaceTab('displayenvironment'));
  const lighting=page.locator('.scene-lighting-custom');assert.equal(await lighting.evaluate(el=>el.open),false);
  await page.locator('[aria-label="Lighting preset"]').selectOption('custom');assert.equal(await lighting.evaluate(el=>el.open),true);
  await page.locator('[aria-label="Ambient brightness"]').fill('.63');await page.locator('[aria-label="Ambient brightness"]').dispatchEvent('input');
  const customized=await page.evaluate(()=>state.sceneLighting.capture());assert.equal(customized.ambient,.63);assert.equal(customized.preset,'custom');
  await page.locator('[aria-label="Lighting preset"]').selectOption('balanced');
  checks.push("Lighting presets and shadows remain primary; selecting Custom exposes editable intensities without changing geometry");
  for(const id of ["show-ground-plane","show-symmetry-plane"])await page.locator('#'+id).check();
  await page.locator('[data-geometry="GROUND"] input[type="color"]').evaluate(el=>{el.value="#8098b1";el.dispatchEvent(new Event("input",{bubbles:true}));});
  const groundStyles=[];
  for(const style of["wireframe","translucent","solid","metallic"]){
   await page.locator('[data-geometry="GROUND"] select').selectOption(style);
   if(style==="translucent")await page.locator('[data-geometry="GROUND"] input[type="range"]').evaluate(el=>{el.value=".43";el.dispatchEvent(new Event("input",{bubbles:true}));});
   groundStyles.push(await page.evaluate(()=>({style:state.viewPlanes.groundAppearance.style,className:state.viewPlanes.meshes.ground.material.getClassName(),alpha:state.viewPlanes.meshes.ground.material.alpha,wireframe:state.viewPlanes.meshes.ground.material.wireframe})));
  }
  assert.deepEqual(groundStyles.map(v=>[v.style,v.className,v.alpha,v.wireframe]),[["wireframe","ShaderMaterial",1,false],["translucent","ShaderMaterial",.43,false],["solid","ShaderMaterial",1,false],["metallic","PBRMaterial",1,false]]);
  await page.locator("#ground-plane-z").fill("28.5");await page.locator("#ground-plane-z").dispatchEvent("change");
  await page.evaluate(async()=>{for(let i=0;i<4;i++)await frame();});
  assert(await page.evaluate(()=>state.viewPlanes.reflection.renderList.some(mesh=>state.data.groups.some(group=>state.layers.get(group.name)?.meshes.includes(mesh)))));
  checks.push("Ground Finish exposes all four working materials, retains opacity when switching, and its metallic render target includes the visible real FE model");
  await page.locator('[data-geometry="SYMMETRY"] select').selectOption("wireframe");
  await page.evaluate(()=>activateWorkspaceTab('displaygeometry'));
  await page.locator('[data-geometry="RIB_DATUMS"] input[type="color"]').evaluate(el=>{el.value="#dc8c36";el.dispatchEvent(new Event("input",{bubbles:true}));});
  const contexts=await page.evaluate(()=>({ground:state.viewPlanes.meshes.ground.isEnabled(),symmetry:state.viewPlanes.meshes.symmetry.isEnabled(),wireframe:state.viewPlanes.meshes.symmetry.material.wireframe,ribs:state.ribDatums.meshes.planes.isEnabled(),ribColor:state.ribDatums.meshes.planes.material.diffuseColor.toHexString().toLowerCase()}));
  assert(contexts.ground&&contexts.symmetry&&contexts.wireframe&&contexts.ribs);assert.equal(contexts.ribColor,"#dc8c36");
  const panelVisibility=await page.evaluate(()=>{const tracked=new Map(["FUEL_TANK","AIRFOIL_SECTIONS","AERO_SURFACE"].map(key=>[key,state.layers.get(key).meshes.slice()]));const read=()=>Object.fromEntries([...tracked].map(([key,meshes])=>[key,meshes.map(m=>m.isEnabled())]));const before=read();setPanelDisplay(true);const during=read();setPanelDisplay(false);return{before,during,after:read()};});
  assert.deepEqual(panelVisibility.during,panelVisibility.before);assert.deepEqual(panelVisibility.after,panelVisibility.before);
  const hiddenStructure=await page.evaluate(()=>{const checkbox=document.getElementById("geometry-show-structure");checkbox.checked=false;checkbox.dispatchEvent(new Event("change"));const shown=state.layers.get("FUEL_TANK").meshes.some(m=>m.isEnabled())&&state.aeroDisplay.meshes.every(m=>m.isEnabled());checkbox.checked=true;checkbox.dispatchEvent(new Event("change"));return shown;});assert(hiddenStructure);
  checks.push("Ground, symmetry and rib datum controls change their real helpers; panel isolation and structural hide/show preserve geometry visibility");
  await page.evaluate(()=>{state.camera.radius*=1.6;state.camera.target.y-=.8;document.getElementById("workspace-content").scrollTop=0;return frame();});await page.screenshot({path:path.join(out,"geometry-controls.png")});
  const saved=await page.evaluate(async()=>{const view=WingWorkspace.captureView(document,state,workspaceUI);const study=await WingWorkspace.snapshot(state.values,state.reference,view);window.portable=WingWorkspace.parse(JSON.stringify(study));return portable.data.view;});
  assert.equal(saved.geometryAppearance.FUEL_TANK.color,"#21dbaa");assert.equal(saved.geometryAppearance.REFERENCE_AERO.opacity,.37);
  assert.equal(saved.geometryAppearance.GROUND.style,"metallic");assert.equal(saved.geometryAppearance.GROUND.opacity,.43);assert.equal(saved.controls["ground-plane-z"],"28.5");
  const restored=await page.evaluate(saved=>{state.geometryAppearance={};state.geometryDisplay.apply();restoreWorkspaceView(saved);return{appearance:state.geometryAppearance,fuel:materialInfo("FUEL_TANK"),airfoil:state.aeroDisplay.meshes[0].color.toHexString().toLowerCase(),tab:workspaceUI.activeTab};},saved);
  assert.deepEqual(restored.appearance,saved.geometryAppearance);assert.equal(restored.fuel.color,"#21dbaa");assert.equal(restored.fuel.alpha,.37);assert.equal(restored.airfoil,"#28b7e2");assert.equal(restored.tab,"displaygeometry");
  assert.equal(await page.evaluate(()=>state.viewPlanes.meshes.ground.material.getClassName()),"PBRMaterial");assert.equal(await page.evaluate(()=>state.viewPlanes.layout.z),28.5);
  const referenceRestore=await page.evaluate(async()=>{const transaction=await state.reference.stagePortable(portable.items,portable.data.view.reference);transaction.commit();transaction.finalize();restoreWorkspaceView(portable.data.view);const entry=state.reference.entries[0];return{count:portable.data.references.length,color:entry.material.diffuseColor.toHexString().toLowerCase(),alpha:entry.material.alpha,wireframe:entry.material.wireframe,visible:entry.root.isEnabled(),triangles:entry.triangles};});
  assert.deepEqual(referenceRestore,{count:1,color:"#c85f72",alpha:.42,wireframe:true,visible:true,triangles:1});
  const reset=await page.evaluate(saved=>{const legacy=structuredClone(saved);delete legacy.geometryAppearance;legacy.workspace.activeTab="reference";restoreWorkspaceView(WingWorkspace.completeView(legacy,document));const clean={appearance:state.geometryAppearance,fuel:materialInfo("FUEL_TANK"),airfoil:state.aeroDisplay.meshes[0].color.toHexString().toLowerCase(),reference:state.reference.entries[0].material.diffuseColor.toHexString().toLowerCase(),ground:state.viewPlanes.groundAppearance,groundMaterial:state.viewPlanes.meshes.ground.material.getClassName(),tab:workspaceUI.activeTab};restoreWorkspaceView(saved);const reapplied=materialInfo("FUEL_TANK");restoreWorkspaceView(WingWorkspace.newModelView(document));return{clean,reapplied,importedReset:state.geometryAppearance};},saved);
  assert.deepEqual(reset.clean.appearance,{});assert.notEqual(reset.clean.fuel.color,"#21dbaa");assert.notEqual(reset.clean.airfoil,"#28b7e2");assert.equal(reset.clean.tab,"displayreference");assert.equal(reset.reapplied.color,"#21dbaa");assert.deepEqual(reset.importedReset,{});
  assert.notEqual(reset.clean.reference,"#c85f72");
  assert.deepEqual(reset.clean.ground,{color:"#bfccd7",style:"solid",opacity:1});assert.equal(reset.clean.groundMaterial,"ShaderMaterial");
  checks.push("Study snapshot/parse restores geometry appearance; legacy missing settings restore original colors, Reference selection migrates, and imported-deck defaults clear styles");
  await page.evaluate(saved=>{restoreWorkspaceView(saved);activateWorkspaceTab("displaygeometry");document.getElementById("geometry-appearance-controls").scrollIntoView();},saved);await page.evaluate(()=>frame());await page.screenshot({path:path.join(out,"geometry-appearance.png")});
  const compact=await page.evaluate(()=>{
   const ids=["show-deformed-aero","show-reference-aero","show-rib-datums","rib-datum-size","show-undeformed","undeformed-color","aero-deformed-style","aero-surface-color","show-ground-plane","show-symmetry-plane","ground-plane-z","ground-grid-spacing","view-planes-note"],original=new Map(ids.map(id=>[id,document.getElementById(id)]));
   for(let i=0;i<4;i++)state.geometryDisplay.rebuild();
   const stable=ids.every(id=>document.getElementById(id)===original.get(id)&&document.querySelectorAll('[id="'+id+'"]').length===1);
   const oldFuel=document.getElementById("layer-FUEL_TANK");buildLayerPanel();
   const afterLayerRebuild=ids.every(id=>document.getElementById(id)===original.get(id)&&document.querySelectorAll('[id="'+id+'"]').length===1);
   const fuel=document.getElementById("layer-FUEL_TANK"),airfoil=document.getElementById("layer-AIRFOIL_SECTIONS");
   return{stable,afterLayerRebuild,freshFuel:!oldFuel.isConnected&&fuel!==oldFuel,fuelAdjacent:fuel.closest('[data-geometry="FUEL_TANK"]')?.querySelectorAll('input[type=color],select').length===2,ribAdjacent:document.getElementById("show-rib-datums").closest('[data-geometry="RIB_DATUMS"]')?.contains(document.getElementById("rib-datum-size")),aeroAdjacent:document.getElementById("aerodynamic-appearance").contains(document.getElementById("show-deformed-aero")),airfoilGrouped:airfoil.closest("#geometry-airfoil-appearance")!==null,captions:["aero-surface-color","aero-deformed-style"].map(id=>{const row=document.getElementById(id).closest("label");return row.querySelectorAll(".geometry-control-caption").length;}),environmentSeparated:document.querySelector('[data-geometry="GROUND"]').closest("#panel-displayenvironment")!==null};
  });
  assert(compact.stable&&compact.afterLayerRebuild&&compact.freshFuel&&compact.fuelAdjacent&&compact.ribAdjacent&&compact.aeroAdjacent&&compact.airfoilGrouped&&compact.environmentSeparated,JSON.stringify(compact));assert.deepEqual(compact.captions,[1,1]);
  checks.push("Compact cards colocate canonical visibility and appearance; four appearance rebuilds and a full layer-list rebuild retain unique permanent nodes and use fresh dynamic layer controls");
  const environmentGrouped=await page.evaluate(()=>({ground:['show-ground-plane','ground-plane-z','ground-grid-spacing','view-planes-note'].every(id=>document.getElementById(id).closest('[data-geometry="GROUND"]')),symmetry:!!document.getElementById('show-symmetry-plane').closest('[data-geometry="SYMMETRY"]'),oldGroupHidden:document.getElementById('display-view-planes').hidden,groundHeight:document.getElementById('ground-plane-z').value}));
  assert(environmentGrouped.ground&&environmentGrouped.symmetry&&environmentGrouped.oldGroupHidden);assert.equal(environmentGrouped.groundHeight,'28.5');
  checks.push("Ground and symmetry each have one card containing visibility and appearance; ground location survives repeated rebuilds and Study restore");
  await page.evaluate(()=>activateWorkspaceTab("displayreference"));
  const referenceCard=page.locator('[data-geometry="REFERENCE_0"]'),activeBefore=await page.evaluate(()=>state.reference.active.id);
  await referenceCard.getByRole('button',{name:'Position and scale',exact:true}).click();assert.equal(await page.locator('#geometry-reference-placement').evaluate(el=>el.open),true);
  assert.equal(await page.locator('#reference-position-x').inputValue(),'10');assert.equal(await page.evaluate(()=>state.reference.active.id),activeBefore);
  await referenceCard.locator('.geometry-visibility input').uncheck();assert.equal(await page.evaluate(()=>state.reference.entries[0].root.isEnabled()),false);await referenceCard.locator('.geometry-visibility input').check();
  await referenceCard.locator('.geometry-reference-wire input').uncheck();assert.equal(await page.evaluate(()=>state.reference.entries[0].material.wireframe),false);await referenceCard.locator('.geometry-reference-wire input').check();
  await referenceCard.locator('input[type=range]').evaluate(el=>{el.value=".31";el.dispatchEvent(new Event("input",{bubbles:true}));});assert.equal(await page.evaluate(()=>state.reference.entries[0].material.alpha),.31);
  await referenceCard.locator('input[type=range]').evaluate(el=>{el.value=".42";el.dispatchEvent(new Event("input",{bubbles:true}));});assert.equal(await page.evaluate(()=>state.reference.active.id),activeBefore);assert.equal(await page.locator("#reference-opacity").inputValue(),"0.42");
  checks.push("Per-reference compact visibility, wireframe and opacity operate through the real reference API and retain selected placement controls");
  await page.evaluate(()=>{activateWorkspaceTab("displaygeometry");setPaneWidth(300);state.geometryDisplay.compact();});await page.evaluate(()=>frame());
  const narrow=await page.locator('#panel-displaygeometry .geometry-entity-card').evaluateAll(cards=>cards.map(card=>({key:card.dataset.geometry,inside:card.scrollWidth<=card.clientWidth+1})));assert(narrow.length&&narrow.every(row=>row.inside),JSON.stringify(narrow));
  await page.screenshot({path:path.join(out,"geometry-compact-narrow.png")});checks.push("Compact controls fit a300px pane without horizontal overflow and keep full entity names accessible");
  const unchanged=await page.evaluate(()=>({sameDefinition:formSignature()===beforeDefinition,sameCoordinates:Array.from(state.baseline).every((v,i)=>v===beforeCoordinates[i])}));assert(unchanged.sameDefinition&&unchanged.sameCoordinates);assert.deepEqual(requests,[]);assert.deepEqual(errors,[]);
  checks.push("All display operations leave canonical model parameters and FE coordinates unchanged and request no solver/model work");
  fs.writeFileSync(path.join(out,"summary.json"),JSON.stringify({passed:true,checks,sectionCount,styles,groundStyles,contexts,panelVisibility,restored,referenceRestore,reset,compact,narrow,unchanged,errors,requests},null,2));console.log(`Geometry display browser: ${checks.length} groups passed.`);
 }catch(error){fs.writeFileSync(path.join(out,"failure.json"),JSON.stringify({error:error.stack,checks,errors,requests},null,2));await page.screenshot({path:path.join(out,"failure.png")});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
