'use strict';
// node loft_cuts_browser_test.cjs <evidence-dir> <playwright-module>
// Uses the bundled production Babylon shader and actual WebGL pixel output.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
(async()=>{
 fs.mkdirSync(out,{recursive:true});let checks=0;const errors=[],verify=(condition,message)=>{assert(condition,message);checks++;};
 const browser=await chromium.launch({headless:true,args:['--enable-webgl','--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader'],...((process.env.CHROME_PATH||process.env.CHROME_BIN)?{executablePath:process.env.CHROME_PATH||process.env.CHROME_BIN}:{})});
 const page=await browser.newPage({viewport:{width:640,height:480},deviceScaleFactor:1});page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.setContent('<!doctype html><style>html,body{margin:0;background:black}canvas{display:block;width:640px;height:480px}</style><canvas id="view" width="640" height="480"></canvas>');
  for(const file of['vendor/babylon.js','loft_cuts.js'])await page.addScriptTag({path:path.join(web,file)});
  await page.evaluate(()=>{
   const B=BABYLON;window.engine=new B.Engine(document.getElementById('view'),true,{preserveDrawingBuffer:true,stencil:true});window.scene=new B.Scene(engine);scene.clearColor=new B.Color4(0,0,0,1);
   const camera=new B.ArcRotateCamera('camera',-Math.PI/3,Math.PI/3,9,new B.Vector3(0,0,0),scene);camera.minZ=.01;
   const positions=[],indices=[];
   for(const x of[-2,2])for(const[y,z]of[[-.7,-1],[.7,-1],[.7,1],[-.7,1]])positions.push(x,y,z);
   for(let k=0;k<4;k++){const a=k,b=(k+1)%4,c=4+(k+1)%4,d=4+k;indices.push(a,b,c,a,c,d);}
   window.source=new B.Mesh('hidden-loft',scene);const vd=new B.VertexData();vd.positions=positions;vd.indices=indices;vd.applyToMesh(source,true);source.setEnabled(false);
   window.cuts=WingLoftCuts.create({BABYLON:B,scene,mesh:source,basePositions:positions});cuts.configure({visible:true,count:3});
   window.frame=()=>new Promise(resolve=>{scene.render();requestAnimationFrame(()=>{scene.render();resolve();});});
   window.stats=async()=>{
    const rgba=await engine.readPixels(0,0,engine.getRenderWidth(),engine.getRenderHeight());let cyan=0,white=0,bright=0,magenta=0;
    for(let i=0;i<rgba.length;i+=4){if(rgba[i]>100&&rgba[i+2]>100&&rgba[i+1]<40)magenta++;if(rgba[i+1]>100&&rgba[i+2]>100&&rgba[i]<40)cyan++;if(rgba[i]>180&&rgba[i+1]>180&&rgba[i+2]>180)white++;if(Math.max(rgba[i],rgba[i+1],rgba[i+2])>100)bright++;}
    const colors=cuts.mesh.getVerticesData(B.VertexBuffer.ColorKind);
    return{cyan,white,bright,magenta,allMagentaVertices:Array.from(colors).every((v,i)=>v===(i%4===1?0:1)),vertexCount:cuts.mesh.getTotalVertices(),allCyanVertices:Array.from(colors).every((v,i)=>v===(i%4===0?0:1)),color:cuts.mesh.color.toHexString(),opaque:cuts.mesh.material.transparencyMode===B.Material.MATERIAL_OPAQUE,sourceEnabled:source.isEnabled(),cutEnabled:cuts.mesh.isEnabled(),planes:cuts.planes};
   };
  });
  await page.evaluate(()=>frame());const initial=await page.evaluate(()=>stats());
  verify(initial.allCyanVertices,'Real Babylon GPU vertex buffer is cyan RGBA.');
  verify(initial.cyan>100&&initial.white===0,JSON.stringify(initial));
  verify(initial.color==='#00FFFF'&&initial.opaque&&initial.cutEnabled&&!initial.sourceEnabled,'Opaque cyan cuts render independently of hidden loft.');
  await page.locator('canvas').screenshot({path:path.join(out,'cyan-cuts.png')});
  // Exercise the allocation branch as well as the original buffer: a fresh
  // larger LinesMesh must carry the same cyan vertex colors.
  await page.evaluate(()=>{cuts.configure({count:37});return frame();});const enlarged=await page.evaluate(()=>stats());
  verify(enlarged.vertexCount>initial.vertexCount&&enlarged.allCyanVertices,'A grown vertex buffer remains cyan.');
  verify(enlarged.cyan>100&&enlarged.white===0,JSON.stringify(enlarged));
  await page.evaluate(()=>{const p=source.getVerticesData(BABYLON.VertexBuffer.PositionKind).slice();for(let i=0;i<p.length;i+=3)p[i+1]+=.2*p[i];source.updateVerticesData(BABYLON.VertexBuffer.PositionKind,p,true);cuts.update();return frame();});const deformed=await page.evaluate(()=>stats());
  verify(deformed.allCyanVertices&&deformed.cyan>100&&deformed.white===0,'Deformation updates preserve cyan pixels and vertex colors.');
  await page.evaluate(()=>{window.originalMesh=cuts.mesh;cuts.configure({color:'#ff00ff'});return frame();});const recolored=await page.evaluate(()=>stats());
  verify(recolored.magenta>100&&recolored.cyan===0&&recolored.allMagentaVertices,'Color picker value changes actual WebGL pixels and the vertex buffer.');
  verify(await page.evaluate(()=>cuts.mesh===originalMesh),'Color changes reuse the rendered mesh.');
  await page.evaluate(()=>{cuts.configure({count:100});return frame();});const regrown=await page.evaluate(()=>stats());
  verify(regrown.vertexCount>enlarged.vertexCount&&regrown.allMagentaVertices&&regrown.magenta>100,'Buffer growth retains the user color.');
  await page.evaluate(()=>{cuts.update();return frame();});verify((await page.evaluate(()=>stats())).allMagentaVertices,'Deformation retains the chosen color.');
  await page.locator('canvas').screenshot({path:path.join(out,'magenta-cuts.png')});
  await page.evaluate(()=>{cuts.configure({visible:false});return frame();});const hidden=await page.evaluate(()=>stats());
  verify(!hidden.cutEnabled&&hidden.bright===0,'Hide removes the actual rendered cuts.');
  verify(errors.length===0,errors.join('\n'));
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,initial,enlarged,deformed,recolored,regrown,hidden,scope:'Bundled production Babylon, actual WebGL RGBA pixel/vertex buffers, hidden source, allocation growth, deformation and hiding'},null,2));
  console.log(JSON.stringify({passed:true,checks,errors,pixels:{initial:initial.cyan,enlarged:enlarged.cyan,deformed:deformed.cyan}}));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});throw error;}finally{await page.evaluate(()=>engine?.dispose()).catch(()=>{});await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
