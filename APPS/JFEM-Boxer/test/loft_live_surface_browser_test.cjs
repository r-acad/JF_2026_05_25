'use strict';
// Actual app + an analytical preview fixture. No user app, Study or solver job.
// node loft_live_surface_browser_test.cjs OUT BOOTSTRAP PLAYWRIGHT [BROWSER]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,fixtureArg,pwArg,browserArg]=process.argv.slice(2);
if(!outArg||!fixtureArg||!pwArg)throw Error('Output, bootstrap and Playwright paths required');
const out=path.resolve(outArg),fixture=path.resolve(fixtureArg),web=path.resolve(__dirname,'../web'),{chromium}=require(path.resolve(pwArg));
const Loft=require('../web/loft.js'),msgpack=require(path.join(web,'vendor/msgpack.min.js'));
const schema=JSON.parse(fs.readFileSync(path.join(fixture,'schema.json'),'utf8'));
schema.defaults=JSON.parse(fs.readFileSync(path.join(fixture,'params.json'),'utf8'));
const simple={'planform.area':8,'planform.aspect_ratio':8,'planform.taper_ratio':1,'planform.sweep':0,'planform.dihedral':0,'planform.twist_tip':0,
 'planform.root_ref_x':0,'planform.root_ref_y':0,'planform.root_ref_z':0,'airfoil.root':'NACA0012','airfoil.tip':'NACA0012','movable_surfaces.items':[],
 'loft.thickness_stations':[],'loft.twist_stations':[],'loft.vertical_shift_stations':[],'loft.vertical_shift_interpolation':'linear'};
