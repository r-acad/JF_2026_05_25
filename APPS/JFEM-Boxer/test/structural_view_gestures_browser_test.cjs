'use strict';
// node structural_view_gestures_browser_test.cjs <evidence-dir> <playwright-module>
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
const base={'planform.area':4,'planform.aspect_ratio':4,'planform.taper_ratio':1,'planform.sweep':0,'planform.sweep_ref_xc':.25,'planform.root_ref_x':0,'planform.root_ref_y':0,'planform.root_ref_z':0,'planform.dihedral':0,'planform.twist_tip':0,'planform.twist_axis_xc':.25,'planform.leading_edge_points':[],'planform.trailing_edge_points':[],'box.front_spar_xc':.2,'box.rear_spar_xc':.7,'box.front_spar_points':[{eta:.5,dxc:.01}],'box.rear_spar_points':[],'box.stringer_angle':0,'box.stringer_pitch':.1,'mesh.stringer_runout_ratio':.5,'mesh.elements_between_ribs':3,'box.end_eta':1,'box.rib_pitch':.5,'ribs.masters':[{eta:.5,mode:'flight_direction',angle:90,pitch:.5}]};
const near=(a,b)=>assert(Math.abs(a-b)<2e-4,`${a} != ${b}`);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,channel:'chrome'}),checks=[],errors=[];
 try{
  for(const kind of ['spars','ribs','stringers']){
   const page=await browser.newPage({viewport:{width:1400,height:1200}});page.on('pageerror',error=>errors.push(error.message));
   await page.setContent('<!doctype html><section id="host"></section><div id="params" hidden></div>');
   for(const file of ['style.css','svg_viewport.css','planform_view.css','spar_view.css','rib_layout.css'])await page.addStyleTag({path:path.join(web,file)});
   await page.addStyleTag({content:'html,body{overflow:auto}body{margin:20px}#host{width:1000px}.planform-editor-sticky,.rl-preview{position:relative!important}#host svg{width:100%;height:425px;max-height:none}'});
   for(const file of ['numbers.js','svg_viewport.js','planform_view.js','spar_view.js','rib_layout.js','stringer_layout.js'])await page.addScriptTag({path:path.join(web,file)});
   await page.evaluate(({kind,base})=>{
    window.locked=false;window.edits=0;const hidden=document.getElementById('params');for(const [key,value]of Object.entries(base)){const input=document.createElement('input');input.id='p-'+key;input.value=JSON.stringify(value);hidden.append(input);}
    window.readValues=()=>Object.fromEntries(Object.keys(base).map(key=>[key,JSON.parse(document.getElementById('p-'+key).value)]));
    const host=document.getElementById('host'),options={readValues,isLocked:()=>locked,onEdit:()=>edits++};
    window.testEditor=kind==='spars'?WingSparView.install(host,options):kind==='ribs'?WingRibLayout.install(host,options):WingStringerLayout.install(host,{...options,read:()=>readValues()['box.rear_spar_points']});window.testView=testEditor.viewport;window.svg=host.querySelector('svg');
   },{kind,base});
   const svg=page.locator('#host svg'),capture=()=>page.evaluate(()=>testView.capture());
   const point=selector=>page.locator(selector).first().evaluate(element=>{let p;if(element.tagName.toLowerCase()==='circle')p={x:Number(element.getAttribute('cx')),y:Number(element.getAttribute('cy'))};else p=element.getPointAtLength(element.getTotalLength()*.43);const m=element.getScreenCTM();return{x:m.a*p.x+m.c*p.y+m.e,y:m.b*p.x+m.d*p.y+m.f};});
   const drag=async(start,dx=150,dy=80)=>{await page.mouse.move(start.x,start.y);await page.mouse.down();await page.mouse.move(start.x+dx,start.y+dy,{steps:4});await page.mouse.up();};
   const fit=()=>page.evaluate(()=>{const state=testView.capture();testView.restore({...state,viewport:{x:0,y:0,scale:1}});});
   if(kind==='stringers'){
    const selector='#stringer-layout-svg [data-stringer="reference-2"]',start=await point(selector),before=await capture(),paramsBefore=await page.evaluate(()=>readValues());
    await page.mouse.click(start.x,start.y);assert.equal(await page.locator(selector+'.sl-selected').count(),1,'A plain click still highlights the stringer');
    await drag(await point(selector));const after=await capture();assert(after.viewport.scale>before.viewport.scale);assert.deepEqual(await page.evaluate(()=>readValues()),paramsBefore);assert.equal(await page.evaluate(()=>edits),0);assert.equal(await page.locator(selector+'.sl-selected').count(),1,'Window drag must not toggle the selection');
    await fit();await page.locator(selector).focus();await page.keyboard.press('Enter');assert.equal(await page.locator(selector+'.sl-selected').count(),0,'Keyboard selection remains available');
    checks.push('Stringers: click/keyboard highlighting retained; default left-drag starting on a stringer line zooms without changing parameters or selection');
   }else{
    const enabled=kind==='spars'?'#spar-editor-svg [data-edge="0"][data-eta="0.5"] .pf-point-dot':'#rib-layout-svg [data-rib-eta="0.5"][data-rib-part="anchor"] circle';
    const before=await capture(),paramsBefore=await page.evaluate(()=>readValues());await drag(await point(enabled),20,0);const after=await capture();assert.deepEqual(after.viewport,before.viewport);assert.notDeepEqual(await page.evaluate(()=>readValues()),paramsBefore,'Editable handle retains its model edit');
    checks.push(kind+': an enabled geometry handle still drags its parameter rather than zooming');
    await page.evaluate(()=>{locked=true;document.getElementById('host').dispatchEvent(new Event('parameterlockchange'));});
    const disabled=kind==='spars'?'#spar-editor-svg [aria-disabled="true"] .pf-point-dot':'#rib-layout-svg .rl-angle-handle[aria-disabled="true"] circle',paramsLocked=await page.evaluate(()=>readValues()),beforeLocked=await capture();await drag(await point(disabled));assert((await capture()).viewport.scale>beforeLocked.viewport.scale);assert.deepEqual(await page.evaluate(()=>readValues()),paramsLocked);
    checks.push(kind+': disabled/locked handle permits default window zoom without editing the model');
    await fit();
    if(kind==='ribs'){
     await page.evaluate(()=>{locked=false;document.getElementById('host').dispatchEvent(new Event('parameterlockchange'));});
     const fixed='#rib-layout-svg [data-rib-eta="0"][data-rib-part="anchor"] circle',beforeFixed=await capture(),paramsFixed=await page.evaluate(()=>readValues());await drag(await point(fixed));assert((await capture()).viewport.scale>beforeFixed.viewport.scale);assert.deepEqual(await page.evaluate(()=>readValues()),paramsFixed);
     checks.push('Ribs: a fixed root master handle allows window zoom even when intermediate masters remain editable');
    }
   }
   if(kind==='spars'){
    await page.evaluate(()=>testView.restore({...testView.capture(),imageScope:'local',image:{name:'pixel.png',width:1,height:1,dataUrl:'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII='},transform:{x:50,y:40,scale:150},viewport:{x:0,y:0,scale:1}}));
    await page.locator('[data-svgv="snap-enabled"]').check();await page.locator('[data-svgv-pin="pick"]').click();
    const source=await svg.evaluate(el=>{const m=el.getScreenCTM();return{x:m.a*125+m.c*115+m.e,y:m.b*125+m.d*115+m.f};});await page.mouse.click(source.x,source.y);
    const target=await page.locator('.sf-rib-datum[data-rib="3"] line').evaluate(el=>{const x=(Number(el.getAttribute('x1'))+Number(el.getAttribute('x2')))/2,y=(Number(el.getAttribute('y1'))+Number(el.getAttribute('y2')))/2,m=el.getScreenCTM();return{x,y,clientX:m.a*x+m.c*y+m.e,clientY:m.b*x+m.d*y+m.f};});
    await page.mouse.click(target.clientX+4,target.clientY);const pinned=await capture();assert(pinned.pin);near(pinned.pin.drawing.x,target.x);near(pinned.pin.drawing.y,target.y);near(pinned.transform.x+pinned.pin.image.x*pinned.transform.scale,target.x);near(pinned.transform.y+pinned.pin.image.y*pinned.transform.scale,target.y);
    checks.push('Spars: image pin snaps to the interior of a visible rib datum line from four screen pixels away, and immediately aligns the image');
   }
   await svg.screenshot({path:path.join(out,kind+'-gesture-controls.png')});await page.close();
  }
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'structural_view_gestures.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){console.error(error.stack);throw error;}finally{await browser.close();}
})().catch(()=>{process.exitCode=1;});
