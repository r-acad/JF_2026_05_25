"use strict";
// node svg_registration_browser_test.cjs <evidence-dir> <playwright-module>
// CHROME_PATH optionally selects an installed browser; otherwise use Playwright Chromium.
const fs=require("node:fs"),path=require("node:path"),assert=require("node:assert/strict");
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,"../web");
const image={name:"pixel.png",width:1,height:1,dataUrl:"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII="};
const base={"planform.area":32,"planform.aspect_ratio":8,"planform.taper_ratio":.5,"planform.sweep":10,"planform.sweep_ref_xc":.25,"planform.root_ref_x":1,"planform.root_ref_y":2,"planform.root_ref_z":3,"planform.dihedral":0,"planform.twist_tip":0,"planform.twist_axis_xc":.25,"planform.leading_edge_points":[],"planform.trailing_edge_points":[],"box.front_spar_xc":.2,"box.rear_spar_xc":.55,"box.front_spar_points":[],"box.rear_spar_points":[],"box.stringer_angle":0,"box.end_eta":.75,"box.rib_pitch":.6,"leading_edge.enabled":false,"leading_edge.start_rib":1,"leading_edge.end_rib":0,"leading_edge.disabled_bays":""};
const near=(a,b)=>assert(Math.abs(a-b)<2e-5*Math.max(1,Math.abs(b)),`${a} != ${b}`);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});const errors=[],checks=[];
 try{
  for(const kind of ["shared","detached"]){
   const page=await browser.newPage({viewport:{width:1450,height:1050}});page.on("pageerror",e=>errors.push(e.message));
   await page.setContent('<!doctype html><style>html,body{margin:0;background:#101b26}#view{height:100vh}#shared{width:1000px;margin:20px}#shared svg{width:900px;height:600px}polygon{fill:#4682b4;stroke:#4ff}text{fill:#fff}</style><div id="view"></div><div id="shared"><svg viewBox="0 0 600 400"><defs><marker id="arrow"><path id="arrow-glyph" d="M0 0 L8 4 L0 8Z" fill="green"/></marker></defs><polygon id="area" points="100,100 300,100 300,220 100,220"/><g data-edge="0" role="button"><circle id="edit-handle" cx="400" cy="200" r="8" fill="yellow"/></g><text id="label" x="120" y="120">Reference</text></svg></div>');
   for(const f of ["svg_viewport.css","planform_view.css","dimensioned_plan_view.css"])await page.addStyleTag({path:path.join(web,f)});
   for(const f of ["numbers.js","planform_view.js","spar_view.js","rib_layout.js","leading_edge_gaps.js","svg_viewport.js","fuel_tank_view.js","dimensioned_plan_view.js"])await page.addScriptTag({path:path.join(web,f)});
   await page.evaluate(({kind,base,image})=>{
    window.parameters=base;window.modelEdits=0;
    if(kind==="shared"){document.getElementById("view").remove();const svg=document.querySelector("svg");window.testView=WingSVGViewport.install(svg,{key:"planform",isGeometryTarget:t=>!!t.closest("[data-edge]")});svg.addEventListener("pointerdown",e=>{if(e.target.closest("[data-edge]"))modelEdits++;});}
    else{document.getElementById("shared").remove();window.testView=WingDimensionedPlanView.install(document.getElementById("view"),{readValues:()=>parameters});}
    testView.restore({...testView.capture(),image,transform:{x:100,y:60,scale:160},snap:{enabled:true,points:true,lines:true}});
   },{kind,base,image});
   const svg=page.locator("svg"),capture=()=>page.evaluate(()=>testView.capture()),control=name=>page.locator(`[data-${kind==="shared"?"svgv":"dpv"}="${name}"]`);
   const client=async p=>svg.evaluate((el,p)=>{const m=el.getScreenCTM();return{x:m.a*p.x+m.c*p.y+m.e,y:m.b*p.x+m.d*p.y+m.f};},p);
   const clickPoint=async p=>{const q=await client(p);await page.mouse.click(q.x,q.y);};
   const wheel=async(alt=false,ctrl=false)=>{const q=await client({x:500,y:300});await svg.evaluate((el,{q,alt,ctrl})=>el.dispatchEvent(new WheelEvent("wheel",{clientX:q.x,clientY:q.y,deltaY:-100,altKey:alt,ctrlKey:ctrl,bubbles:true,cancelable:true})),{q,alt,ctrl});await page.waitForTimeout(140);};
   const original=await capture();await wheel();const normal=(await capture()).viewport.scale;await page.evaluate(s=>testView.restore(s),original);await wheel(true);const fine=(await capture()).viewport.scale;near(Math.log(fine/original.viewport.scale),.1*Math.log(normal/original.viewport.scale));
   await page.evaluate(s=>testView.restore(s),original);await wheel(false,true);const normalImage=(await capture()).transform.scale;await page.evaluate(s=>testView.restore(s),original);await wheel(true,true);near(Math.log((await capture()).transform.scale/original.transform.scale),.1*Math.log(normalImage/original.transform.scale));
   await page.evaluate(s=>testView.restore(s),original);
   await page.locator('[data-svgv-pin="pick"]').click();await clickPoint({x:140,y:140});
   const drawing=kind==="shared"?{x:400,y:200}:await page.locator(".pf-wing").evaluate(el=>({x:el.points.getItem(0).x,y:el.points.getItem(0).y}));
   await clickPoint({x:drawing.x+3,y:drawing.y});const pinned=await capture();assert(pinned.pin);near(pinned.pin.image.x,.25);near(pinned.pin.image.y,.5);near(pinned.pin.drawing.x,drawing.x);near(pinned.pin.drawing.y,drawing.y);assert.equal(await page.evaluate(()=>modelEdits),0);
   const checkPin=s=>{near(s.transform.x+s.transform.scale*s.pin.image.x,s.pin.drawing.x);near(s.transform.y+s.transform.scale*s.pin.image.y,s.pin.drawing.y);};checkPin(pinned);
   await wheel(false,true);const zoomed=await capture();checkPin(zoomed);assert.deepEqual(zoomed.viewport,pinned.viewport);
   const screenPin=s=>({x:s.viewport.x+s.viewport.scale*s.pin.drawing.x,y:s.viewport.y+s.viewport.scale*s.pin.drawing.y});const before=screenPin(zoomed);await wheel();const after=screenPin(await capture());near(before.x,after.x);near(before.y,after.y);
   await control("zoom").fill("250");await control("zoom").press("Tab");near((await capture()).viewport.scale,2.5);checkPin(await capture());
   if(kind==="shared")await page.locator(".svgv-image-options summary").first().click();else await control("image-tools").click();
   await control("scale").fill("75");await control("scale").press("Tab");checkPin(await capture());
   await control(kind==="shared"?"filled":"filledFigures").uncheck();assert.equal((await capture()).filledFigures,false);assert.equal(await page.locator(kind==="shared"?"#area":".pf-wing").evaluate(el=>getComputedStyle(el).fill),"none");
   const marker=page.locator(kind==="shared"?"#arrow-glyph":"marker path").first();assert.notEqual(await marker.evaluate(el=>getComputedStyle(el).fill),"none");
   if(kind==="shared"){assert.notEqual(await page.locator("#edit-handle").evaluate(el=>getComputedStyle(el).fill),"none");assert.notEqual(await page.locator("#label").evaluate(el=>getComputedStyle(el).fill),"none");}
   const saved=await capture();await page.evaluate(s=>testView.restore(JSON.parse(JSON.stringify(s))),saved);assert.deepEqual(await capture(),saved);
   if(kind==="shared"){await page.evaluate(()=>{const saved=WingSVGViewport.captureAll();WingSVGViewport.restoreAll(JSON.parse(JSON.stringify(saved)));});assert.deepEqual(await capture(),saved);}
   await page.locator('[data-svgv-pin="pick"]').click();await clickPoint({x:saved.viewport.x+saved.viewport.scale*(saved.transform.x+.5*saved.transform.scale),y:saved.viewport.y+saved.viewport.scale*(saved.transform.y+.5*saved.transform.scale)});await svg.press("Escape");assert.deepEqual(await capture(),saved);
   await page.screenshot({path:path.join(out,kind+"-registered-outline.png")});
   const at=await client(screenPin(saved));await page.keyboard.down("Control");await page.mouse.move(at.x,at.y);await page.mouse.down();await page.mouse.move(at.x+22,at.y+14,{steps:3});await page.keyboard.press("Escape");await page.mouse.up();await page.keyboard.up("Control");assert.deepEqual(await capture(),saved);
   await page.keyboard.down("Control");await page.mouse.move(at.x,at.y);await page.mouse.down();await page.mouse.move(at.x+22,at.y+14,{steps:3});await page.mouse.up();await page.keyboard.up("Control");assert.equal((await capture()).pin,null);await page.evaluate(s=>testView.restore(s),saved);
   await page.locator('[data-svgv-pin="clear"]').click();assert.equal((await capture()).pin,null);
   assert.equal(await page.evaluate(()=>JSON.stringify(parameters)),JSON.stringify(base));
   checks.push({kind,alt_log_step:.1,pin_alignment:true,pin_blocks_geometry_edits:true,geometry_snapping:true,anchored_image_and_view_zoom:true,numeric_zoom:true,filled_geometry_only:true,roundtrip:true,escape_cancel:true,image_pan_clears_pin_cancel_restores:true});await page.close();
  }
  // The legacy in-page dimensioned dialog remains a valid fallback when the
  // app does not supply an external-window callback. Exercise its actual
  // install/refresh branch and schedule-aware properties, not a UI fixture.
  const fallback=await browser.newPage({viewport:{width:1450,height:1050}});fallback.on("pageerror",e=>errors.push(e.message));
  await fallback.setContent('<!doctype html><div id="host"></div><textarea id="p-planform.leading_edge_points" hidden></textarea><textarea id="p-planform.trailing_edge_points" hidden></textarea>');
  for(const f of ["svg_viewport.css","planform_view.css"])await fallback.addStyleTag({path:path.join(web,f)});
  for(const f of ["numbers.js","planform_view.js","svg_viewport.js"])await fallback.addScriptTag({path:path.join(web,f)});
  await fallback.evaluate(base=>{window.parameters={...base,"loft.twist_stations":[{eta:0,twist:2},{eta:1,twist:-3}]};window.modelEdits=0;window.editor=WingPlanformView.install(document.getElementById("host"),{readValues:()=>parameters,onEdit:()=>modelEdits++});},base);
  await fallback.locator("#btn-planform-view").click();assert(await fallback.locator("#planform-view-dialog").evaluate(el=>el.open));
  assert((await fallback.locator("#planform-view-values").innerText()).includes("Dihedral / fallback tip twist"));
  assert.equal(await fallback.locator("#planform-view-svg").evaluate(el=>!!el.wingViewport),true);
  const fallbackZoom=fallback.locator('#planform-view-dialog [data-svgv="zoom"]');await fallbackZoom.fill("125");await fallbackZoom.press("Tab");
  near(await fallback.locator("#planform-view-svg").evaluate(el=>el.wingViewport.capture().viewport.scale),1.25);
  await fallback.locator('#planform-view-dialog [data-svgv="filled"]').uncheck();assert.equal(await fallback.locator("#planform-view-svg .pf-wing").evaluate(el=>getComputedStyle(el).fill),"none");
  assert.equal(await fallback.evaluate(()=>modelEdits),0);await fallback.screenshot({path:path.join(out,"fallback-dialog-outline.png")});await fallback.close();
  checks.push({kind:"inline-fallback-dialog",actual_install_refresh:true,schedule_label:true,numeric_zoom:true,filled_geometry_only:true,model_unchanged:true});
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,"receipt.json"),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
