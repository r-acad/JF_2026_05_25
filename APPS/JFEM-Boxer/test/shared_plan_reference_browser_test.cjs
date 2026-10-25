"use strict";
// node shared_plan_reference_browser_test.cjs <evidence-dir> <playwright-module>
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
const near=(a,b)=>assert(Math.abs(a-b)<=1e-8*Math.max(1,Math.abs(a),Math.abs(b)),`${a} != ${b}`);
(async()=>{fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});const errors=[];
try{const page=await browser.newPage({viewport:{width:1400,height:1100}});page.on('pageerror',e=>errors.push(e.message));
 await page.setContent('<style>body{background:#132334;color:white;font:14px system-ui}#views{display:grid;grid-template-columns:1fr 1fr}.view{min-width:0}svg{width:100%;height:320px}polygon{fill:#789abe;stroke:white}</style><div id="views">'+['planform','spars','master-ribs','airfoil:1'].map((key,i)=>`<div class="view"><svg id="v${i}" viewBox="0 0 600 400"><polygon points="80,80 540,80 350,300 80,300"/></svg></div>`).join('')+'</div>');
 await page.addStyleTag({path:path.join(web,'svg_viewport.css')});await page.addScriptTag({path:path.join(web,'svg_viewport.js')});
 await page.evaluate(()=>{window.views=[];window.maps=[{origin:{x:20,y:40},x:{x:20,y:0},y:{x:0,y:20}},{origin:{x:100,y:60},x:{x:80,y:0},y:{x:0,y:80}},{origin:{x:5,y:-12},x:{x:35,y:0},y:{x:0,y:35}},{origin:{x:0,y:0},x:{x:1,y:0},y:{x:0,y:1}}];['planform','spars','master-ribs','airfoil:1'].forEach((key,i)=>{views[i]=WingSVGViewport.install(document.getElementById('v'+i),{key});views[i].setMetric(maps[i]);});});
 const png=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=100;c.height=80;const ctx=c.getContext('2d');ctx.fillStyle='#ab5566';ctx.fillRect(0,0,100,80);return c.toDataURL();}),upload=async(i,name,choice)=>{await page.locator('.view').nth(i).locator('[data-svgv=file]').setInputFiles({name,mimeType:'image/png',buffer:Buffer.from(png.split(',')[1],'base64')});if(choice)await page.locator('.svgv-image-scope-dialog button[value='+choice+']').click();await page.waitForFunction(({i,name})=>views[i].capture().image?.name===name,{i,name});};
 const physical=()=>page.evaluate(()=>views.slice(0,3).map((v,i)=>WingSVGViewport.referenceInModel(v.capture(),maps[i])));
 const equalPhysical=async()=>{const v=await physical();for(const s of v.slice(1)){assert.equal(s.image?.name,v[0].image?.name);near(s.opacity,v[0].opacity);assert.equal(s.imageAspectRatio,v[0].imageAspectRatio);for(const k of ['x','y','scale'])near(s.transform[k],v[0].transform[k]);assert.equal(!!s.pin,!!v[0].pin);if(s.pin)for(const key of ['image','drawing'])for(const k of ['x','y'])near(s.pin[key][k],v[0].pin[key][k]);}return v[0];};
 await upload(0,'shared.png');await equalPhysical();assert.equal(await page.evaluate(()=>views[3].capture().image),null);
 // Image appearance and registration share model coordinates, independent of camera zoom.
 await page.evaluate(()=>{const s=views[1].capture();views[1].restore({...s,opacity:.31,imageAspectRatio:2.2,pin:{image:{x:20,y:25},drawing:{x:260,y:220}},transform:{x:128,y:126.25,scale:3.75},viewport:{x:30,y:20,scale:2}});});
 const shared=await equalPhysical();assert.equal(shared.opacity,.31);assert.equal(shared.imageAspectRatio,2.2);
 const canonical=await page.evaluate(()=>WingSVGViewport.getSharedReference());await page.evaluate(()=>{window.notifications=0;WingSVGViewport.subscribeSharedReference(()=>notifications++);for(let i=0;i<12;i++){views[1].setMetric(maps[1]);const s=views[1].capture();views[1].restore({...s,viewport:{...s.viewport,x:i}});}});assert.equal(await page.evaluate(()=>notifications),0);assert.deepEqual(await page.evaluate(()=>WingSVGViewport.getSharedReference()),canonical);
 await upload(1,'local.png','local');assert.equal((await physical())[0].image.name,'shared.png');assert.equal((await physical())[2].image.name,'shared.png');
 await page.evaluate(()=>{const s=views[1].capture();views[1].restore({...s,opacity:.83});});assert.equal((await physical())[0].opacity,.31);
 // Serialized studies contain one copy of the shared bitmap plus any intentional local image.
 const saved=await page.evaluate(()=>WingSVGViewport.captureAll());assert.equal(Object.values(saved).filter(v=>v.image).length,2);assert.equal(saved.spars.imageScope,'local');assert.equal(saved.planform.image,null);assert.equal(saved['shared-plan-reference'].image.name,'shared.png');
 await page.evaluate(s=>{WingSVGViewport.restoreAll(JSON.parse(JSON.stringify(s)));views.forEach((v,i)=>v.setMetric(maps[i]));},saved);assert.equal((await physical())[1].image.name,'local.png');near((await physical())[0].opacity,.31);
 await upload(2,'replace-all.png','shared');await equalPhysical();assert(await page.evaluate(()=>views.slice(0,3).every(v=>v.capture().imageScope==='shared')));
 const dedup=await page.evaluate(()=>WingSVGViewport.captureAll());assert.equal(Object.values(dedup).filter(v=>v.image).length,1);
 await page.evaluate(s=>{WingSVGViewport.restoreAll(JSON.parse(JSON.stringify(s)));views.forEach((v,i)=>v.setMetric(maps[i]));},dedup);await equalPhysical();
 // Study hydration must not reinterpret old SVG pixels after a new geometry scale.
 const stable=await page.evaluate(()=>WingSVGViewport.getSharedReference());
 await page.evaluate(s=>{WingSVGViewport.restoreAll(s);maps=maps.map((m,i)=>i===3?m:{...m,origin:{x:m.origin.x+30,y:m.origin.y-11},x:{x:m.x.x*1.7,y:0},y:{x:0,y:m.y.y*1.7}});views.forEach((v,i)=>v.setMetric(maps[i]));},dedup);
 await equalPhysical();assert.deepEqual(await page.evaluate(()=>WingSVGViewport.getSharedReference()),stable);
 await page.evaluate(()=>WingSVGViewport.setSharedReference(null));assert(await page.evaluate(()=>views.slice(0,3).every(v=>v.capture().image===null)));
 await page.evaluate(s=>WingSVGViewport.setSharedReference(s),stable);
 // A legacy study with one plan image is promoted; explicit local images in new studies are retained.
 await page.evaluate(()=>{const s=views[0].capture();delete s.imageScope;WingSVGViewport.restoreAll({planform:s});views.forEach((v,i)=>v.setMetric(maps[i]));});await equalPhysical();assert.equal(await page.evaluate(()=>views[1].capture().imageScope),'shared');
 await page.evaluate(()=>{const a=views[0].capture(),b=views[1].capture();delete a.imageScope;delete b.imageScope;b.image.name='legacy-different.png';WingSVGViewport.restoreAll({planform:a,spars:b});views.forEach((v,i)=>v.setMetric(maps[i]));});assert.equal(await page.evaluate(()=>views[1].capture().image.name),'legacy-different.png');assert.equal(await page.evaluate(()=>views[0].capture().imageScope),'local');
 await page.screenshot({path:path.join(out,'shared-reference-images.png')});assert.deepEqual(errors,[]);const receipt={passed:true,physical_alignment:true,appearance_and_pin_sharing:true,camera_independence:true,scope_dialog:true,local_exception:true,replace_all:true,serialization_deduplicated:true,legacy_single_image_promoted:true,legacy_different_images_preserved:true,airfoils_separate:true,no_float_notification_loop:true,geometry_scale_reload:true,clear_shared_image:true,errors};fs.writeFileSync(path.join(out,'receipt.json'),JSON.stringify(receipt,null,2));console.log(receipt);
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
