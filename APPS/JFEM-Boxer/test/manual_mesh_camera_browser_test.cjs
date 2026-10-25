'use strict';
// Real application regeneration: initial fit, manual button, G shortcut and
// explicit Fit. Run: node manual_mesh_camera_browser_test.cjs URL OUTPUT PLAYWRIGHT
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const [url,out,modulePath='playwright']=process.argv.slice(2);
if(!url||!out)throw Error('Expected application URL and evidence directory');
fs.mkdirSync(out,{recursive:true});
const {chromium}=require(modulePath);
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']});
 const page=await browser.newPage({viewport:{width:1600,height:1000}}),errors=[],checks=[];
 page.on('pageerror',e=>errors.push(e.message));
 const ready=()=>page.waitForFunction(()=>state.data?.nodes?.count&&!state.meshRequestInFlight&&!state.workspaceBusy&&!state.loadingInput&&!state.busy,null,{timeout:240000});
 const pose=()=>page.evaluate(()=>({alpha:state.camera.alpha,beta:state.camera.beta,radius:state.camera.radius,target:state.camera.target.asArray(),position:state.camera.position.asArray(),mode:state.camera.mode,ortho:[state.camera.orthoLeft,state.camera.orthoRight,state.camera.orthoTop,state.camera.orthoBottom]}));
 function same(a,b){for(const key of ['alpha','beta','radius'])assert(Math.abs(a[key]-b[key])<1e-9,key+' changed during regeneration');assert.equal(a.mode,b.mode);for(const key of ['target','position','ortho'])a[key].forEach((v,i)=>{if(v===null)assert.equal(b[key][i],null);else assert(Math.abs(v-b[key][i])<1e-8,key+' changed during regeneration');});}
 try{
  await page.goto(url,{waitUntil:'domcontentloaded',timeout:120000});await page.getByRole('button',{name:'Start new study',exact:true}).click();await ready();
  const initial=await page.evaluate(()=>({radius:state.camera.radius,diagonal:state.diag,baseline:state.baseline.length}));assert(initial.radius>0&&initial.diagonal>0&&initial.baseline>0);checks.push('First model is fitted');
  await page.evaluate(()=>{document.getElementById('auto-save').checked=false;state.autosave?.destroy();document.getElementById('auto-mesh').checked=false;autoMeshChanged();});
  for(const parallel of [false,true]){
   await page.evaluate(async parallel=>{const c=state.camera;WingViewportTools.stopMotion(c);state.viewportTools.projection(parallel);c.setTarget(c.target.add(new BABYLON.Vector3(.17,-.08,.11)),false,true,true);c.alpha=-.82;c.beta=1.17;c.radius=state.diag*.42;await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);},parallel);
   const before=await pose();
   const response=page.waitForResponse(r=>new URL(r.url()).pathname==='/api/generate'&&r.request().method()==='POST');await page.locator('#btn-create').click();assert((await response).ok());await ready();await page.evaluate(()=>new Promise(requestAnimationFrame));same(before,await pose());
   checks.push((parallel?'Orthographic':'Perspective')+' pose and zoom survive manual Create FEM');
  }
  // Change the actual geometry before using the keyboard regeneration path.
  await page.evaluate(()=>{const input=document.getElementById('p-planform.area');input.value=Number(input.value)*1.03;input.dispatchEvent(new Event('input',{bubbles:true}));});
  const before=await pose(),response=page.waitForResponse(r=>new URL(r.url()).pathname==='/api/generate'&&r.request().method()==='POST');await page.locator('#render').click({position:{x:30,y:30}});await page.keyboard.press('g');assert((await response).ok());await ready();await page.evaluate(()=>new Promise(requestAnimationFrame));same(before,await pose());checks.push('G regeneration preserves view after geometry edits');
  await page.evaluate(()=>fitView());await page.evaluate(()=>new Promise(requestAnimationFrame));const fitted=await pose();assert(Math.abs(fitted.radius-before.radius)>1e-5);checks.push('Explicit Fit still adjusts the camera');
  assert.deepEqual(errors,[]);await page.screenshot({path:path.join(out,'camera-regeneration.png')});fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,initial},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({message:error.stack,errors},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
