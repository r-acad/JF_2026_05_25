'use strict';
// Real geometry preview, before any FEM is generated.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [url,out,modulePath='playwright',studyPath=path.join(__dirname,'../examples/test1/test1.wingfem.json')]=process.argv.slice(2),{chromium}=require(modulePath);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({channel:'chrome',headless:true,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1750,height:1150}}),errors=[],requests=[],checks=[],depths=[];
 page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(r.method()==='POST')requests.push(new URL(r.url()).pathname);});
 await page.route('**/api/input',async route=>{const response=await route.fetch(),data=await response.json();Object.assign(data.defaults,{'planform.area':200,'planform.aspect_ratio':8,'planform.taper_ratio':.4,'planform.sweep':20,'planform.dihedral':15,'planform.root_ref_z':25});await route.fulfill({json:data});});
 const ready=()=>page.waitForFunction(()=>state.geometryPreview?.active&&!state.workspaceBusy&&!state.studyRestoring,null,{timeout:180000});
 async function checkDepth(label){
  const d=await page.evaluate(()=>{
   const c=state.camera,m=state.scene.getMeshByName('live-geometry-loft');c.getViewMatrix(true);const xyz=m.getVerticesData(BABYLON.VertexBuffer.PositionKind),matrix=m.computeWorldMatrix(true),eye=c.globalPosition,forward=c.getForwardRay(1).direction;let min=Infinity,max=-Infinity;
   for(let i=0;i<xyz.length;i+=3){const p=BABYLON.Vector3.TransformCoordinates(new BABYLON.Vector3(xyz[i],xyz[i+1],xyz[i+2]),matrix),depth=BABYLON.Vector3.Dot(p.subtract(eye),forward);min=Math.min(min,depth);max=Math.max(max,depth);}
   return{min,max,near:c.minZ,far:c.maxZ,feDiag:state.diag,previousFar:Math.max(state.diag*10,c.radius+state.diag*3),hasFEM:!!state.data};
  });
  assert(!d.hasFEM);assert(d.min>d.near,JSON.stringify(d));assert(d.max<d.far,JSON.stringify(d));depths.push({label,...d});return d;
 }
 try{
  await page.goto(url);await page.getByRole('button',{name:'Start new study',exact:true}).click();await ready();await page.evaluate(()=>state.autosave?.destroy());await page.waitForTimeout(150);
  const initial=await checkDepth('initial large geometry');assert(initial.max>initial.previousFar);checks.push('Initial large geometry is fully inside the depth range before FEM; the former FEM-only clipping range cuts this fixture.');
  for(const [name,a,b]of [['iso',-Math.PI/4,Math.acos(1/Math.sqrt(3))],['top',Math.PI/2,.001],['side',Math.PI,Math.PI/2]]){await page.evaluate(([a,b])=>setView(a,b),[a,b]);await page.waitForTimeout(60);await checkDepth(name);}
  await page.evaluate(()=>state.viewportTools.projection(true));await page.waitForTimeout(60);await checkDepth('parallel');await page.screenshot({path:path.join(out,'large-geometry-no-fem.png')});await page.evaluate(()=>state.viewportTools.projection(false));checks.push('Perspective and parallel views retain the complete geometry through top/side/isometric fitting.');
  const study=JSON.parse(fs.readFileSync(studyPath,'utf8'));study.view.controls['auto-mesh']=false;assert(await page.evaluate(text=>loadModelDefinition({name:'test1.wingfem.json',text:async()=>text},{recent:true}),JSON.stringify(study)));await ready();await page.evaluate(()=>setView(-Math.PI/4,Math.acos(1/Math.sqrt(3))));await page.waitForTimeout(80);await checkDepth('actual test1');await page.screenshot({path:path.join(out,'test1-geometry-no-fem.png')});
  const oldZ=await page.evaluate(()=>Number(document.getElementById('p-planform.root_ref_z').value));await page.evaluate(z=>{const n=document.getElementById('p-planform.root_ref_z');n.value=z+500;parameterEdited('planform.root_ref_z');},oldZ);await page.waitForFunction(z=>state.geometryPreview?.bbox?.min[2]>z+400,oldZ);await page.evaluate(()=>fitView());await page.waitForTimeout(80);await checkDepth('translated test1');checks.push('Actual test1 geometry and a large vertical translation fit without a FEM or changing FE glyph scale.');
  assert.equal(requests.filter(p=>['/api/generate','/api/prepare_workspace'].includes(p)).length,0);assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,depths,requests,errors},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(error){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,depths,requests,errors},null,2));await page.screenshot({path:path.join(out,'failure.png')}).catch(()=>{});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
