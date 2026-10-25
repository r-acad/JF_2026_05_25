'use strict';
// node test/movable_preview_style_browser_test.cjs URL OUTPUT PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[4]),out=path.resolve(process.argv[3]);fs.mkdirSync(out,{recursive:true});
(async()=>{const browser=await chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']}),page=await browser.newPage({viewport:{width:1600,height:1100}}),errors=[],checks=[];
page.on('pageerror',e=>errors.push(e.message));
try{
 await page.goto(process.argv[2]);await page.getByRole('button',{name:'Start new study',exact:true}).click();
 const ready=()=>page.waitForFunction(()=>state.data?.nodes?.count&&!state.meshRequestInFlight&&!state.workspaceBusy&&!state.loadingInput,null,{timeout:180000});await ready();
 await page.evaluate(()=>{document.getElementById('auto-save').checked=false;state.autosave?.destroy();document.getElementById('auto-mesh').checked=false;document.getElementById('auto-mesh').dispatchEvent(new Event('change',{bubbles:true}));activateWorkspaceTab('movablesurfaces');});
 const preview=n=>page.waitForFunction(n=>state.movablePreview?.meshes.length===2*n&&document.querySelector('#movable-status')?.textContent.startsWith(n+' movable'),n,{timeout:120000});
 await page.locator('#movable-add').click();await preview(1);
 assert.equal(await page.locator('#movable-preview-style').inputValue(),'translucent');
 assert.equal(await page.evaluate(()=>state.movablePreview.meshes[0].material.alpha),.3);checks.push('New control-surface preview is translucent by default');
 await page.locator('.movable-surface').first().locator('[data-movable-field=eta_start]').fill('.1');
 await page.locator('.movable-surface').first().locator('[data-movable-field=eta_end]').fill('.8');await preview(1);
 await page.locator('#movable-add').click();await preview(2);
 const rows=await page.evaluate(()=>state.movableEditor.readDrafts()['movable_surfaces.items']);assert.equal(rows[1].eta_start,.8);assert.equal(rows[1].eta_end,1);assert(await page.locator('#movable-add').isDisabled());assert.match(await page.locator('#movable-add').getAttribute('title'),/outboard span/);checks.push('New surface is appended beyond the existing outboard edge, and tip exhaustion is explained');
 const png=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=500;c.height=220;const x=c.getContext('2d');x.fillStyle='#fff';x.fillRect(0,0,500,220);x.fillStyle='#9fb4a0';x.fillRect(0,70,500,80);x.strokeStyle='#273b66';for(let i=0;i<500;i+=20){x.beginPath();x.moveTo(i,0);x.lineTo(i,220);x.stroke();}x.fillStyle='#173c73';x.font='25px sans-serif';x.fillText('REFERENCE IMAGE',70,120);return c.toDataURL();});
 await page.locator('#movable-plan-view').locator('..').locator('[data-svgv=file]').setInputFiles({name:'movable-reference.png',mimeType:'image/png',buffer:Buffer.from(png.split(',')[1],'base64')});
 await page.waitForFunction(()=>document.getElementById('movable-plan-view').wingViewport.capture().image?.name==='movable-reference.png');
 const fills=await page.locator('#movable-plan-view').evaluate(svg=>Array.from(svg.querySelectorAll('.svgv-geometry polygon')).map(e=>({opacity:Number(getComputedStyle(e).fillOpacity),fill:getComputedStyle(e).fill})));
 assert(fills.length>=3);assert(fills.every(x=>x.opacity<=.2));checks.push('Plan outline and movable footprints remain translucent over the embedded image');
 await page.locator('#movable-plan-view').screenshot({path:path.join(out,'movable-reference-visible.png')});
 for(const style of ['solid','wireframe','metallic','translucent']){
  await page.locator('#movable-preview-style').selectOption(style);
  const info=await page.evaluate(()=>{const p=state.movablePreview,m=p.meshes[0],mat=m.material;return{style:p.style,alpha:mat.alpha,wire:mat.wireframe,zOffset:mat.zOffset,normalCount:m.getVerticesData(BABYLON.VertexBuffer.NormalKind).length,metallic:mat.metallic,reflection:!!mat.reflectionTexture,finiteNormals:m.getVerticesData(BABYLON.VertexBuffer.NormalKind).every(Number.isFinite),enabled:m.isEnabled()};});
  assert.equal(info.style,style);assert.equal(info.alpha,style==='translucent'?.3:1);assert.equal(info.wire,style==='wireframe');assert(info.enabled&&info.normalCount>0&&info.finiteNormals);if(style==='wireframe')assert.equal(info.zOffset,0);if(style==='metallic')assert(info.metallic===1&&info.reflection);
  await page.waitForTimeout(350);
 }
 checks.push('Solid, wireframe and metallic use valid normals, WebGPU-safe wire bias and offline reflections');
 await page.locator('#movable-preview-style').selectOption('metallic');
 const text=await page.evaluate(async()=>{window.studyWrite=null;window.showSaveFilePicker=async()=>({kind:'file',name:'movable-finish.wingfem.json',queryPermission:async()=> 'granted',requestPermission:async()=> 'granted',createWritable:async()=>({write:async text=>{studyWrite=text;},close:async()=>{},abort:async()=>{}})});if(!await saveModelDefinition({saveAs:true,noteText:'Movable finish and background round trip.'}))throw Error('Save failed');return studyWrite;});
 assert.equal(JSON.parse(text).view.controls['movable-preview-style'],'metallic');fs.writeFileSync(path.join(out,'movable-finish.wingfem.json'),text);
 await page.evaluate(async text=>{if(!await loadModelDefinition(new File([text],'movable-finish.wingfem.json',{type:'application/json'}),{recent:true}))throw Error('Reopen failed');},text);await ready();await preview(2);
 assert.equal(await page.locator('#movable-preview-style').inputValue(),'metallic');assert.equal(await page.evaluate(()=>state.movablePreview.style),'metallic');checks.push('Actual Save and reopen preserve the finish and visible preview');
 const legacy=JSON.parse(text);delete legacy.view.controls['movable-preview-style'];
 await page.evaluate(async text=>{if(!await loadModelDefinition(new File([text],'legacy-movable.wingfem.json',{type:'application/json'}),{recent:true}))throw Error('Legacy reopen failed');},JSON.stringify(legacy));await ready();await preview(2);
 assert.equal(await page.locator('#movable-preview-style').inputValue(),'translucent');assert.equal(await page.evaluate(()=>state.movablePreview.meshes[0].material.alpha),.3);checks.push('Older studies reset absent finish to translucent rather than inheriting the previous study');
 await page.evaluate(()=>{activateWorkspaceTab('movablesurfaces');applyBackgroundColor('#ffffff',false);fitView();});await page.waitForTimeout(300);await page.screenshot({path:path.join(out,'movable-preview-app.png')});
 assert.deepEqual(errors,[]);const result={passed:true,checks,engine:await page.evaluate(()=>state.scene.getEngine().isWebGPU?'WebGPU':'WebGL'),errors};fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));
}catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({message:error.message,checks,errors},null,2));throw error;}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
