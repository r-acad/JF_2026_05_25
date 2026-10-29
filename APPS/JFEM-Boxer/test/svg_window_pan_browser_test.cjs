"use strict";
const fs=require("node:fs"),path=require("node:path"),assert=require("node:assert/strict");
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,"../web");
const image={name:"pixel.png",width:1,height:1,dataUrl:"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII="};
const base={"planform.area":32,"planform.aspect_ratio":8,"planform.taper_ratio":.5,"planform.sweep":10,"planform.sweep_ref_xc":.25,"planform.root_ref_x":1,"planform.root_ref_y":2,"planform.root_ref_z":3,"planform.dihedral":0,"planform.twist_tip":0,"planform.twist_axis_xc":.25,"planform.leading_edge_points":[],"planform.trailing_edge_points":[],"box.front_spar_xc":.2,"box.rear_spar_xc":.55,"box.front_spar_points":[],"box.rear_spar_points":[],"box.stringer_angle":0,"box.end_eta":.75,"box.rib_pitch":.6,"leading_edge.enabled":false,"leading_edge.start_rib":1,"leading_edge.end_rib":0,"leading_edge.disabled_bays":""};
const near=(a,b)=>assert(Math.abs(a-b)<2e-5*Math.max(1,Math.abs(b)),`${a} != ${b}`);
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})}),checks=[],errors=[];
 try{
  for(const kind of ["shared","detached","fallback"]){
   const page=await browser.newPage({viewport:{width:1450,height:1050}});page.on("pageerror",e=>errors.push(e.message));
   await page.setContent('<!doctype html><style>html,body{margin:0;background:#101b26;font:13px system-ui}#view{height:100vh}#shared{width:1000px;margin:20px}#shared svg{width:900px;height:600px}polygon{fill:#4682b4;stroke:#4ff}</style><div id="view"></div><div id="shared"><svg viewBox="0 0 600 400"><polygon points="100,100 450,100 450,300 100,300"/><g data-edge="0" role="button"><circle id="edit-handle" cx="300" cy="200" r="8" fill="yellow"/></g></svg></div><textarea id="p-planform.leading_edge_points" hidden></textarea><textarea id="p-planform.trailing_edge_points" hidden></textarea>');
   for(const f of ["svg_viewport.css","planform_view.css","dimensioned_plan_view.css"])await page.addStyleTag({path:path.join(web,f)});
   for(const f of ["numbers.js","planform_view.js","spar_view.js","rib_layout.js","leading_edge_gaps.js","svg_viewport.js","fuel_tank_view.js","dimensioned_plan_view.js"])await page.addScriptTag({path:path.join(web,f)});
   await page.evaluate(({kind,base})=>{window.modelEdits=0;window.parameters=base;
    if(kind==="shared"){document.getElementById("view").remove();const svg=document.querySelector("svg");window.testSvg=svg;window.testView=WingSVGViewport.install(svg,{isGeometryTarget:t=>!!t.closest("[data-edge]")});svg.addEventListener("pointerdown",e=>{if(e.target.closest("[data-edge]"))modelEdits++;});}
    else{document.getElementById("shared").remove();const host=document.getElementById("view");if(kind==="detached"){window.testView=WingDimensionedPlanView.install(host,{readValues:()=>parameters});window.testSvg=host.querySelector("svg");}else{WingPlanformView.install(host,{readValues:()=>parameters,onEdit:()=>modelEdits++});document.getElementById("btn-planform-view").click();window.testSvg=document.getElementById("planform-view-svg");window.testView=testSvg.wingViewport;}}
   },{kind,base});
   await page.evaluate(image=>testView.restore({...testView.capture(),image,pin:{image:{x:.25,y:.5},drawing:{x:400,y:200}},transform:{x:360,y:120,scale:160},viewport:{x:12,y:-9,scale:1.3}}),image);
   const svg=page.locator(kind==="shared"?"#shared svg":kind==="detached"?"#view svg":"#planform-view-svg"),capture=()=>page.evaluate(()=>testView.capture()),restore=s=>page.evaluate(s=>testView.restore(s),s),windowButton=page.locator(kind==="fallback"?'#planform-view-dialog [data-svgv-window="toggle"]':'[data-svgv-window="toggle"]');
   const literalRectangle=()=>svg.locator(".svgv-window-rectangle").evaluate(el=>{const m=el.getScreenCTM(),x=Number(el.getAttribute("x")),y=Number(el.getAttribute("y")),w=Number(el.getAttribute("width")),h=Number(el.getAttribute("height"));return{x:m.a*x+m.c*y+m.e,y:m.b*x+m.d*y+m.f,width:m.a*w,height:m.d*h};});
   const client=async p=>svg.evaluate((el,p)=>{const m=el.getScreenCTM();return{x:m.a*p.x+m.c*p.y+m.e,y:m.b*p.x+m.d*p.y+m.f};},p);
   const pan=async({ctrl=false,cancel=false}={})=>{const before=await capture(),r=await svg.boundingBox(),a={x:r.x+r.width*.45,y:r.y+r.height*.45},b={x:a.x+42,y:a.y+27};const delta=await svg.evaluate((el,{a,b})=>{const m=el.getScreenCTM().inverse();return{x:m.a*(b.x-a.x)+m.c*(b.y-a.y),y:m.b*(b.x-a.x)+m.d*(b.y-a.y)};},{a,b});
    if(ctrl)await page.keyboard.down("Control");await page.mouse.move(a.x,a.y);await page.mouse.down({button:"right"});await page.mouse.move(b.x,b.y,{steps:3});if(cancel)await page.keyboard.press("Escape");await page.mouse.up({button:"right"});if(ctrl)await page.keyboard.up("Control");const after=await capture();
    if(cancel)assert.deepEqual(after,before);else if(ctrl){assert.deepEqual(after.viewport,before.viewport);assert.equal(after.pin,null);near(after.transform.x,before.transform.x+delta.x/before.viewport.scale);near(after.transform.y,before.transform.y+delta.y/before.viewport.scale);}else{assert.deepEqual(after.transform,before.transform);assert.deepEqual(after.pin,before.pin);near(after.viewport.x,before.viewport.x+delta.x);near(after.viewport.y,before.viewport.y+delta.y);}return after;};
   const original=await capture();
   // Double-click returns every shared and detached view to its full drawing,
   // without altering the independently registered reference image or pin.
   const fitRect=await svg.boundingBox();await page.mouse.dblclick(fitRect.x+fitRect.width*.1,fitRect.y+fitRect.height*.1);
   const fitted=await capture();assert.deepEqual(fitted.viewport,{x:0,y:0,scale:1});assert.deepEqual(fitted.transform,original.transform);assert.deepEqual(fitted.pin,original.pin);await restore(original);
   await pan();await pan({ctrl:true});await pan({cancel:true});await restore(original);
   if(kind==="shared"){const point=await client({x:original.viewport.x+300*original.viewport.scale,y:original.viewport.y+200*original.viewport.scale});await page.mouse.move(point.x,point.y);await page.mouse.down({button:"right"});await page.mouse.move(point.x+20,point.y+10);await page.mouse.up({button:"right"});assert.equal(await page.evaluate(()=>modelEdits),0);await restore(original);await page.mouse.click(point.x,point.y);assert.equal(await page.evaluate(()=>modelEdits),1);await page.evaluate(()=>modelEdits=0);}
   assert.equal(await svg.evaluate(el=>{const e=new MouseEvent("contextmenu",{bubbles:true,cancelable:true,button:2});el.dispatchEvent(e);return e.defaultPrevented;}),true);
   assert.equal(await page.evaluate(()=>{const e=new MouseEvent("contextmenu",{bubbles:true,cancelable:true,button:2});document.body.dispatchEvent(e);return e.defaultPrevented;}),false);
   // Default navigation needs no toolbar mode: repeated left-drag zooms,
   // middle-drag does nothing, and Escape cancels an unfinished rectangle.
   const navRect=await svg.boundingBox(),start={x:navRect.x+navRect.width*.13,y:navRect.y+navRect.height*.12},end={x:navRect.x+navRect.width*.53,y:navRect.y+navRect.height*.42};
   for(let repeat=0;repeat<2;repeat++){const prior=await capture();await page.mouse.move(start.x,start.y);await page.mouse.down();assert.equal(await svg.evaluate(e=>getComputedStyle(e).cursor),'crosshair');await page.mouse.move(end.x,end.y,{steps:3});assert.equal(await svg.locator('.svgv-window-rectangle').count(),1);await page.mouse.up();const after=await capture();near(after.viewport.scale/prior.viewport.scale,2.5);assert.deepEqual(after.transform,prior.transform);assert.deepEqual(after.pin,prior.pin);}
   await restore(original);await page.mouse.move(start.x,start.y);await page.mouse.down({button:'middle'});await page.mouse.move(end.x,end.y,{steps:3});await page.mouse.up({button:'middle'});assert.deepEqual(await capture(),original);
   await page.mouse.move(start.x,start.y);await page.mouse.down();await page.mouse.move(end.x,end.y);await svg.press('Escape');await page.mouse.up();assert.deepEqual(await capture(),original);assert.equal(await svg.locator('.svgv-window-rectangle').count(),0);
   const measure=page.locator(kind==="fallback"?'#planform-view-dialog [data-svgv="measure"]':'[data-svgv="measure"]');await measure.selectOption("distance");await pan({ctrl:true});assert.equal(await measure.inputValue(),"distance");await restore(original);
   await windowButton.click();assert.equal(await windowButton.getAttribute("aria-pressed"),"true");await pan({ctrl:true});await pan({cancel:true});assert.equal(await windowButton.getAttribute("aria-pressed"),"true");await svg.press("Escape");assert.equal(await windowButton.getAttribute("aria-pressed"),"false");await restore(original);
   await windowButton.click();await measure.selectOption("distance");assert.equal(await windowButton.getAttribute("aria-pressed"),"false");await windowButton.click();assert.equal(await measure.inputValue(),"navigate");
   const r=await svg.boundingBox(),a={x:r.x+r.width*.2,y:r.y+r.height*.15},b={x:r.x+r.width*.6,y:r.y+r.height*.45};
   const selectedDrawingCenter=await svg.evaluate((el,{a,b,state})=>{const p=el.createSVGPoint();p.x=(a.x+b.x)/2;p.y=(a.y+b.y)/2;const q=p.matrixTransform(el.getScreenCTM().inverse());return{x:(q.x-state.viewport.x)/state.viewport.scale,y:(q.y-state.viewport.y)/state.viewport.scale};},{a,b,state:original});
   await page.mouse.move(a.x,a.y);await page.mouse.down();await page.mouse.move(b.x,b.y,{steps:3});
   const selectionBounds=await literalRectangle();near(selectionBounds.x,a.x);near(selectionBounds.y,a.y);near(selectionBounds.width,b.x-a.x);near(selectionBounds.height,b.y-a.y);
   const exported=await svg.evaluate(el=>WingSVGViewport.serializeSVG(el));assert(!exported.includes('class="svgv-window-rectangle"'));
   await page.screenshot({path:path.join(out,kind+"-window-selection.png")});await page.mouse.up();
   const zoomed=await capture();near(zoomed.viewport.scale/original.viewport.scale,2.5);assert.deepEqual(zoomed.transform,original.transform);assert.deepEqual(zoomed.pin,original.pin);assert.equal(await windowButton.getAttribute("aria-pressed"),"false");
   const centered=await svg.evaluate((el,p)=>{const m=el.querySelector(".svgv-scene,.dpv-scene").getScreenCTM();return{x:m.a*p.x+m.c*p.y+m.e,y:m.b*p.x+m.d*p.y+m.f};},selectedDrawingCenter);near(centered.x,r.x+r.width/2);near(centered.y,r.y+r.height/2);assert.equal(await page.evaluate(()=>modelEdits),0);
   await restore(original);await windowButton.click();await page.mouse.move(b.x,b.y);await page.mouse.down();await page.mouse.move(a.x,a.y,{steps:3});await page.mouse.up();assert.deepEqual(await capture(),zoomed);
   await restore(original);await windowButton.click();await page.mouse.move(a.x,a.y);await page.mouse.down();await page.mouse.move(b.x,b.y);await svg.press("Escape");await page.mouse.up();assert.deepEqual(await capture(),original);assert.equal(await svg.locator(".svgv-window-rectangle").count(),0);
   await windowButton.click();await page.mouse.move(a.x,a.y);await page.mouse.down();await page.mouse.move(a.x+2,a.y+2);await page.mouse.up();assert.deepEqual(await capture(),original);assert.equal(await windowButton.getAttribute("aria-pressed"),"true");await windowButton.click();
   await windowButton.click();await page.mouse.move(a.x,a.y);await page.mouse.down();await page.mouse.move(b.x,b.y);await svg.dispatchEvent("pointercancel",{pointerId:1});await page.mouse.up();assert.deepEqual(await capture(),original);assert.equal(await windowButton.getAttribute("aria-pressed"),"false");
   // The live outline must remain under both pointer corners, not expand to
   // the canvas aspect ratio. Exercise letterboxing, resized and maximized
   // canvases, all drag directions, and an already zoomed / pinned image.
   for(const layout of [{name:"narrow",width:1050,height:1250,sw:700,sh:650},{name:"wide",width:1700,height:1050,sw:1300,sh:450},{name:"maximized",width:1850,height:1450,sw:1650,sh:850}]){
    await page.setViewportSize({width:layout.width,height:layout.height});
    if(kind==="shared")await page.evaluate(layout=>{document.getElementById("shared").style.width=(layout.sw+20)+"px";testSvg.style.width=layout.sw+"px";testSvg.style.height=layout.sh+"px";},layout);
    await restore(original);await windowButton.scrollIntoViewIfNeeded();
    for(const [sx,sy,ex,ey]of [[.2,.2,.68,.48],[.68,.48,.2,.2],[.2,.48,.68,.2],[.68,.2,.2,.48]]){
     await restore(original);if(await windowButton.getAttribute("aria-pressed")!=="true")await windowButton.click();
     const bounds=await svg.boundingBox(),from={x:bounds.x+bounds.width*sx,y:bounds.y+bounds.height*sy},to={x:bounds.x+bounds.width*ex,y:bounds.y+bounds.height*ey};
     await page.mouse.move(from.x,from.y);await page.mouse.down();await page.mouse.move(to.x,to.y,{steps:4});
     const rect=await literalRectangle();near(rect.x,Math.min(from.x,to.x));near(rect.y,Math.min(from.y,to.y));near(rect.width,Math.abs(to.x-from.x));near(rect.height,Math.abs(to.y-from.y));
     if(sx===.2&&sy===.2&&layout.name==="maximized")await page.screenshot({path:path.join(out,kind+"-literal-corners-maximized.png")});
     await page.mouse.up();const after=await capture();near(after.viewport.scale/original.viewport.scale,Math.min(1/Math.abs(ex-sx),1/Math.abs(ey-sy)));assert.deepEqual(after.transform,original.transform);assert.deepEqual(after.pin,original.pin);
    }
    // Horizontal and vertical drags are not windows, and must not throw or
    // create a click on underlying geometry after a long drag.
    for(const delta of [{x:120,y:0},{x:0,y:100},{x:120,y:2}]){
     await restore(original);if(await windowButton.getAttribute("aria-pressed")!=="true")await windowButton.click();const bounds=await svg.boundingBox(),from={x:bounds.x+bounds.width*.35,y:bounds.y+bounds.height*.35};
     await page.mouse.move(from.x,from.y);await page.mouse.down();await page.mouse.move(from.x+delta.x,from.y+delta.y);await page.mouse.up();assert.deepEqual(await capture(),original);assert.equal(await svg.locator(".svgv-window-rectangle").count(),0);
    }
    await svg.press("Escape");
   }
   // Use the release event position even if no pointermove was dispatched
   // at the final location (for example, when the browser coalesces events).
   await restore(original);await windowButton.click();const releaseBounds=await svg.boundingBox(),releaseStart={x:releaseBounds.x+releaseBounds.width*.2,y:releaseBounds.y+releaseBounds.height*.2},releaseEnd={x:releaseBounds.x+releaseBounds.width*.7,y:releaseBounds.y+releaseBounds.height*.5};
   await page.mouse.move(releaseStart.x,releaseStart.y);await page.mouse.down();await page.mouse.move(releaseStart.x+40,releaseStart.y+30);await svg.dispatchEvent("pointerup",{pointerId:1,button:0,clientX:releaseEnd.x,clientY:releaseEnd.y});await page.mouse.up();near((await capture()).viewport.scale/original.viewport.scale,2);await restore(original);
   await windowButton.click();const pin=page.locator(kind==="fallback"?'#planform-view-dialog [data-svgv-pin="pick"]':'[data-svgv-pin="pick"]');await pin.click();assert.equal(await windowButton.getAttribute("aria-pressed"),"false");await pan({ctrl:true});await pan({cancel:true});assert.equal(await pin.getAttribute("aria-pressed"),"true");await svg.press("Escape");
   assert.equal(await page.evaluate(()=>JSON.stringify(parameters)),JSON.stringify(base));checks.push({kind,double_click_fit:true,right_pan:true,ctrl_right_image_pan:true,default_left_window:true,middle_drag_inert:true,right_pan_over_handles:kind==="shared"?"pass":"not_applicable_read_only",right_pan_while_measuring_and_picking:true,right_pan_escape:true,canvas_context_menu_only:true,literal_corner_window:true,window_centers_selection:true,pinned_registration_unchanged:true,reversed_drag:true,four_drag_quadrants:true,resized_and_maximized:true,release_coordinate_used:true,degenerate_drag_noop:true,tiny_box_noop:true,cancel_escape_toggle_pointer:true,no_model_edits:true});await page.close();
  }
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,"receipt.json"),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
