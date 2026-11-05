'use strict';
// node test/loft_plots_browser_test.cjs <evidence-dir> <playwright-module>
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
fs.mkdirSync(out,{recursive:true});
const fixture=`<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="loft.css"><style>body{background:#142331;color:#dceaf5;font:14px system-ui;margin:20px}#loft{max-width:720px}input{max-width:120px}.row{display:flex;justify-content:space-between;margin:5px 0}[hidden]{display:none!important}</style><div id="context" hidden></div><section id="loft"><h2>Loft</h2></section><script src="airfoils.js"></script><script src="numeric_inputs.js"></script><script src="loft_plots.js"></script><script src="loft.js"></script>`;
const server=http.createServer((req,res)=>{const name=req.url.split('?')[0].slice(1);if(!name){res.setHeader('Content-Type','text/html');return res.end(fixture);}if(!/^[\w.]+$/.test(name)||!fs.existsSync(path.join(web,name))){res.statusCode=404;return res.end();}res.setHeader('Content-Type',name.endsWith('.css')?'text/css':'application/javascript');res.end(fs.readFileSync(path.join(web,name)));});
const checks=[];
(async()=>{
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch({channel:'chrome',headless:true}),page=await browser.newPage({viewport:{width:1000,height:1100}}),errors=[];
 page.on('pageerror',error=>errors.push(error.message));
 try{
  await page.goto('http://127.0.0.1:'+server.address().port);
  await page.evaluate(()=>{
   window.edits=[];window.previews=[];window.locked=false;document.addEventListener("pointerdown",event=>window.lastPointerId=event.pointerId,true);WingNumericInputs.install(document);
   const host=document.getElementById('loft'),context=document.getElementById('context');
   const field=(key,value,choices,parent=host)=>{const row=document.createElement('label');row.id='row-'+key;row.className='row';row.append(document.createTextNode(key));const input=document.createElement(choices?'select':'input');input.id='p-'+key;if(choices)for(const choice of choices){const option=document.createElement('option');option.value=option.textContent=choice;input.append(option);}input.value=value;row.append(input);parent.append(row);};
   for(const kind of ['thickness','twist','vertical_shift']){field('loft.'+kind+'_stations','[]');field('loft.'+kind+'_interpolation','linear',['linear','cosine']);}
   field('planform.twist_tip','10');field('planform.twist_axis_xc','.25');
   for(const station of ['root','tip']){field('airfoil.'+station+'_source','naca',null,context);field('airfoil.'+station,station==='root'?'2412':'0018',null,context);field('airfoil.'+station+'_profile','',null,context);}
   field('airfoil.n_points','21',null,context);field('airfoil.closed_trailing_edge','',null,context);document.getElementById('p-airfoil.closed_trailing_edge').type='checkbox';document.getElementById('p-airfoil.closed_trailing_edge').checked=false;
   field('airfoil.stations','[]',null,context);field('airfoil.interpolation','linear',null,context);
   window.editor=WingLoft.install(host,{onEdit:key=>edits.push(key),onPreview:key=>previews.push(key),isLocked:()=>locked});
   document.addEventListener('input',e=>{if(e.target.id?.startsWith('p-planform.'))editor.refresh();});
  });
  assert.equal(await page.locator('.loft-distribution-plot').count(),3);
  assert.equal(await page.locator('[data-loft-plot="thickness"] [data-loft-curve]').count(),1);
  assert.equal(await page.locator('[data-loft-handle]').count(),0);
  const inherited=await page.evaluate(()=>{const f=WingLoftPlots.inheritedThickness(document,WingAirfoils);return[f(0),f(.5),f(1)];});
  assert(inherited[0]>.119&&inherited[0]<.122);assert(inherited[2]>.179&&inherited[2]<.182);assert(inherited[1]>inherited[0]&&inherited[1]<inherited[2]);
  checks.push('All three inherited distributions draw; airfoil thickness uses actual surface tables');
  await page.locator('[data-loft-add="thickness"]').click();
  const thickness=page.locator('[data-loft-kind="thickness"]'),rows=thickness.locator('.loft-station-row');
  const seeded=await page.evaluate(()=>JSON.parse(document.getElementById('p-loft.thickness_stations').value));assert(Math.abs(seeded[0].tc-inherited[0])<.00005,JSON.stringify({seeded,inherited}));assert(Math.abs(seeded[1].tc-inherited[2])<.00005,JSON.stringify({seeded,inherited}));
  checks.push('Adding initial thickness stations honors the current coarse airfoil sampling and open trailing edge instead of changing the inherited section');
  await rows.last().locator('input').last().fill('.24');
  const curve=()=>thickness.locator('[data-loft-curve]').getAttribute('d');
  const linear=await curve();await page.locator('[id="p-loft.thickness_interpolation"]').selectOption('cosine');const cosine=await curve();assert.notEqual(linear,cosine);
  assert.equal(await thickness.locator('[data-loft-handle]').count(),2);
  checks.push('Changing interpolation redraws the curve through the scheduled control points');
  const point=thickness.locator('[data-loft-handle="1"]');await point.scrollIntoViewIfNeeded();const box=await point.boundingBox(),before=Number(await rows.last().locator('input').last().inputValue()),editCount=await page.evaluate(()=>edits.length);
  await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.mouse.move(box.x+box.width/2,box.y+box.height/2+25,{steps:5});
  assert.equal(await page.evaluate(()=>edits.length),editCount,'Dragging must not launch repeated model generations');assert(await page.evaluate(()=>previews.length)>0,'Dragging publishes live geometry drafts independently of FEM generation');
  assert.equal(await page.evaluate(()=>editor.isInteracting()),true);
  assert(Number(await rows.last().locator('input').last().inputValue())<before);await page.mouse.up();
  assert.equal(await page.evaluate(()=>edits.length),editCount+1);assert.equal(await rows.last().locator('input').first().inputValue(),'1');
  assert.equal(await page.evaluate(()=>editor.isInteracting()),false);
  const saved=await page.evaluate(()=>JSON.parse(document.getElementById('p-loft.thickness_stations').value));assert(saved[1].tc<before&&saved[1].tc>0);assert.equal(saved[1].eta,1);
  checks.push('Mouse dragging updates the saved schedule and numeric input; eta is fixed and one edit commits on release');
  const start=await rows.last().locator('input').last().inputValue(),pbox=await point.boundingBox(),count=await page.evaluate(()=>edits.length);
  await page.mouse.move(pbox.x+pbox.width/2,pbox.y+pbox.height/2);await page.mouse.down();await page.mouse.move(pbox.x+pbox.width/2,pbox.y+pbox.height/2+15,{steps:3});await page.keyboard.press('Escape');await page.mouse.up();
  assert.equal(await rows.last().locator('input').last().inputValue(),start);assert.equal(await page.evaluate(()=>edits.length),count);
  checks.push('Escape rolls back an in-progress graphical edit without marking the model changed');
  await point.focus();await page.keyboard.press('ArrowUp');assert(Number(await rows.last().locator('input').last().inputValue())>Number(start),JSON.stringify({start,diagnostic:await page.evaluate(()=>({active:document.activeElement?.tagName,edits,stored:document.getElementById('p-loft.thickness_stations').value})),errors}));
  await page.evaluate(()=>{locked=true;document.getElementById('loft').dispatchEvent(new Event('parameterlockchange'));});
  assert.equal(await point.getAttribute('aria-disabled'),'true');assert.equal(await point.getAttribute('tabindex'),'-1');
  await page.evaluate(()=>{locked=false;document.getElementById('loft').dispatchEvent(new Event('parameterlockchange'));});
  checks.push('Keyboard adjustment and parameter locks apply to graphical control points');
  await page.locator('[data-loft-add="thickness"]').click();
  const mid=thickness.locator('[data-loft-handle="1"]'),middle=rows.nth(1);await mid.scrollIntoViewIfNeeded();
  const xyBefore=await page.evaluate(()=>JSON.parse(document.getElementById('p-loft.thickness_stations').value)),xyBox=await mid.boundingBox(),xyEdits=await page.evaluate(()=>edits.length);
  await page.mouse.move(xyBox.x+xyBox.width/2,xyBox.y+xyBox.height/2);await page.mouse.down();await page.mouse.move(xyBox.x+xyBox.width/2+50,xyBox.y+xyBox.height/2-12,{steps:7});
  const xyLive=await page.evaluate(()=>JSON.parse(document.getElementById('p-loft.thickness_stations').value));assert(xyLive[1].eta>xyBefore[1].eta&&xyLive[1].tc>xyBefore[1].tc);assert.equal(await page.evaluate(()=>edits.length),xyEdits);await page.mouse.up();
  assert.equal(await page.evaluate(()=>edits.length),xyEdits+1);assert.equal(xyLive[0].eta,0);assert.equal(xyLive[2].eta,1);assert.equal(Number(await middle.locator('input').first().inputValue()),xyLive[1].eta);
  checks.push('Interior handles move in both eta and value, update the live draft, retain root/tip anchors and commit exactly once');
  const closeBox=await mid.boundingBox();await page.mouse.move(closeBox.x+closeBox.width/2,closeBox.y+closeBox.height/2);await page.mouse.down();await page.mouse.move(closeBox.x+closeBox.width/2+1500,closeBox.y+closeBox.height/2,{steps:3});await page.mouse.up();
  const bounded=await page.evaluate(()=>JSON.parse(document.getElementById('p-loft.thickness_stations').value));assert(bounded[1].eta<bounded[2].eta&&bounded[1].eta>bounded[0].eta);assert(bounded[2].eta-bounded[1].eta>=1e-8);
  checks.push('Dragging beyond neighbouring anchors clamps to a distinct representable eta without crossing or collapsing interpolation intervals');
  await page.evaluate(()=>{const rows=document.querySelectorAll('[data-loft-kind=thickness] .loft-station-row');rows[1].querySelectorAll('input')[0].value='0.587654321012';rows[1].querySelectorAll('input')[1].value='0.173456789012';editor.refresh();});
  const raw=await middle.locator('input').evaluateAll(nodes=>nodes.map(node=>Number(node.value))),rawBox=await mid.boundingBox(),rawEdits=await page.evaluate(()=>edits.length);
  await page.mouse.move(rawBox.x+rawBox.width/2,rawBox.y+rawBox.height/2);await page.mouse.down();await page.mouse.move(rawBox.x+rawBox.width/2-35,rawBox.y+rawBox.height/2+9,{steps:4});await page.keyboard.press('Escape');await page.mouse.up();
  assert.deepEqual(await middle.locator('input').evaluateAll(nodes=>nodes.map(node=>Number(node.value))),raw);assert.equal(await page.evaluate(()=>edits.length),rawEdits);
  const cancelBox=await mid.boundingBox();await page.mouse.move(cancelBox.x+cancelBox.width/2,cancelBox.y+cancelBox.height/2);await page.mouse.down();await page.mouse.move(cancelBox.x+cancelBox.width/2+20,cancelBox.y+cancelBox.height/2-8,{steps:3});await page.evaluate(()=>document.querySelector('[data-loft-plot=thickness]').dispatchEvent(new PointerEvent('pointercancel',{pointerId:window.lastPointerId,bubbles:true})));await page.mouse.up();
  assert.deepEqual(await middle.locator('input').evaluateAll(nodes=>nodes.map(node=>Number(node.value))),raw);assert.equal(await page.evaluate(()=>edits.length),rawEdits);
  checks.push('Escape and pointer cancellation restore both coordinates with the original loaded precision and no model edit');
  const lockBox=await mid.boundingBox();await page.mouse.move(lockBox.x+lockBox.width/2,lockBox.y+lockBox.height/2);await page.mouse.down();await page.mouse.move(lockBox.x+lockBox.width/2+12,lockBox.y+lockBox.height/2+8,{steps:2});await page.evaluate(()=>{locked=true;document.getElementById('loft').dispatchEvent(new Event('parameterlockchange'));});await page.mouse.up();
  assert.deepEqual(await middle.locator('input').evaluateAll(nodes=>nodes.map(node=>Number(node.value))),raw);assert.equal(await page.evaluate(()=>edits.length),rawEdits);await page.evaluate(()=>{locked=false;document.getElementById('loft').dispatchEvent(new Event('parameterlockchange'));});
  checks.push('A lock activated during a drag rolls back its draft instead of committing a locked parameter');

  await mid.focus();await page.keyboard.press('ArrowLeft');const etaKeyboard=Number(await middle.locator('input').first().inputValue());assert(etaKeyboard<raw[0]);await page.keyboard.press('Alt+ArrowRight');assert(Math.abs(Number(await middle.locator('input').first().inputValue())-etaKeyboard-.01)<1e-4);
  checks.push('Left/right keyboard actions change eta and Alt provides a fine spanwise increment');
  const offsetBefore=Number(await middle.locator('input').first().inputValue()),offsetBox=await mid.boundingBox(),axisWidth=await thickness.locator('svg').evaluate(svg=>svg.getScreenCTM().a*(svg.viewBox.baseVal.width-86));
  await page.mouse.move(offsetBox.x+offsetBox.width/2+3,offsetBox.y+offsetBox.height/2+2);await page.mouse.down();await page.mouse.move(offsetBox.x+offsetBox.width/2+23,offsetBox.y+offsetBox.height/2+2,{steps:3});await page.mouse.up();
  assert(Math.abs(Number(await middle.locator('input').first().inputValue())-offsetBefore-20/axisWidth)<1e-4,JSON.stringify({offsetBefore,after:Number(await middle.locator('input').first().inputValue()),axisWidth,offsetBox}));
  checks.push('Dragging from the edge of a handle preserves its cursor offset instead of jumping the anchor to the initial mouse position');

  const thicknessBefore=await rows.last().locator('input').last().inputValue();await page.locator('[data-loft-add="twist"]').click();await page.locator('[data-loft-add="vertical_shift"]').click();
  assert.equal(await page.locator('[data-loft-plot="twist"] [data-loft-handle]').count(),2);assert.equal(await page.locator('[data-loft-plot="vertical_shift"] [data-loft-handle]').count(),2);
  await page.locator('[data-loft-kind="vertical_shift"] .loft-station-row').last().locator('input').last().fill('-3');
  assert.match(await page.locator('[data-loft-plot="vertical_shift"] [data-loft-handle="1"]').getAttribute('aria-valuetext'),/-3/);
  assert.equal(thicknessBefore,await rows.last().locator('input').last().inputValue());
  checks.push('Twist and shift schedules have independent, labeled editable control points');
  for(const kind of ['twist','vertical_shift']){
   await page.locator('[data-loft-add="'+kind+'"]').click();const group=page.locator('[data-loft-kind="'+kind+'"]'),handle=group.locator('[data-loft-handle="1"]');await handle.scrollIntoViewIfNeeded();
   const before=await group.locator('.loft-station-row').nth(1).locator('input').evaluateAll(nodes=>nodes.map(node=>Number(node.value))),box=await handle.boundingBox();
   await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.mouse.move(box.x+box.width/2-25,box.y+box.height/2+8,{steps:4});await page.mouse.up();
   const after=await group.locator('.loft-station-row').nth(1).locator('input').evaluateAll(nodes=>nodes.map(node=>Number(node.value)));assert(after[0]<before[0]&&after[1]<before[1],JSON.stringify({kind,before,after}));
  }
  checks.push('Twist and vertical-shift function viewers also support independent two-axis control-point editing');

  await page.locator('#loft').screenshot({path:path.join(out,'loft-distributions-wide.png')});
  await page.evaluate(()=>document.getElementById('loft').style.width='300px');await page.waitForTimeout(100);
  assert.equal(await thickness.evaluate(el=>el.scrollWidth<=el.clientWidth+1),true);
  const dimensions=await thickness.locator('svg').evaluate(svg=>({viewBox:svg.viewBox.baseVal.width,width:svg.clientWidth,height:svg.clientHeight}));assert(dimensions.viewBox<350&&dimensions.height>=180);
  await page.locator('#loft').screenshot({path:path.join(out,'loft-distributions-narrow.png')});
  checks.push('Plots keep readable dimensions in narrow forms and resize their viewBox');
  await rows.last().locator('input').first().fill('0');assert.equal(await thickness.locator('[data-loft-curve]').count(),0);assert.match(await thickness.locator('.loft-plot-note').textContent(),/Correct/);
  await rows.last().locator('input').first().fill('1');await page.locator('[data-loft-clear="thickness"]').click();assert.equal(await thickness.locator('[data-loft-handle]').count(),0);assert.equal(await thickness.locator('[data-loft-curve]').count(),1);
  checks.push('Invalid station tables show a useful message; clearing restores the inherited curve');
  assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(out,'loft_plots.json'),JSON.stringify({passed:true,checks,inherited,dimensions,errors},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(error){await page.screenshot({path:path.join(out,'loft-plots-failure.png'),fullPage:true});throw error;}
 finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
