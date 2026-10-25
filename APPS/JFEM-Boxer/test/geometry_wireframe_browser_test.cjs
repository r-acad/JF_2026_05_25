'use strict';
// node geometry_wireframe_browser_test.cjs EVIDENCE_DIR PLAYWRIGHT [webgpu|webgl]
// Exercises real bundled Babylon pipelines: line topology cannot carry depth bias.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const [out,modulePath,backend='webgpu']=process.argv.slice(2),web=path.resolve(__dirname,'../web');
if(!out||!modulePath||!['webgpu','webgl'].includes(backend))throw Error('Expected EVIDENCE_DIR PLAYWRIGHT [webgpu|webgl]');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],checks=[];
 const server=http.createServer((req,res)=>{if(req.url==='/favicon.ico')return res.end();if(req.url==='/'){res.setHeader('Content-Type','text/html');return res.end('<!doctype html>');}const file=path.resolve(web,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(web+path.sep)){res.statusCode=403;return res.end();}res.setHeader('Content-Type',file.endsWith('.wasm')?'application/wasm':'application/javascript');fs.createReadStream(file).pipe(res);});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const {chromium}=require(modulePath),browser=await chromium.launch({channel:'chrome',headless:true,args:backend==='webgpu'?['--enable-unsafe-webgpu']:['--enable-webgl','--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:640,height:480}});
 page.on('pageerror',error=>errors.push(error.message));page.on('console',message=>{if(message.type()==='error')errors.push(message.text());});
 try{
  const origin='http://127.0.0.1:'+server.address().port;await page.goto(origin);await page.setContent('<!doctype html><style>html,body{margin:0;background:black}canvas{display:block;width:640px;height:480px}</style><canvas id="view" width="640" height="480"></canvas>');
  for(const name of ['vendor/babylon.js','aero_display.js','geometry_display.js'])await page.addScriptTag({path:path.join(web,name)});
  await page.evaluate(async({backend,origin})=>{
   const B=BABYLON;window.engine=backend==='webgpu'?new B.WebGPUEngine(document.getElementById('view'),{antialias:true,enableAllFeatures:true}):new B.Engine(document.getElementById('view'),true,{preserveDrawingBuffer:true,stencil:true});
   if(backend==='webgpu')await engine.initAsync({jsPath:origin+'/vendor/glslang/glslang.js',wasmPath:origin+'/vendor/glslang/glslang.wasm'},{jsPath:origin+'/vendor/twgsl/twgsl.js',wasmPath:origin+'/vendor/twgsl/twgsl.wasm'});engine._device?.addEventListener('uncapturederror',event=>console.error(event.error.message));engine.useReverseDepthBuffer=true;
   window.scene=new B.Scene(engine);scene.clearColor=new B.Color4(0,0,0,1);new B.ArcRotateCamera('camera',-Math.PI/3,Math.PI/3,6,new B.Vector3(0,0,0),scene);new B.HemisphericLight('light',new B.Vector3(0,1,0),scene);
   window.original=new B.StandardMaterial('biased-fuel-surface',scene);original.diffuseColor=new B.Color3(.1,.8,.5);original.zOffset=-1;original.zOffsetUnits=2;original.alpha=.42;
   window.meshes=[-1,1].map(x=>{const mesh=B.MeshBuilder.CreateBox('fuel-bay-'+x,{size:1.3},scene);mesh.position.x=x;mesh.material=original;return mesh;});
   window.state={scene,layers:new Map([['FUEL_TANK',{meshes}]]),geometryAppearance:{FUEL_TANK:{style:'wireframe',color:'#21dbaa',opacity:.37}}};window.display=WingGeometryDisplay.create({BABYLON:B,state});
   window.frame=async()=>{for(let i=0;i<20;i++){engine.beginFrame();scene.render();engine.endFrame();await new Promise(resolve=>setTimeout(resolve,10));}};
   window.apply=async style=>{state.geometryAppearance.FUEL_TANK.style=style;display.apply();await frame();return meshes.map(mesh=>({material:mesh.material.getClassName(),zOffset:mesh.material.zOffset,zOffsetUnits:mesh.material.zOffsetUnits,wireframe:mesh.material.wireframe,alpha:mesh.material.alpha,original:mesh.material===original}));};
   window.brightPixels=async png=>{const image=new Image();image.src='data:image/png;base64,'+png;await image.decode();const canvas=document.createElement('canvas');canvas.width=image.width;canvas.height=image.height;const context=canvas.getContext('2d');context.drawImage(image,0,0);const rgba=context.getImageData(0,0,canvas.width,canvas.height).data;let bright=0;for(let i=0;i<rgba.length;i+=4)if(Math.max(rgba[i],rgba[i+1],rgba[i+2])>60)bright++;return bright;};
  },{backend,origin});
  const states=[];
  for(const style of ['wireframe','solid','translucent','metallic','wireframe']){
   const values=await page.evaluate(style=>apply(style),style);states.push({style,values});for(const value of values){assert.equal(value.zOffset,style==='wireframe'?0:-1);assert.equal(value.zOffsetUnits,style==='wireframe'?0:2);assert.equal(value.wireframe,style==='wireframe');assert.equal(value.alpha,style==='translucent'?.37:1);assert.equal(value.original,style!=='metallic');}
   const png=await page.locator('canvas').screenshot();const pixels=await page.evaluate(png=>brightPixels(png),png.toString('base64'));assert(pixels>100,style+' must render actual visible pixels');fs.writeFileSync(path.join(out,'geometry-'+style+'.png'),png);checks.push(style+': '+pixels+' visible pixels with valid depth-bias state.');
  }
  await page.evaluate(async()=>{display.reset();await frame();});const reset=await page.evaluate(()=>meshes.every(mesh=>mesh.material===original&&!mesh.material.wireframe&&mesh.material.zOffset===-1&&mesh.material.zOffsetUnits===2&&mesh.material.alpha===.42));assert(reset);checks.push('Reset restores the original shared material, original triangle depth bias and opacity.');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'geometry_wireframe_check.json'),JSON.stringify({passed:true,backend,states,reset,checks,errors},null,2));console.log(JSON.stringify({passed:true,backend,checks}));
 }catch(error){await page.screenshot({path:path.join(out,'geometry-wireframe-failure.png')});fs.writeFileSync(path.join(out,'geometry_wireframe_failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));throw error;}finally{await page.evaluate(()=>engine?.dispose()).catch(()=>{});await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error);process.exitCode=1;});