Object.assign(schema.defaults,simple);Object.assign(schema.values,simple);
function geometry(p){
 const schedule=(kind,eta,fallback)=>{const rows=p['loft.'+kind+'_stations']||[];return rows.length?Loft.interpolateSchedule(rows,eta,{kind,method:p['loft.'+kind+'_interpolation']||'linear'}):fallback;};
 const xyz=[],conn=[];
 for(let j=0;j<=4;j++)for(const sign of [-1,1])for(const x of [0,1]){
  const eta=j/4,shift=4*schedule('vertical_shift',eta,0)/100,tc=schedule('thickness',eta,.12),twist=schedule('twist',eta,eta*(p['planform.twist_tip']||0))*Math.PI/180,z=sign*tc/2;
  xyz.push(.25+Math.cos(twist)*(x-.25)+Math.sin(twist)*z,eta*4,shift-Math.sin(twist)*(x-.25)+Math.cos(twist)*z);
 }
 for(let j=0;j<4;j++)for(let side=0;side<2;side++){const a=4*j+2*side;conn.push(a,a+1,a+5,a+4);}
 const axis=k=>xyz.filter((_,i)=>i%3===k);
 return{ok:true,geometry_only:true,aero:{xyz,conn,count:conn.length/4,sections:[]},bbox:{min:[0,1,2].map(k=>Math.min(...axis(k))),max:[0,1,2].map(k=>Math.max(...axis(k)))},movables:{surfaces:[]}};
}
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(browserArg?{executablePath:browserArg}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1700,height:1100}}),checks=[],errors=[],requests=[];let active=0,maxActive=0;page.setDefaultTimeout(30000);page.on('pageerror',e=>errors.push(e.message));
 const settle=()=>page.waitForFunction(()=>state.geometryPreview?.active&&state.geometryPreview.signature===WingGeometryPreview.signature(readAuthoredGeometry())&&!state.workspaceBusy);
 const rows=()=>page.evaluate(()=>state.loftEditor.readDrafts()['loft.vertical_shift_stations']);
 const dragHandle=async(dx,dy)=>{const handle=page.locator('[data-loft-plot=vertical_shift] [data-loft-handle="1"]');await handle.scrollIntoViewIfNeeded();const box=await handle.boundingBox();assert(box);await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.mouse.move(box.x+box.width/2+dx,box.y+box.height/2+dy,{steps:10});};
 try{
  await page.route('http://127.0.0.1:43996/**',async route=>{
   const u=new URL(route.request().url()),p=route.request().method()==='POST'?route.request().postDataJSON():null;
   if(u.pathname.startsWith('/api/'))requests.push({path:u.pathname,params:p});
   if(u.pathname==='/api/input')return route.fulfill({json:schema});
   if(['/api/validate_workspace','/api/restore_workspace'].includes(u.pathname))return route.fulfill({json:{ok:true,parameters:p}});
   if(u.pathname==='/api/geometry_preview'){
    active++;maxActive=Math.max(maxActive,active);try{await new Promise(resolve=>setTimeout(resolve,70));await route.fulfill({body:Buffer.from(msgpack.encode(geometry(p))),contentType:'application/msgpack'});}finally{active--;}return;
   }
   if(u.pathname==='/api/movable_surfaces')return route.fulfill({json:{ok:true,surfaces:[]}});
   if(u.pathname==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
   if(u.pathname==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
   if(u.pathname==='/api/jfem_probe')return route.fulfill({json:{found:true}});
   if(u.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated live loft fixture'}});
   const file=u.pathname.startsWith('/shared/')?path.join(web,'../..',u.pathname.slice(8)):path.join(web,u.pathname==='/'?'index.html':decodeURIComponent(u.pathname));
   return fs.existsSync(file)?route.fulfill({path:file}):route.fulfill({status:404,body:'Missing fixture asset'});
  });
  await page.goto('http://127.0.0.1:43996/');await page.locator('.startup-study-dialog [data-choice=new]').click();await page.waitForFunction(()=>state.autoMeshReady&&!state.workspaceBusy);await settle();
  await page.evaluate(()=>{state.autosave?.destroy();document.getElementById('auto-save').checked=false;state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();activateWorkspaceTab('loft');setWorkspaceMaximized('loft');});
  assert.equal(await page.evaluate(()=>state.data),null);checks.push('Loaded authored surface is visible before generating any FEM.');
  await page.locator('[data-loft-add=vertical_shift]').click();await page.locator('[data-loft-add=vertical_shift]').click();await settle();
  assert.equal((await rows()).length,3);const original=await rows();
  await page.evaluate(()=>{state.studyDirty=false;updateFileStatus();window.cameraBeforeLoft={alpha:state.camera.alpha,beta:state.camera.beta,radius:state.camera.radius,target:state.camera.target.asArray()};});
  const before=await page.evaluate(()=>({maxZ:state.geometryPreview.bbox.max[2],positions:Array.from(state.scene.getMeshByName('live-geometry-loft').getVerticesData(BABYLON.VertexBuffer.PositionKind))}));
  await dragHandle(70,-32);await page.waitForFunction(()=>state.loftEditor.isInteracting());await settle();
  const during=await rows();assert(during[1].eta>original[1].eta);assert(during[1].shift_percent>original[1].shift_percent);assert.equal(await page.evaluate(()=>state.studyDirty),false);
  const shown=await page.evaluate(()=>({maxZ:state.geometryPreview.bbox.max[2],positions:Array.from(state.scene.getMeshByName('live-geometry-loft').getVerticesData(BABYLON.VertexBuffer.PositionKind))}));
  assert(shown.maxZ>before.maxZ);assert.notDeepEqual(shown.positions,before.positions);assert.equal(await page.evaluate(()=>state.data),null);
  checks.push('Horizontal and vertical pointer movement changes eta and shift, and the 3D mesh updates while the pointer is still held.');
  await page.mouse.up();await settle();assert.equal(await page.evaluate(()=>state.studyDirty),true);
  const committed=await rows(),camera=await page.evaluate(()=>({alpha:state.camera.alpha,beta:state.camera.beta,radius:state.camera.radius,target:state.camera.target.asArray()}));
  assert.deepEqual(camera,await page.evaluate(()=>window.cameraBeforeLoft));checks.push('Release commits the Study edit and retains the camera; FEM remains absent.');
  await dragHandle(-35,22);await settle();assert.notDeepEqual(await rows(),committed);await page.keyboard.press('Escape');await page.mouse.up();await settle();assert.deepEqual(await rows(),committed);
  checks.push('Escape restores both coordinates and updates the visible surface back to the committed loft.');
  await page.locator('[id="p-loft.vertical_shift_interpolation"]').selectOption('cosine');await page.waitForFunction(()=>JSON.parse(state.geometryPreview.signature||'{}')['loft.vertical_shift_interpolation']==='cosine');await settle();assert.equal(requests.filter(r=>r.path==='/api/geometry_preview').at(-1).params['loft.vertical_shift_interpolation'],'cosine');
  const tip=page.locator('[id="p-planform.twist_tip"]');await tip.fill('-4');await tip.dispatchEvent('input');await settle();assert.equal(requests.filter(r=>r.path==='/api/geometry_preview').at(-1).params['planform.twist_tip'],-4);
  checks.push('Interpolation and original tip-twist edits also reach the geometry preview without Create FEM.');
  const saved=await page.evaluate(async()=>WingWorkspace.snapshot(collectParams(),null,WingWorkspace.captureView(document,state,workspaceUI)));
  assert.deepEqual(saved.parameters['loft.vertical_shift_stations'],committed);assert.equal(saved.parameters['loft.vertical_shift_interpolation'],'cosine');assert.equal(saved.parameters['planform.twist_tip'],-4);
  assert.equal(maxActive,1);assert(!requests.some(r=>['/api/generate','/api/prepare_workspace','/api/aerodynamics/run'].includes(r.path)));assert.deepEqual(errors,[]);
  checks.push('Study serialization retains XY edits, and preview requests run one at a time without generating a FEM or solving aerodynamics.');
  await page.evaluate(()=>document.activeElement?.blur());await page.mouse.move(1680,1080);await page.waitForTimeout(300);await page.screenshot({path:path.join(out,'live-loft-controls.png')});
  await page.evaluate(()=>setWorkspaceMaximized(null));await page.locator('[data-loft-plot=vertical_shift]').scrollIntoViewIfNeeded();await page.screenshot({path:path.join(out,'live-loft-surface.png')});
  fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,maxActive,previewRequests:requests.filter(r=>r.path==='/api/geometry_preview').length,committed},null,2));console.log(JSON.stringify({passed:true,checks,errors,maxActive}));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png'),timeout:5000}).catch(()=>{});const stateSnapshot=await page.evaluate(()=>({method:document.getElementById('p-loft.vertical_shift_interpolation')?.value,geometry:readAuthoredGeometry(),signature:state.geometryPreview?.signature})).catch(()=>null);fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,errors,requests,stateSnapshot},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
