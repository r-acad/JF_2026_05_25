'use strict';
// Closed-loft depth/lighting regression before any FEM exists.
// node geometry_preview_render_browser_test.cjs PRIVATE_OUTPUT PLAYWRIGHT_MODULE
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const out=path.resolve(process.argv[2]),{chromium}=require(process.argv[3]||'playwright'),web=path.resolve(__dirname,'../web');
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],checks=[];
 const server=http.createServer((req,res)=>{const u=new URL(req.url,'http://localhost');if(u.pathname==='/'){res.setHeader('Content-Type','text/html');return res.end('<body style="margin:0"><canvas width="1000" height="700" id="canvas"></canvas><script src="/vendor/babylon.js"></script><script src="/movable_surfaces.js"></script><script src="/geometry_preview.js"></script>');}if(u.pathname==='/favicon.ico')return res.end();const p=path.resolve(web,'.'+u.pathname);if(!p.startsWith(web+path.sep)){res.statusCode=403;return res.end();}res.setHeader('Content-Type','application/javascript');fs.createReadStream(p).pipe(res);});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const browser=await chromium.launch({headless:true,channel:'chrome',args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1000,height:700}});
 page.on('pageerror',e=>errors.push(e.stack));
 try{
  await page.goto('http://127.0.0.1:'+server.address().port);
  await page.evaluate(async()=>{
   const B=BABYLON;window.engine=new B.Engine(document.getElementById('canvas'),false,{preserveDrawingBuffer:true});window.scene=new B.Scene(engine);scene.useRightHandedSystem=true;scene.clearColor=new B.Color4(.13,.24,.36,1);
   window.camera=new B.ArcRotateCamera('camera',-Math.PI/3,.42,12,new B.Vector3(2.5,0,1),scene);camera.minZ=.01;camera.maxZ=100;
   new B.HemisphericLight('light',new B.Vector3(0,1,.3),scene);const light=new B.DirectionalLight('side',new B.Vector3(-.5,-1,-.2),scene);light.intensity=.45;
   const xs=Array.from({length:41},(_,i)=>(1-Math.cos(Math.PI*i/40))/2),loop=[[1,0],...xs.slice(1,-1).reverse().map(x=>[x,-1]),[0,0],...xs.slice(1,-1).map(x=>[x,1])],xyz=[],conn=[];
   for(let i=0;i<49;i++)for(const[x,s]of loop){const t=5*.12*(.2969*Math.sqrt(x)-.126*x-.3516*x*x+.2843*x*x*x-.1036*x*x*x*x);xyz.push(2*x,5*i/48,2*s*t);}
   for(let i=0;i<48;i++)for(let j=0;j<loop.length;j++){const k=(j+1)%loop.length;conn.push(i*loop.length+j,i*loop.length+k,(i+1)*loop.length+k,(i+1)*loop.length+j);}
   window.payload={aero:{xyz,conn,sections:[]},bbox:{min:[0,0,-.13],max:[2,5,.13]}};window.params={'planform.area':10};window.state={scene,layers:new Map(),data:null,transparency:{enabled:false}};
   window.preview=WingGeometryPreview.create({state,read:()=>params,request:async()=>payload});preview.request(0);await new Promise(r=>setTimeout(r,30));
   window.render=async()=>{for(let i=0;i<4;i++){scene.render();await new Promise(r=>setTimeout(r,10));}};await render();
  });
  const initial=await page.evaluate(()=>{const m=scene.getMeshByName('live-geometry-loft');return{alpha:m.material.alpha,mode:m.material.transparencyMode,opaque:BABYLON.Material.MATERIAL_OPAQUE,depthWrite:!m.material.disableDepthWrite,count:m.getTotalVertices()};});
  await page.screenshot({path:path.join(out,'initial-preview.png')});
  // Ordering closed-surface triangles must not alter what a standalone opaque
  // loft shows. The former alpha=.72 path exposed differently lit back faces.
  const depth=await page.evaluate(async()=>{
   const mesh=scene.getMeshByName('live-geometry-loft'),indices=Array.from(mesh.getIndices()),read=()=>engine.readPixels(0,0,1000,700);await render();const a=await read();
   const reversed=[];for(let i=indices.length-3;i>=0;i-=3)reversed.push(indices[i],indices[i+1],indices[i+2]);mesh.setIndices(reversed);await render();const b=await read();let changed=0,max=0;
   for(let i=0;i<a.length;i+=4){const diff=Math.max(Math.abs(a[i]-b[i]),Math.abs(a[i+1]-b[i+1]),Math.abs(a[i+2]-b[i+2]));max=Math.max(max,diff);if(diff>3)changed++;}
   mesh.setIndices(indices);return{changed,max,pixels:a.length/4};
  });
  assert.equal(initial.alpha,1,'Standalone geometry must not blend unsorted back faces');assert.equal(initial.mode,initial.opaque);assert(initial.depthWrite&&initial.count>3000);assert(depth.changed<100,JSON.stringify(depth));checks.push('Initial closed loft is opaque with depth writes; reversing all triangles preserves visible pixels except subpixel shared edges.');
  const normals=await page.evaluate(()=>{const mesh=scene.getMeshByName('live-geometry-loft'),expected=[];if(mesh.sideOrientation!==BABYLON.Material.CounterClockWiseSideOrientation)return false;BABYLON.VertexData.ComputeNormals(mesh.getVerticesData(BABYLON.VertexBuffer.PositionKind),mesh.getIndices(),expected,{useRightHandedSystem:true});const actual=mesh.getVerticesData(BABYLON.VertexBuffer.NormalKind);return expected.every((v,i)=>Math.abs(v-actual[i])<1e-6);});assert(normals);checks.push('Preview normals use the same right-handed scene convention as the FEM loft.');
  await page.evaluate(async()=>{const surface={definition:{name:'Neutral',color:'#ffac49',deflection:0},xyz:[1.5,1,0,2,1,0,2,2,0,1.5,2,0],triangles:[0,1,2,0,2,3],outline:[[1.5,1,0],[1.5,2,0],[2,2,0],[2,1,0]],hinge:[[1.5,1,0],[1.5,2,0]]};payload.movables={surfaces:[surface,{...surface,definition:{...surface.definition,name:'Deflected',deflection:15}}]};params={'planform.area':10.5};preview.request(0);await new Promise(r=>setTimeout(r,30));await render();});
  const controls=await page.evaluate(()=>{const guides=scene.meshes.filter(m=>m.metadata?.neutralControlGuide),filled=scene.meshes.filter(m=>m.metadata?.movableSurfacePreview&&m.name==='movable-surface-Deflected');return{guides:guides.map(m=>m.metadata.controlName),neutralFilled:!!scene.getMeshByName('movable-surface-Neutral'),deflected:filled.length===1&&filled[0].isEnabled()&&filled[0].material.alpha===.3&&filled[0].material.depthFunction!==BABYLON.Constants.ALWAYS};});assert.deepEqual(controls.guides,['Neutral']);assert(!controls.neutralFilled&&controls.deflected);checks.push('Neutral controls have visible colored footprint/hinge guides without overlapping fill; deflected controls retain ordinary depth-tested translucent surfaces.');
  await page.evaluate(async()=>{state.data={model_params:{'planform.area':1}};params={'planform.area':11};preview.request(0);await new Promise(r=>setTimeout(r,30));await render();});
  const overlay=await page.evaluate(()=>{const m=scene.getMeshByName('live-geometry-loft').material;return{alpha:m.alpha,separate:m.separateCullingPass,mode:m.transparencyMode,blend:BABYLON.Material.MATERIAL_ALPHABLEND};});assert.equal(overlay.alpha,.22);assert.equal(overlay.mode,overlay.blend);assert(overlay.separate);checks.push('Changed geometry over a retained FEM remains translucent with the structural fallback culling policy.');
  await page.evaluate(()=>preview.reset());assert.equal(await page.evaluate(()=>scene.meshes.filter(m=>m.name==='live-geometry-loft').length),0);assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,initial,depth,overlay,errors},null,2));console.log(JSON.stringify({passed:true,checks,depth}));
 }catch(e){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,errors},null,2));throw e;}finally{await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
