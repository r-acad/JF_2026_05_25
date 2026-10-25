'use strict';
// node test/reference_scale_link_browser_test.cjs EVIDENCE_DIR PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
const near=(a,b)=>a.forEach((v,i)=>assert(Math.abs(v-b[i])<1e-10*Math.max(1,Math.abs(b[i])),JSON.stringify({a,b})));
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],checks=[];
 const server=http.createServer((req,res)=>{const name=new URL(req.url,'http://localhost').pathname.slice(1);if(!name){res.setHeader('Content-Type','text/html; charset=utf-8');return res.end('<!doctype html><head><link rel="stylesheet" href="/reference.css"><style>body{font:13px system-ui;background:#13202b;color:#dcebf6;display:flex;align-items:start}canvas{width:500px;height:500px}#reference-panel{width:340px}button{background:#243b4f;color:white;border:1px solid #426078;border-radius:4px;padding:6px}</style></head><canvas id="view" width="500" height="500"></canvas><section id="reference-panel"></section>');}if(name==='favicon.ico')return res.end();const file=path.resolve(web,name);if(!file.startsWith(web+path.sep)){res.statusCode=403;return res.end();}res.setHeader('Content-Type',(name.endsWith('.css')?'text/css':'application/javascript')+'; charset=utf-8');fs.createReadStream(file).pipe(res);});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch({headless:true,channel:'chrome',args:['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1000,height:1300}});page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto('http://127.0.0.1:'+server.address().port);for(const file of ['vendor/babylon.js','vendor/babylonjs.loaders.min.js','reference.js'])await page.addScriptTag({url:'/'+file});
  await page.evaluate(async()=>{
   const B=BABYLON;window.engine=new B.Engine(document.getElementById('view'),true);window.scene=new B.Scene(engine);window.camera=new B.ArcRotateCamera('camera',-Math.PI/3,Math.PI/3,8,B.Vector3.Zero(),scene);new B.HemisphericLight('light',new B.Vector3(0,1,0),scene);window.changes=0;
   window.reference=WingReference.create({scene,camera,engine,host:document.getElementById('reference-panel'),onChange:()=>changes++});
   window.obj='v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3\nf 1 3 4\n';
   await reference.importFile(new File([obj],'first.obj'));reference.setMode('off');scene.render();
  });
  const scale=()=>page.evaluate(()=>reference.getTransform().scale),edit=async(axis,value)=>{const input=page.locator('#reference-scale-'+axis);await input.fill(String(value));await input.press('Tab');};
  assert.equal(await page.locator('#reference-scale-linked').isChecked(),false);await page.locator('#reference-scale-linked').check();near(await scale(),[1,1,1]);await edit('x',2);near(await scale(),[2,2,2]);
  assert.equal(await page.evaluate(()=>['xGizmo','yGizmo','zGizmo'].every(axis=>reference.gizmos.gizmos.scaleGizmo[axis].uniformScaling)),true);
  checks.push('Linking changes no existing scale; equal XYZ values and all scale handles remain uniformly linked');
  await page.evaluate(()=>reference.setTransform({scale:[2,3,4]}));await edit('x',4);near(await scale(),[4,6,8]);await edit('z',2);near(await scale(),[1,1.5,2]);
  assert.match(await page.locator('#reference-scale-linked').getAttribute('title'),/ratios are preserved/);
  checks.push('Linked numeric edits preserve existing unequal proportions for increasing and decreasing scale');
  await page.locator('#reference-scale-linked').uncheck();await edit('y',3);near(await scale(),[1,3,2]);assert.equal(await page.evaluate(()=>reference.gizmos.gizmos.scaleGizmo.yGizmo.uniformScaling),false);
  await page.locator('#reference-scale-linked').check();const previous=await scale();await edit('x',0);near(await scale(),previous);assert.match(await page.locator('#reference-scale-x').evaluate(el=>el.validationMessage),/positive/);await edit('x',2);near(await scale(),[2,6,4]);
  checks.push('Unlinked axes edit independently; invalid scale input leaves the model unchanged');
  const first=await page.evaluate(()=>reference.active.id);await page.evaluate(async()=>{await reference.importFile(new File([obj],'second.obj'));reference.setMode('off');});assert.equal(await page.locator('#reference-scale-linked').isChecked(),false);
  await page.evaluate(id=>reference.select(id),first);assert.equal(await page.locator('#reference-scale-linked').isChecked(),true);near(await scale(),[2,6,4]);
  await page.locator('#reference-lock').check();assert.equal(await page.locator('#reference-scale-linked').isDisabled(),true);await page.evaluate(()=>reference.setScaleAxis(0,99));near(await scale(),[2,6,4]);
  checks.push('Each reference retains its own link setting; placement lock blocks linked scale edits');
  const portable=await page.evaluate(async()=>{const items=await reference.exportPortable(),before=items.map(x=>({name:x.metadata.source_name,scale:x.metadata.scale,linked:x.metadata.scale_linked,locked:x.metadata.locked})),staged=await reference.stagePortable(items.map(({metadata,bytes})=>({metadata,file:new File([bytes],metadata.source_name)})),{selectedIndex:0,mode:'off'});staged.commit();staged.finalize();return {before,after:reference.entries.map(e=>({name:e.name,scale:reference.getTransform(e).scale,linked:e.scaleLinked,locked:e.locked}))};});
  assert.deepEqual(portable.after,portable.before);assert.equal(await page.locator('#reference-scale-linked').isChecked(),true);assert.equal(await page.locator('#reference-scale-linked').isDisabled(),true);
  await page.locator('#reference-panel').screenshot({path:path.join(out,'reference-linked-scale.png')});
  const legacy=await page.evaluate(async()=>{const items=await reference.exportPortable();items.forEach(x=>delete x.metadata.scale_linked);const staged=await reference.stagePortable(items.map(({metadata,bytes})=>({metadata,file:new File([bytes],metadata.source_name)})),{selectedIndex:0,mode:'off'});staged.commit();staged.finalize();return {linked:reference.active.scaleLinked,scale:reference.getTransform().scale};});assert.equal(legacy.linked,false);near(legacy.scale,[2,6,4]);
  checks.push('Portable Study metadata round-trips linked scale and locks; older records load unlinked without changing numeric scaling');
  await page.evaluate(()=>{reference.setLocked(false);reference.setScaleLinked(true);reference.active.assetPath='fixture.obj';reference.active.savedId='fixture';});const record=await page.evaluate(()=>reference.serialize()[0]);assert.equal(record.scale_linked,true);near(record.scale,[2,6,4]);
  checks.push('Linked TOML records include the same per-reference scale_linked setting');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'reference_scale_link.json'),JSON.stringify({passed:true,checks,portable,legacy,errors},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(error){await page.screenshot({path:path.join(out,'reference-scale-failure.png'),fullPage:true});throw error;}finally{await page.evaluate(()=>engine?.dispose()).catch(()=>{});await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
