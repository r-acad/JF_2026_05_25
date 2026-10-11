'use strict';
// Full app controls, native Chromium mouse-button chords and real Babylon
// camera inputs. No solver fixture or server is needed.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
const near=(a,b)=>assert(Math.abs(a-b)<1e-8,`${a} != ${b}`),samePose=(a,b)=>{near(a.alpha,b.alpha);near(a.beta,b.beta);a.target.forEach((x,i)=>near(x,b.target[i]));};
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'C:/Program Files/Google/Chrome/Application/chrome.exe',args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1500,height:1000}}),errors=[],checks=[];page.on('pageerror',e=>errors.push(e.stack));
 try{
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43979/**',route=>{const name=new URL(route.request().url()).pathname;return route.fulfill(name.endsWith('.js')?{contentType:'application/javascript',body:fs.readFileSync(path.join(web,name),'utf8')}:{contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')});});
  await page.goto('http://127.0.0.1:43979/');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:app.slice(0,app.indexOf('(async function start()'))});
  await page.evaluate(()=>{
   initScene();state.engine.stopRenderLoop();state.bbox={min:[-2,-2,-2],max:[2,2,2]};state.diag=7;
   const sphere=BABYLON.MeshBuilder.CreateSphere('click-target',{diameter:2},state.scene);sphere.position.set(1,0,0);sphere.material=shellMaterial('test-material','#86bed6',1);sphere.isPickable=true;
   state.baseline=Float32Array.of(1,0,0);state.nodeIds=Int32Array.of(901);
   document.getElementById('splash').hidden=true;document.getElementById('activity-status').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;setBusy(false);activateWorkspaceTab('display');
   window.frame=async(n=4)=>{state.engine.resize();for(let i=0;i<n;i++){state.scene.render();await new Promise(requestAnimationFrame);}};
   window.pose=()=>({alpha:state.camera.alpha,beta:state.camera.beta,radius:state.camera.radius,target:state.camera.target.asArray(),orthoTop:state.camera.orthoTop,active:state.catiaZoom.active});
   window.reset=async(parallel)=>{WingViewportTools.stopMotion(state.camera);state.camera.alpha=-.7;state.camera.beta=1;state.camera.radius=12;state.camera.setTarget(BABYLON.Vector3.Zero(),false,true,true);state.viewportTools.projection(parallel);await frame();};
   window.nodePoint=()=>{const rect=document.getElementById('render').getBoundingClientRect(),viewport=state.camera.viewport.toGlobal(state.engine.getRenderWidth(),state.engine.getRenderHeight()),p=BABYLON.Vector3.Project(new BABYLON.Vector3(1,0,0),BABYLON.Matrix.IdentityReadOnly,state.scene.getTransformMatrix(),viewport);return{x:rect.left+p.x*state.engine.getHardwareScalingLevel(),y:rect.top+p.y*state.engine.getHardwareScalingLevel()};};
  });
  const pose=()=>page.evaluate(()=>pose());
  for(const parallel of [false,true])for(const first of ['middle','right']){
   await page.evaluate(value=>reset(value),parallel);const before=await pose(),point=await page.evaluate(()=>nodePoint()),second=first==='middle'?'right':'middle';
   await page.mouse.move(point.x,point.y);await page.mouse.down({button:first});await page.mouse.down({button:second});await page.mouse.move(point.x+20,point.y-25,{steps:3});await page.evaluate(()=>frame());
   const armed=await pose();samePose(before,armed);near(before.radius,armed.radius);assert(armed.active,'Holding the chord only arms zoom');
   await page.mouse.up({button:'right'});await page.mouse.move(point.x+45,point.y-95,{steps:7});await page.evaluate(()=>frame());
   const zoom=await pose();samePose(before,zoom);assert(zoom.radius<before.radius*.7&&zoom.active);if(parallel)assert(zoom.orthoTop<before.orthoTop*.7);
   await page.mouse.move(point.x+70,point.y-25,{steps:7});await page.evaluate(()=>frame());const out=await pose();samePose(before,out);near(out.radius,before.radius);
   await page.mouse.up({button:'middle'});await page.evaluate(()=>frame());const after=await pose();samePose(out,after);near(out.radius,after.radius);assert(!after.active);
  }
  checks.push('CATIA chord only arms; releasing right while continuously holding middle zooms up/down in both projections and press orders, without pan, orbit or node recentering');
  for(const first of ['middle','right']){
   await page.evaluate(()=>reset(false));const before=await pose(),point=await page.evaluate(()=>nodePoint()),second=first==='middle'?'right':'middle';
   await page.mouse.move(point.x,point.y);await page.mouse.down({button:first});await page.mouse.down({button:second});await page.mouse.up({button:'middle'});await page.mouse.move(point.x+40,point.y+35,{steps:3});await page.evaluate(()=>frame());
   const cancelled=await pose();samePose(before,cancelled);near(before.radius,cancelled.radius);assert(cancelled.active,'Residual right button remains swallowed');
   await page.mouse.down({button:'middle'});await page.mouse.up({button:'right'});await page.mouse.move(point.x+65,point.y-40,{steps:4});await page.evaluate(()=>frame());const repeated=await pose();samePose(before,repeated);near(before.radius,repeated.radius);
   await page.mouse.up({button:'middle'});await page.evaluate(()=>frame());assert(!(await pose()).active);
  }
  checks.push('Releasing middle first cancels; pressing it again without ending the chord cannot rearm or cause pan/orbit/centering');
  for(const button of ['left','right']){
   await page.evaluate(()=>reset(false));const before=await pose(),point=await page.evaluate(()=>nodePoint());await page.mouse.move(point.x,point.y);await page.mouse.down({button});await page.mouse.move(point.x+50,point.y+30,{steps:5});await page.evaluate(()=>frame());await page.mouse.up({button});await page.evaluate(()=>frame());const after=await pose();
   if(button==='left'){assert(Math.abs(after.alpha-before.alpha)>1e-3);before.target.forEach((x,i)=>near(x,after.target[i]));}
   else{near(after.alpha,before.alpha);near(after.beta,before.beta);assert(after.target.some((x,i)=>Math.abs(x-before.target[i])>1e-3));}
  }
  checks.push('Normal left orbit and right pan still work after repeated CATIA chords');
  await page.evaluate(()=>reset(false));let point=await page.evaluate(()=>nodePoint()),before=await pose();await page.mouse.click(point.x,point.y,{button:'middle'});await page.evaluate(()=>frame());let after=await pose();near(before.alpha,after.alpha);near(before.beta,after.beta);near(before.radius,after.radius);assert(after.target.every((v,i)=>Math.abs(v-[1,0,0][i])<1e-8),JSON.stringify({before,after,other:await page.evaluate(()=>({ipx:state.camera.inertialPanningX,ipy:state.camera.inertialPanningY,log:document.getElementById('log').textContent}))}));
  await page.evaluate(()=>reset(false));point=await page.evaluate(()=>nodePoint());before=await pose();await page.mouse.click(point.x,point.y);await page.evaluate(()=>frame());after=await pose();near(before.alpha,after.alpha);near(before.beta,after.beta);near(before.radius,after.radius);assert(after.target.some(x=>Math.abs(x)>1e-3));
  checks.push('Ordinary middle node-centering and left surface-centering preserve the camera frame');
  await page.evaluate(()=>reset(false));point=await page.evaluate(()=>nodePoint());await page.mouse.move(point.x,point.y);await page.mouse.down({button:'middle'});await page.mouse.down({button:'right'});await page.mouse.move(point.x,point.y+50);await page.evaluate(()=>window.dispatchEvent(new Event('blur')));assert.equal((await pose()).active,false);await page.mouse.up({button:'right'});await page.mouse.up({button:'middle'});
  checks.push('Focus loss safely cancels the chord and reattaches normal pointer controls');
  assert.deepEqual(errors,[]);await page.screenshot({path:path.join(out,'catia-camera.png')});fs.writeFileSync(path.join(out,'catia-summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log('CATIA camera passed '+checks.length+' browser groups.');
 }catch(error){fs.writeFileSync(path.join(out,'catia-failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'catia-failure.png')});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
