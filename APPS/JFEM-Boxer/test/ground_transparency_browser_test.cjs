"use strict";
// node ground_transparency_browser_test.cjs <fixture-dir> <evidence-dir> [playwright-module]
// Generated FE fixture: schema.json and payload.msgpack (gaps_ accepted).
// CHROME_PATH optionally selects a browser executable.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
if(!process.argv[2]||!process.argv[3])throw Error('Usage: node ground_transparency_browser_test.cjs <fixture-dir> <evidence-dir> [playwright-module]');
const fixture=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]),web=path.resolve(__dirname,'../web'),{chromium}=require(process.argv[4]||'playwright');
const fixtureFile=name=>{const file=path.join(fixture,name);return fs.existsSync(file)?file:path.join(fixture,'gaps_'+name);};
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],results=[];
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1450,height:1000}});page.on('pageerror',e=>errors.push(e.stack));
 try{
  const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
  await page.route('http://127.0.0.1:43995/**',async route=>{const url=new URL(route.request().url());if(url.pathname.startsWith('/api/'))throw Error('Ground display must not request model or solver work');return url.pathname==='/'?route.fulfill({contentType:'text/html',body:html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'').replace(/<link\b[^>]*>/g,'')}):route.fulfill({path:path.join(web,url.pathname)});});
  await page.goto('http://127.0.0.1:43995/');
  for(const[,file]of html.matchAll(/<link\s+rel="stylesheet"\s+href="([^"]+)"/g))await page.addStyleTag({path:path.join(web,file)});
  for(const[,file]of html.matchAll(/<script\s+src="([^"]+)"/g))if(file!=='app.js')await page.addScriptTag({path:path.join(web,file)});
  const app=fs.readFileSync(path.join(web,'app.js'),'utf8');await page.addScriptTag({content:app.slice(0,app.indexOf('(async function start()'))});
  await page.evaluate(async({bytes,schema})=>{
   initScene();state.engine.stopRenderLoop();state.schema=schema.schema;state.defaults=schema.defaults;state.data=MessagePack.decode(Uint8Array.from(bytes));state.values=state.data.model_params;state.autoMeshEnabled=false;
   document.getElementById('auto-mesh').checked=false;buildForm(state.schema,state.values);buildModel(state.data);state.modelSignature=formSignature();setModelDirty(false);setBusy(false);
   document.getElementById('splash').hidden=true;WingActivity.end(WingActivity.startup);WingActivity.startup=null;activateWorkspaceTab('displayenvironment');
   state.camera.radius*=1.4;
   window.render=async(n=3)=>{state.engine.resize();await state.scene.whenReadyAsync();for(let i=0;i<n;i++){state.scene.render();await new Promise(requestAnimationFrame);}};
   window.capture=async()=>{const width=state.engine.getRenderWidth(),height=state.engine.getRenderHeight(),pixels=await state.engine.readPixels(0,0,width,height),sample=[];for(let y=20;y<height-20;y+=4)for(let x=20;x<width-20;x+=4){const offset=(y*width+x)*4;sample.push(...pixels.slice(offset,offset+3));}return sample;};
   window.compare=(a,b)=>{let changed=0;for(let i=0;i<a.length;i+=3)if(Math.max(...[0,1,2].map(c=>Math.abs(a[i+c]-b[i+c])))>4)changed++;return changed;};
   window.lighting=()=>({lights:state.scene.lights.map(l=>({id:l.id,intensity:l.intensity,direction:l.direction?.asArray(),diffuse:l.diffuse.asArray(),specular:l.specular.asArray()})),environment:state.scene.environmentTexture?.uniqueId||null,environmentIntensity:state.scene.environmentIntensity,oit:state.scene.useOrderIndependentTransparency,camera:state.scene.activeCamera.uniqueId,clip:state.scene.clipPlane?.asArray()||null});
   await render();
  },{bytes:[...fs.readFileSync(fixtureFile('payload.msgpack'))],schema:JSON.parse(fs.readFileSync(fixtureFile('schema.json'),'utf8'))});
  for(const mode of ['translucent','solid'])for(const [view,beta,alpha,orthographic]of [['above',1.05,-.95,false],['rotated',1.2,.6,false],['below',2.15,-.95,false],['orthographic',1.05,-.95,true]]){
   const setup=await page.evaluate(async({mode,beta,alpha,orthographic})=>{
    document.getElementById('surface-mode').value=mode;applySurfaceMode();state.camera.beta=beta;state.camera.alpha=alpha;
    state.camera.mode=orthographic?BABYLON.Camera.ORTHOGRAPHIC_CAMERA:BABYLON.Camera.PERSPECTIVE_CAMERA;
    if(orthographic){const r=state.camera.radius*.45,aspect=state.engine.getRenderWidth()/state.engine.getRenderHeight();state.camera.orthoLeft=-r*aspect;state.camera.orthoRight=r*aspect;state.camera.orthoTop=r;state.camera.orthoBottom=-r;}
    document.getElementById('ground-plane-z').value=String(beta>Math.PI/2?state.data.bbox.max[2]+.8:state.data.bbox.min[2]-.8);document.getElementById('ground-grid-spacing').value='1';document.getElementById('show-ground-plane').checked=false;syncViewPlanes();await render();window.baseline=await capture();window.before=lighting();
    return{oit:state.transparency.enabled,alphas:[...new Set(state.data.groups.filter(g=>['quad','tria'].includes(g.kind)).flatMap(g=>state.layers.get(g.name)?.meshes||[]).map(m=>m.material.alpha))]};
   },{mode,beta,alpha,orthographic});
   if(mode==='translucent'){assert(setup.oit);assert(setup.alphas.every(alpha=>alpha>0&&alpha<1));}
   for(const style of ['solid','translucent','wireframe','metallic']){
    const result=await page.evaluate(async({mode,view,style})=>{
     const finish=document.querySelector('[aria-label="Ground plane finish"]'),opacity=document.querySelector('[aria-label="Ground plane opacity"]');finish.value=style;finish.dispatchEvent(new Event('change',{bubbles:true}));opacity.value='.4';opacity.dispatchEvent(new Event('input',{bubbles:true}));document.getElementById('show-ground-plane').checked=true;syncViewPlanes();await render();
     const visible=await capture(),beforeHide=lighting(),vertices=state.viewPlanes.meshes.ground.getTotalVertices();
     document.getElementById('show-ground-plane').checked=false;syncViewPlanes();await render();const hidden=await capture();
     document.getElementById('show-ground-plane').checked=true;syncViewPlanes();await render();const reshown=await capture();
     return{mode,view,style,visiblePixels:compare(visible,baseline),hiddenPixels:compare(hidden,baseline),reshownPixels:compare(reshown,baseline),vertices,before,after:beforeHide,oit:state.transparency.enabled};
    },{mode,view,style});results.push(result);
    await page.screenshot({path:path.join(out,mode+'-'+view+'-'+style+'.png')});
    assert(result.visiblePixels>500,'Ground remains visible: '+JSON.stringify(result));
    assert(result.reshownPixels>500,'Ground returns after hiding: '+JSON.stringify(result));
    // Coplanar support/edge pixels fluctuate slightly between real FE frames.
    assert(result.hiddenPixels<500,'Hiding restores model: '+JSON.stringify(result));
    assert.equal(result.vertices,4);assert.deepEqual(result.after,result.before,'Ground does not change lights/environment/camera/OIT');
   }
  }
  const label=await page.evaluate(()=>document.getElementById('layer-RBE3')?.closest('label')?.textContent);assert(label.includes('RBE3 for Loads'),label);
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,results,errors},null,2));console.log('Ground transparency: '+results.length+' whole-model finish/perspective combinations passed.');
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,results,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
