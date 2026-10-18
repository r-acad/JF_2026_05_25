'use strict';
// Exercise the real app, Babylon ray picking and Chromium mouse events. Verify
// the initial surface point's projection, rather than only camera deltas.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'C:/Program Files/Google/Chrome/Application/chrome.exe',args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1500,height:1000},deviceScaleFactor:1.5}),errors=[],checks=[];page.on('pageerror',e=>errors.push(e.stack));
 try{
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43980/**',route=>{const name=new URL(route.request().url()).pathname;return route.fulfill(name.endsWith('.js')?{contentType:'application/javascript',body:fs.readFileSync(path.join(web,name),'utf8')}:{contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')});});
  await page.goto('http://127.0.0.1:43980/');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:app.slice(0,app.indexOf('(async function start()'))});
  await page.evaluate(()=>{
   initScene();state.engine.stopRenderLoop();state.bbox={min:[-2,-2,-2],max:[2,2,2]};state.diag=7;
   const sphere=BABYLON.MeshBuilder.CreateSphere('pan-target',{diameter:2,segments:24},state.scene);sphere.material=shellMaterial('pan-material','#86bed6',1);sphere.isPickable=true;
   document.getElementById('splash').hidden=true;document.getElementById('activity-status').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;setBusy(false);activateWorkspaceTab('display');
   window.frame=async(n=4)=>{state.engine.resize();for(let i=0;i<n;i++){state.scene.render();await new Promise(requestAnimationFrame);}};
   window.pose=()=>({alpha:state.camera.alpha,beta:state.camera.beta,radius:state.camera.radius,target:state.camera.target.asArray(),pan:state.cursorPan.active});
   window.reset=async({parallel,scale=1,depth=0})=>{
    state.diag=7*scale;state.bbox={min:[-2,-2,-2].map(x=>x*scale),max:[2,2,2].map(x=>x*scale)};
    WingViewportTools.stopMotion(state.camera);state.viewportTools.projection(parallel);state.camera.alpha=-.7;state.camera.beta=1;state.camera.radius=12*scale;state.camera.lowerRadiusLimit=.00001*scale;state.camera.minZ=.001*scale;state.camera.maxZ=100*scale;
    state.camera.setTarget(BABYLON.Vector3.Zero(),false,true,true);state.viewportTools.fit();state.camera.getViewMatrix(true);
    sphere.scaling.setAll(scale);sphere.position.copyFrom(state.camera.getForwardRay().direction.scale(depth*scale)).addInPlace(new BABYLON.Vector3(scale,.4*scale,0));await frame();return project(sphere.position);
   };
   window.project=point=>{
    const rect=document.getElementById('render').getBoundingClientRect(),viewport=state.camera.viewport.toGlobal(state.engine.getRenderWidth(),state.engine.getRenderHeight());
    const p=BABYLON.Vector3.Project(point,BABYLON.Matrix.IdentityReadOnly,state.camera.getViewMatrix(true).multiply(state.camera.getProjectionMatrix(true)),viewport);
    return{x:rect.left+p.x*rect.width/state.engine.getRenderWidth(),y:rect.top+p.y*rect.height/state.engine.getRenderHeight()};
   };
   window.pickAt=({x,y})=>{
    const rect=document.getElementById('render').getBoundingClientRect(),factor=state.engine.getHardwareScalingLevel(),sx=(x-rect.left)*state.engine.getRenderWidth()*factor/rect.width,sy=(y-rect.top)*state.engine.getRenderHeight()*factor/rect.height;
    const hit=state.scene.pick(sx,sy,m=>m.name==='pan-target',false,state.camera);
    if(hit?.hit)window.anchor=hit.pickedPoint.clone();else{
     const ray=state.scene.createPickingRay(sx,sy,BABYLON.Matrix.IdentityReadOnly,state.camera),normal=state.camera.getForwardRay().direction;
     window.anchor=ray.origin.add(ray.direction.scale(BABYLON.Vector3.Dot(state.camera.target.subtract(ray.origin),normal)/BABYLON.Vector3.Dot(ray.direction,normal)));
    }
    return{hit:!!hit?.hit,position:anchor.asArray()};
   };
  });
  const pose=()=>page.evaluate(()=>pose());
  const lock=async(point,before)=>{
   await page.evaluate(()=>frame());const actual=await page.evaluate(()=>project(anchor)),after=await pose();
   assert(Math.hypot(actual.x-point.x,actual.y-point.y)<.25,JSON.stringify({point,actual,before,after}));
   for(const key of ['alpha','beta','radius'])assert(Math.abs(after[key]-before[key])<1e-8*Math.max(1,before.radius),`${key} changed while panning`);
  };
  for(const parallel of [false,true])for(const scale of [.001,1,1000])for(const depth of [-5,5]){
   const start=await page.evaluate(args=>reset(args),{parallel,scale,depth}),before=await pose();assert((await page.evaluate(p=>pickAt(p),start)).hit);
   await page.mouse.move(start.x,start.y);await page.mouse.down({button:'right'});assert((await pose()).pan);
   for(const delta of [[37,25],[-28,-19],[63,-33]]){const next={x:start.x+delta[0],y:start.y+delta[1]};await page.mouse.move(next.x,next.y,{steps:4});await lock(next,before);}
   await page.mouse.up({button:'right'});const released=await pose();await page.evaluate(()=>frame(12));assert.deepEqual(await pose(),{...released,pan:false});
  }
  checks.push('Picked near/far surface points track the cursor within 0.25 CSS pixels in perspective and orthographic views, at metre, millimetre and kilometre scales, with no inertial drift');
  for(const parallel of [false,true]){
   await page.evaluate(args=>reset(args),{parallel});const rect=await page.locator('#render').boundingBox(),start={x:rect.x+35,y:rect.y+65},before=await pose();assert(!(await page.evaluate(p=>pickAt(p),start)).hit);
   await page.mouse.move(start.x,start.y);await page.mouse.down({button:'right'});const next={x:start.x+75,y:start.y+40};await page.mouse.move(next.x,next.y,{steps:4});await lock(next,before);await page.mouse.up({button:'right'});
  }
  checks.push('Empty-canvas drags use a view-facing plane through the current camera target');
  let start=await page.evaluate(args=>reset(args),{parallel:true,depth:-5}),before=await pose();assert((await page.evaluate(p=>pickAt(p),start)).hit);
  await page.mouse.move(start.x,start.y);await page.mouse.down({button:'right'});await page.setViewportSize({width:1300,height:900});await page.evaluate(()=>frame());let next={x:start.x-60,y:start.y-30};await page.mouse.move(next.x,next.y,{steps:4});await lock(next,before);await page.mouse.up({button:'right'});
  checks.push('An in-progress drag remains cursor-locked after resizing the viewport');
  await page.evaluate(()=>{state.engine.setHardwareScalingLevel(2);document.getElementById('render').style.transform='scale(.85)';document.getElementById('render').style.transformOrigin='top left';});
  start=await page.evaluate(args=>reset(args),{parallel:false,depth:3});before=await pose();assert((await page.evaluate(p=>pickAt(p),start)).hit);await page.mouse.move(start.x,start.y);await page.mouse.down({button:'right'});next={x:start.x+40,y:start.y-50};await page.mouse.move(next.x,next.y,{steps:4});await lock(next,before);await page.mouse.up({button:'right'});
  checks.push('Hardware scaling and CSS-scaled canvas coordinates are handled correctly');
  for(const cancellation of ['pointercancel','blur']){
   start=await page.evaluate(args=>reset(args),{parallel:false});await page.mouse.move(start.x,start.y);await page.mouse.down({button:'right'});await page.mouse.move(start.x+20,start.y+15);await page.evaluate(type=>window.dispatchEvent(type==='blur'?new Event(type):new PointerEvent(type,{pointerId:1,pointerType:'mouse'})),cancellation);assert(!(await pose()).pan);const cancelled=await pose();await page.mouse.move(start.x+60,start.y+50);await page.evaluate(()=>frame());assert.deepEqual(await pose(),cancelled);await page.mouse.up({button:'right'});
  }
  checks.push('Pointer cancellation and focus loss release pan without leaving camera input stuck');
  assert.deepEqual(errors,[]);await page.screenshot({path:path.join(out,'cursor-pan.png')});fs.writeFileSync(path.join(out,'cursor-pan-summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log('Cursor pan passed '+checks.length+' browser groups.');
 }catch(error){fs.writeFileSync(path.join(out,'cursor-pan-failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'cursor-pan-failure.png')});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
