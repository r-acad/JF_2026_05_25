"use strict";
// node ground_reflection_browser_test.cjs <evidence-dir> [playwright-module]
// Fixture-free WebGL check. CHROME_PATH optionally selects a browser executable.
const fs=require("node:fs"),path=require("node:path"),assert=require("node:assert/strict");
if(!process.argv[2])throw Error("Usage: node ground_reflection_browser_test.cjs <evidence-dir> [playwright-module]");
const out=path.resolve(process.argv[2]),web=path.resolve(__dirname,"../web"),{chromium}=require(process.argv[3]||"playwright");
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],checks=[];
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:["--use-angle=swiftshader","--enable-unsafe-swiftshader"]});
 const page=await browser.newPage({viewport:{width:1100,height:820}});page.on("pageerror",e=>errors.push(e.stack));
 try{
  await page.setContent('<!doctype html><html><body style="margin:0;background:#101c28;color:white;font:16px system-ui"><p style="position:absolute;top:8px;left:16px;z-index:2">Metallic ground · reflection of current scene geometry</p><canvas id="view" style="display:block;width:1100px;height:820px"></canvas></body></html>');
  for(const file of ["vendor/babylon.js","view_planes.js"])await page.addScriptTag({path:path.join(web,file)});
  await page.evaluate(async()=>{
   window.engine=new BABYLON.Engine(document.getElementById("view"),true,{preserveDrawingBuffer:true});window.scene=new BABYLON.Scene(engine);scene.useRightHandedSystem=true;scene.clearColor=new BABYLON.Color4(.025,.035,.055,1);
   window.camera=new BABYLON.ArcRotateCamera("camera",-Math.PI/3,1.13,11,new BABYLON.Vector3(0,1,0),scene);camera.minZ=.05;scene.activeCamera=camera;
   const light=new BABYLON.HemisphericLight("light",new BABYLON.Vector3(0,1,0),scene);light.intensity=.95;
   window.above=BABYLON.MeshBuilder.CreateBox("model-red-above",{width:1.8,height:1.3,depth:.9},scene);above.position.copyFromFloats(-.8,2,.25);above.material=new BABYLON.StandardMaterial("red",scene);above.material.diffuseColor=new BABYLON.Color3(.95,.035,.02);above.material.emissiveColor=new BABYLON.Color3(.25,.005,.005);
   window.below=BABYLON.MeshBuilder.CreateBox("model-blue-below",{width:1.2,height:1.1,depth:1.2},scene);below.position.copyFromFloats(1,-2,0);below.material=new BABYLON.StandardMaterial("blue",scene);below.material.diffuseColor=new BABYLON.Color3(.015,.08,.95);below.material.emissiveColor=new BABYLON.Color3(.005,.02,.3);below.isVisible=false;
   window.helper=BABYLON.MeshBuilder.CreateBox("excluded-helper",{size:.7},scene);helper.position.copyFromFloats(1.5,1.4,-1);helper.metadata={wingViewHelper:true};helper.material=new BABYLON.StandardMaterial("helper",scene);helper.material.diffuseColor=new BABYLON.Color3(0,1,0);helper.material.emissiveColor=new BABYLON.Color3(0,.6,0);
   window.planes=WingViewPlanes.create({scene});planes.update({bbox:{min:[-3,-3,-3],max:[3,3,3]}},{z:0,spacing:1});planes.setVisible(true,false);planes.setGroundAppearance({color:"#e3e9ee",style:"metallic",opacity:.4});
   window.frames=0;planes.reflection.onBeforeRenderObservable.add(()=>frames++);
   window.render=async(n=6)=>{for(let i=0;i<n;i++){scene.render();await new Promise(requestAnimationFrame);}};
   window.stats=async()=>{const pixels=await planes.reflection.readPixels();let red=0,blue=0,green=0;for(let i=0;i<pixels.length;i+=4){if(pixels[i]>60&&pixels[i]>pixels[i+1]*1.8&&pixels[i]>pixels[i+2]*1.8)red++;if(pixels[i+2]>60&&pixels[i+2]>pixels[i]*1.8&&pixels[i+2]>pixels[i+1]*1.8)blue++;if(pixels[i+1]>60&&pixels[i+1]>pixels[i]*1.8&&pixels[i+1]>pixels[i+2]*1.8)green++;}return{red,blue,green,plane:planes.reflection.mirrorPlane.asArray(),renderList:planes.reflection.renderList.map(m=>m.name),frames,size:planes.reflection.getSize()};};
   await render();
  });
  const initial=await page.evaluate(()=>stats());assert(initial.red>200,JSON.stringify(initial));assert.equal(initial.green,0);assert(!initial.renderList.includes("view-plane-ground"));assert(!initial.renderList.includes("excluded-helper"));assert.deepEqual(initial.size,{width:512,height:512});
  const visibleReflection=await page.evaluate(async()=>{const reflected=above.position.clone();reflected.y=-reflected.y;const viewport=camera.viewport.toGlobal(engine.getRenderWidth(),engine.getRenderHeight()),pixel=BABYLON.Vector3.Project(reflected,BABYLON.Matrix.Identity(),scene.getTransformMatrix(),viewport);const rgba=await engine.readPixels(Math.round(pixel.x),engine.getRenderHeight()-Math.round(pixel.y),1,1);return{point:pixel.asArray(),rgba:[...rgba]};});
  assert(visibleReflection.rgba[0]>visibleReflection.rgba[1]*1.5&&visibleReflection.rgba[0]>visibleReflection.rgba[2]*1.5,JSON.stringify(visibleReflection));
  await page.screenshot({path:path.join(out,"metallic-ground-above.png")});
  checks.push("The bounded mirror texture and projected onscreen reflection contain the actual red model; ground and green helpers never reflect themselves");
  const hidden=await page.evaluate(async()=>{above.setEnabled(false);await render();const hidden=await stats();above.setEnabled(true);await render();return hidden;});assert.equal(hidden.red,0);
  checks.push("Hiding real model geometry immediately removes it from the reflection");
  const underside=await page.evaluate(async()=>{below.isVisible=true;camera.beta=Math.PI-1.13;camera.target.y=-1;await render();return stats();});assert(underside.blue>200,JSON.stringify(underside));assert.equal(underside.red,0);assert.deepEqual(underside.plane.map(v=>v||0),[0,1,0,0]);
  await page.screenshot({path:path.join(out,"metallic-ground-below.png")});
  const elevated=await page.evaluate(async()=>{planes.configure({z:3,spacing:1});await render();return stats();});assert(elevated.red>50,JSON.stringify(elevated));assert.deepEqual(elevated.plane,[0,1,0,-3]);
  checks.push("Clipping reverses correctly below the mirror and moving ground Z moves its reflection plane without rebuilding the model");
  const finishes=await page.evaluate(async()=>{const values=[];for(const style of["solid","wireframe","translucent","metallic"]){planes.setGroundAppearance({style,color:"#7099bd",opacity:.31});await render(2);const m=planes.meshes.ground.material;values.push({style,className:m.getClassName(),alpha:m.alpha,wireframe:m.wireframe});}const material=planes.meshes.ground.material,texture=planes.reflection;for(let i=0;i<12;i++){planes.setGroundAppearance({style:"solid"});planes.setGroundAppearance({style:"metallic"});}const resources={sameMaterial:material===planes.meshes.ground.material,sameTexture:texture===planes.reflection,mirrors:scene.textures.filter(t=>t.name==="view-ground-reflection").length};planes.setVisible(false,false);const before=frames;await render(3);return{values,resources,hiddenRenderCount:frames-before};});
  assert.deepEqual(finishes.values.map(v=>[v.style,v.className,v.alpha,v.wireframe]),[["solid","ShaderMaterial",1,false],["wireframe","ShaderMaterial",1,false],["translucent","ShaderMaterial",.31,false],["metallic","PBRMaterial",1,false]]);assert(finishes.resources.sameMaterial&&finishes.resources.sameTexture);assert.equal(finishes.resources.mirrors,1);assert.equal(finishes.hiddenRenderCount,0);
  const nonmetalRenderCount=await page.evaluate(async()=>{planes.setGroundAppearance({style:"solid"});planes.setVisible(true,false);const before=frames;await render(3);return frames-before;});assert.equal(nonmetalRenderCount,0);
  await page.evaluate(()=>{
   above.setEnabled(false);below.setEnabled(false);helper.setEnabled(false);planes.configure({z:0,spacing:1});camera.beta=.001;camera.alpha=0;camera.target.copyFromFloats(0,0,0);camera.mode=BABYLON.Camera.ORTHOGRAPHIC_CAMERA;camera.orthoLeft=-6;camera.orthoRight=6;camera.orthoTop=4.5;camera.orthoBottom=-4.5;
   window.gridPixel=async(x,z)=>{const pixel=BABYLON.Vector3.Project(new BABYLON.Vector3(x,0,z),BABYLON.Matrix.Identity(),scene.getTransformMatrix(),camera.viewport.toGlobal(engine.getRenderWidth(),engine.getRenderHeight()));const rgba=await engine.readPixels(Math.round(pixel.x)-1,engine.getRenderHeight()-Math.round(pixel.y)-1,3,3);let min=255,max=0;for(let i=0;i<rgba.length;i+=4){const brightness=(rgba[i]+rgba[i+1]+rgba[i+2])/3;min=Math.min(min,brightness);max=Math.max(max,brightness);}return{min,max};};
  });
  const grids=[];
  for(const style of['solid','wireframe','translucent']){
   const grid=await page.evaluate(async style=>{planes.setGroundAppearance({style,opacity:.35});await render();return{style,center:await gridPixel(.5,.5),line:await gridPixel(1,.5),vertices:planes.meshes.ground.getTotalVertices(),indices:planes.meshes.ground.getTotalIndices(),bounds:planes.layout.ground};},style);grids.push(grid);
   assert.equal(grid.vertices,4);assert.equal(grid.indices,6);assert.deepEqual(grid.bounds,grids[0].bounds);
   if(style==='wireframe'){assert(grid.center.max<25,JSON.stringify(grid));assert(grid.line.max>grid.center.max+50,JSON.stringify(grid));}
   else assert(grid.center.min>grid.line.min+8,JSON.stringify(grid));
   await page.screenshot({path:path.join(out,'ground-grid-'+style+'.png')});
  }
  const spacing=await page.evaluate(async()=>{planes.configure({z:0,spacing:2});planes.setGroundAppearance({style:'wireframe'});await render();const check={oldLine:await gridPixel(1,.5),newLine:await gridPixel(2,.5),bounds:planes.layout.ground};for(const value of[1e-30,1e30]){planes.configure({z:0,spacing:value});await render(2);if(planes.meshes.ground.getTotalVertices()!==4)throw Error('Grid must stay a single quad');}planes.configure({z:0,spacing:2});return check;});
  assert(spacing.oldLine.max<25);assert(spacing.newLine.max>spacing.oldLine.max+50);assert.deepEqual(spacing.bounds,grids[0].bounds);
  checks.push('Solid, wireframe and translucent use the same regularly spaced grid and extent; spacing changes do not create geometry, even at extreme finite values');
  const disposed=await page.evaluate(()=>{planes.dispose();return{ground:scene.meshes.filter(m=>m.name.startsWith("view-plane-")).length,mirrors:scene.textures.filter(t=>t.name==="view-ground-reflection").length};});assert.deepEqual(disposed,{ground:0,mirrors:0});
  checks.push("All finishes apply correctly, repeated switches reuse one material/texture, hiding the ground stops reflection renders, and disposal removes its resources");
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,"summary.json"),JSON.stringify({passed:true,checks,initial,visibleReflection,hidden,underside,elevated,finishes,nonmetalRenderCount,grids,spacing,disposed,errors},null,2));console.log(`Ground reflection: ${checks.length} browser groups passed.`);
 }catch(error){fs.writeFileSync(path.join(out,"failure.json"),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,"failure.png")});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
