"use strict";
// An already running fresh app server is required. No solver is started.
// node test/scene_lighting_browser_test.cjs URL EVIDENCE_DIR [PLAYWRIGHT_MODULE]
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const [url,out,modulePath='playwright']=process.argv.slice(2);
if(!url||!out)throw Error('Usage: node scene_lighting_browser_test.cjs URL EVIDENCE_DIR [PLAYWRIGHT_MODULE]');
const {chromium}=require(modulePath),checks=[],errors=[];fs.mkdirSync(out,{recursive:true});
(async()=>{const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});try{
 const page=await browser.newPage({viewport:{width:1440,height:1000}});page.setDefaultTimeout(120000);
 await page.route('**/favicon.ico',route=>route.fulfill({status:204}));
 page.on('pageerror',error=>errors.push(error.message));page.on('console',message=>{if(message.type()==='error')errors.push(message.text());});
 await page.goto(url);await page.getByRole('button',{name:'Start new study',exact:true}).click();
 await page.waitForFunction(()=>state.autoMeshReady&&state.data&&!state.workspaceBusy&&!state.loadingInput);
 await page.evaluate(()=>{activateWorkspaceTab('displayenvironment');document.getElementById('show-ground-plane').click();const z=document.getElementById('ground-plane-z');z.value=-1;z.dispatchEvent(new Event('change'));document.getElementById('view-iso').click();});
 for(const mode of ['solid','translucent'])for(const finish of ['solid','translucent','metallic']){
  await page.evaluate(({mode,finish})=>{const input=document.getElementById('surface-mode');input.value=mode;input.dispatchEvent(new Event('change'));const style=document.querySelector('[aria-label="Ground plane finish"]');style.value=finish;style.dispatchEvent(new Event('change'));const opacity=document.querySelector('[aria-label="Ground plane opacity"]');opacity.value=.65;opacity.dispatchEvent(new Event('input'));}, {mode,finish});
  await verify(mode+'-'+finish);
 }
 // An off-origin, rotated model and lower ground exercise the fitted light
 // range. Change projection as well; the shadow is world-space geometry.
 await verify('translucent-self-shadows',true);
 await page.evaluate(()=>{state.root.position.set(1.5,.7,-.4);state.root.rotation.y=.13;const z=document.getElementById('ground-plane-z');z.value=-1.7;z.dispatchEvent(new Event('change'));const style=document.querySelector('[aria-label="Ground plane finish"]');style.value='solid';style.dispatchEvent(new Event('change'));const camera=state.camera;camera.mode=BABYLON.Camera.ORTHOGRAPHIC_CAMERA;const half=camera.radius*Math.tan(camera.fov/2),ratio=state.engine.getAspectRatio(camera);camera.orthoTop=half;camera.orthoBottom=-half;camera.orthoLeft=-half*ratio;camera.orthoRight=half*ratio;});
 await verify('transformed-orthographic');
 await page.evaluate(()=>state.sceneLighting.apply({...state.sceneLighting.capture(),key:0}));
 await verify('zero-main-light',false,false);
 await page.evaluate(()=>{state.viewPlanes.setGroundAppearance({style:'wireframe'});state.sceneLighting.apply({...state.sceneLighting.capture(),key:.3});});await page.waitForTimeout(300);
 assert.equal(await page.evaluate(()=>state.scene.meshes.find(m=>m.metadata?.groundShadow).isEnabled()),false);checks.push({name:'Wireframe ground does not receive an opaque shadow patch'});
 assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'shadow-browser-summary.json'),JSON.stringify({passed:true,groups:checks.length,checks,errors},null,2));console.log(`Shadow browser passed ${checks.length} groups.`);
 async function verify(name,self=false,expectedShadow=true){
  await page.evaluate(()=>state.sceneLighting.apply({...state.sceneLighting.capture(),shadows:false,selfShadows:false}));await page.waitForTimeout(350);
  const off=await page.screenshot({path:path.join(out,name+'-off.png')});
  await page.evaluate(self=>state.sceneLighting.apply({...state.sceneLighting.capture(),shadows:!self,selfShadows:self}),self);await page.waitForTimeout(500);
  const points=await page.evaluate(self=>{
   const light=state.sceneLighting.lights[1],list=light.getShadowGenerator()?.getShadowMap().renderList||state.scene.meshes.filter(m=>m.metadata?.feGroup);
   if(list.some(m=>m.metadata?.nodeSelection||m.metadata?.supportGlyphs||m.metadata?.glyphs||m.metadata?.coordinateIds))throw Error('An annotation entered the shadow map');
   const meshes=list.filter(m=>m.isEnabled()&&m.isVisible&&['quad','tria'].includes(m.metadata?.feGroup?.kind));
   const centers=meshes.map(m=>m.getBoundingInfo().boundingBox.centerWorld).sort((a,b)=>a.x-b.x),ground=state.viewPlanes.meshes.ground.getBoundingInfo().boundingBox.centerWorld.y;
   const canvas=state.engine.getRenderingCanvas().getBoundingClientRect(),viewport=state.camera.viewport.toGlobal(state.engine.getRenderWidth(),state.engine.getRenderHeight());
   return [.15,.5,.85].map(fraction=>{const p=centers[Math.floor(fraction*(centers.length-1))],hit=self?p:p.add(light.direction.scale((ground-p.y)/light.direction.y)),screen=BABYLON.Vector3.Project(hit,BABYLON.Matrix.Identity(),state.scene.getTransformMatrix(),viewport);return{x:screen.x+canvas.left,y:screen.y+canvas.top};});
  },self);
  const on=await page.screenshot({path:path.join(out,name+'-on.png')});
  const counts=await page.evaluate(async({off,on,points})=>{
   async function pixels(base64){const image=new Image();image.src='data:image/png;base64,'+base64;await image.decode();const canvas=document.createElement('canvas');canvas.width=image.width;canvas.height=image.height;const context=canvas.getContext('2d');context.drawImage(image,0,0);return{width:canvas.width,height:canvas.height,data:context.getImageData(0,0,canvas.width,canvas.height).data};}
   const a=await pixels(off),b=await pixels(on);return points.map(point=>{let dark=0;for(let y=Math.round(point.y)-12;y<=point.y+12;y++)for(let x=Math.round(point.x)-12;x<=point.x+12;x++){if(x<0||y<0||x>=a.width||y>=a.height)continue;const i=4*(y*a.width+x),delta=(a.data[i]+a.data[i+1]+a.data[i+2]-b.data[i]-b.data[i+1]-b.data[i+2])/3;if(delta>1)dark++;}return dark;});
  },{off:off.toString('base64'),on:on.toString('base64'),points});
  assert(counts.every(value=>expectedShadow?value>10:value===0),`${name}: expected shadow=${expectedShadow} in all three span regions, got ${counts}`);checks.push({name,expected_shadow:expectedShadow,shadow_pixels_by_span_region:counts,points});
 }
}finally{await browser.close();}})().catch(error=>{fs.writeFileSync(path.join(out,'shadow-browser-failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));console.error(error);process.exitCode=1;});
