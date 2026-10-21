'use strict';
// Actual Boxer server + fresh browsers with every external request denied.
// node offline_browser_test.cjs BOXER_URL EVIDENCE_DIR [PLAYWRIGHT_MODULE]
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const[url,out,modulePath='playwright']=process.argv.slice(2),repo=path.resolve(__dirname,'../../..');
fs.mkdirSync(out,{recursive:true});
function glb(){
 const binary=Buffer.alloc(44);new Float32Array([0,0,0,1,0,0,0,1,0]).forEach((v,i)=>binary.writeFloatLE(v,4*i));[0,1,2].forEach((v,i)=>binary.writeUInt16LE(v,36+2*i));
 const data={asset:{version:'2.0'},scene:0,scenes:[{nodes:[0]}],nodes:[{mesh:0}],meshes:[{primitives:[{attributes:{POSITION:0},indices:1}]}],buffers:[{byteLength:44}],bufferViews:[{buffer:0,byteOffset:0,byteLength:36,target:34962},{buffer:0,byteOffset:36,byteLength:6,target:34963}],accessors:[{bufferView:0,componentType:5126,count:3,type:'VEC3',min:[0,0,0],max:[1,1,0]},{bufferView:1,componentType:5123,count:3,type:'SCALAR'}]};
 let json=JSON.stringify(data);while(Buffer.byteLength(json)%4)json+=' ';const chunk=Buffer.from(json),result=Buffer.alloc(28+chunk.length+binary.length);
 result.writeUInt32LE(0x46546c67,0);result.writeUInt32LE(2,4);result.writeUInt32LE(result.length,8);result.writeUInt32LE(chunk.length,12);result.writeUInt32LE(0x4e4f534a,16);chunk.copy(result,20);result.writeUInt32LE(binary.length,20+chunk.length);result.writeUInt32LE(0x004e4942,24+chunk.length);binary.copy(result,28+chunk.length);return [...result];
}
(async()=>{
 const requests=[],external=[],errors=[],gpuConsoleErrors=[],checks=[],renderer=process.env.JFEM_TEST_RENDERER||'webgpu';
 const server=http.createServer((req,res)=>{
  const route=decodeURIComponent(new URL(req.url,'http://local').pathname),file=path.resolve(repo,'.'+route);
  if(!file.startsWith(repo+path.sep)||!fs.existsSync(file)||!fs.statSync(file).isFile()){res.writeHead(404);return res.end('not found');}
  const type={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.wasm':'application/wasm'}[path.extname(file)]||'application/octet-stream';
  res.writeHead(200,{'Content-Type':type,'Cache-Control':'no-store'});fs.createReadStream(file).pipe(res);
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const staticURL='http://127.0.0.1:'+server.address().port;
 const {chromium}=require(modulePath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:renderer==='webgl'?['--use-angle=swiftshader','--enable-unsafe-swiftshader']:[]});
 const context=await browser.newContext({viewport:{width:1500,height:1000},serviceWorkers:'block'});
 await context.route('**/*',route=>{const target=route.request().url();requests.push(target);if(target.startsWith('data:')||target.startsWith('blob:')||[new URL(url).origin,staticURL].includes(new URL(target).origin))return route.continue();external.push(target);return route.abort('internetdisconnected');});
 const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));page.on('console',message=>{if(message.type()==='error'&&/shader|WebGPU|GPUValidation|WGSL|SPIR-V|ValidationError/i.test(message.text()))gpuConsoleErrors.push(message.text());});
 try{
  await page.goto(url);await page.getByRole('button',{name:'Start new study',exact:true}).click();await page.waitForFunction(()=>state.data?.nodes?.count&&!state.workspaceBusy&&!state.meshRequestInFlight,null,{timeout:300000});await page.locator('#auto-mesh').uncheck();
  const initial=await page.evaluate(()=>{window.offlineGpuErrors=[];state.engine._device?.addEventListener('uncapturederror',event=>offlineGpuErrors.push(String(event.error?.message||event.error)));return{version:BABYLON.Engine.Version,nodes:state.data.nodes.count,meshes:state.scene.meshes.length,frames:state.engine.frameId,webGPU:!!state.engine.isWebGPU};});assert.equal(initial.webGPU,renderer==='webgpu');assert(initial.meshes>0);assert.equal(initial.version,'9.27.1');checks.push({name:'Boxer startup and generated model',...initial});
  const geometry=await page.evaluate(async bytes=>{
   const sources=[['offline.stl','solid triangle\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid triangle'],['offline.obj','v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n'],['offline.glb',new Uint8Array(bytes)]];
   const result=[];for(const[name,body]of sources){const entry=await state.reference.importFile(new File([body],name));result.push({name,triangles:entry.triangles});}return result;
  },glb());assert(geometry.every(item=>item.triangles===1));checks.push({name:'Local STL, OBJ and GLB imports',geometry});
  await page.evaluate(()=>{activateWorkspaceTab('displayenvironment');document.getElementById('show-ground-plane').checked=true;document.getElementById('ground-plane-z').value=String(state.data.bbox.min[2]-.5);syncViewPlanes();state.sceneLighting.apply({...state.sceneLighting.capture(),shadows:true,selfShadows:true});});
  for(const surface of ['solid','translucent'])for(const finish of ['solid','wireframe','translucent','metallic']){
   const result=await page.evaluate(async({surface,finish})=>{const control=document.getElementById('surface-mode');control.value=surface;control.dispatchEvent(new Event('change',{bubbles:true}));const ground=document.querySelector('[aria-label="Ground plane finish"]');ground.value=finish;ground.dispatchEvent(new Event('change',{bubbles:true}));await state.scene.whenReadyAsync();for(let i=0;i<5;i++)await new Promise(resolve=>state.engine.onEndFrameObservable.addOnce(resolve));return{surface,finish,ground:state.viewPlanes.meshes.ground.isEnabled(),ready:state.scene.isReady()};},{surface,finish});assert(result.ground);await page.waitForFunction(()=>state.scene.isReady(),null,{timeout:30000});checks.push(result);
   await page.locator('#render').screenshot({path:path.join(out,`boxer-${surface}-${finish}.png`)});
  }
  await page.screenshot({path:path.join(out,'boxer-offline.png')});assert.deepEqual(await page.evaluate(()=>offlineGpuErrors),[]);
  for(const [name,file]of [['PANDEATOR','APPS/PANDEATOR_APP/panel_app.html'],['Results viewer','APPS/JFEM_results_viewer/postv11.html']]){
   await page.goto(staticURL+'/'+file);await page.waitForFunction(()=>typeof BABYLON!=='undefined'&&BABYLON.Engine.Instances.some(engine=>engine.scenes.length>0));
   const result=await page.evaluate(()=>{const engine=BABYLON.Engine.Instances[0];return{version:BABYLON.Engine.Version,scenes:engine.scenes.length,frames:engine.frameId,webGPU:!!engine.isWebGPU};});assert.equal(result.version,'7.54.3');assert.equal(result.webGPU,renderer==='webgpu');checks.push({name,...result});
  }
  assert.deepEqual(external,[],'No runtime request may need internet');assert.deepEqual(errors,[]);assert.deepEqual(gpuConsoleErrors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,renderer,checks,external,errors,gpuConsoleErrors,requests},null,2));console.log(JSON.stringify({passed:true,checks:checks.length,externalRequests:external.length}));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,renderer,checks,external,errors,gpuConsoleErrors,requests},null,2));await page.screenshot({path:path.join(out,'failure.png')});throw error;}
 finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error);process.exitCode=1;});
