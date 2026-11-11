'use strict';
// GRID/part picking component: exact native coordinates and asynchronous provider fixtures.
// node fe_edit_picking_browser_test.cjs OUTPUT PLAYWRIGHT [CHROME]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,modulePath,chromeArg]=process.argv.slice(2),out=path.resolve(outArg),web=path.resolve(__dirname,'../web'),{chromium}=require(path.resolve(modulePath));
(async()=>{
 fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(chromeArg?{executablePath:chromeArg}:{})}),page=await browser.newPage({viewport:{width:1420,height:1100}}),checks=[],errors=[];
 try{
  page.on('pageerror',error=>errors.push(error.message));await page.setContent('<html><body style="margin:0;background:#0d1622"><main style="display:grid;grid-template-columns:440px minmax(0,1fr)"><div id="tools" style="padding:14px;min-width:0"></div><div style="padding:30px;color:#b9d5ed">3D picking provider fixture · native model coordinates</div></main></body></html>');
  for(const file of ['style.css','fe_edit.css'])await page.addStyleTag({path:path.join(web,file)});await page.addStyleTag({content:'html,body{height:auto;overflow:auto}main{height:auto}'});
  for(const file of ['numeric_inputs.js','fe_edit.js'])await page.addScriptTag({path:path.join(web,file)});
  await page.evaluate(()=>{
   WingNumericInputs.install(document);window.calls=[];window.previews=[];window.picks=[];window.context={available:true,modelKey:'model-0',sourceName:'native_model.bdf',unitsLabel:'source model units'};let revision=0;
   window.editor=WingFEEdit.install(document.getElementById('tools'),{
    readContext:()=>context,
    request:async(action,payload)=>{calls.push({action,payload});const parts=[{id:'part-E10',label:'Forward part',element_ids:[10,11],element_count:2,side:'negative'},{id:'part-E20',label:'Aft part',element_ids:[20,21,22],element_count:3,side:'positive'}];if(action==='parts')return{ok:true,parts};revision++;return{ok:true,session_id:'working-model',revision,...(action==='cut'?{parts}:{}),source:{name:'native_model.bdf',text:'BEGIN BULK\nENDDATA\n'},summary:{nodes:10,elements:5,bounds:{min:[0,0,0],max:[10,2,2]}}};},
    onCommit:data=>{context.modelKey='model-'+data.revision;},onPreview:data=>previews.push(data),
    onPickNodes:options=>new Promise((resolve,reject)=>{const pick={options,resolve,reject,aborted:false};options.signal.addEventListener('abort',()=>pick.aborted=true);picks.push(pick);}),
    onPickPart:options=>new Promise((resolve,reject)=>{const pick={options,resolve,reject,aborted:false};options.signal.addEventListener('abort',()=>pick.aborted=true);picks.push(pick);})
   });
  });
  const button=name=>page.locator('[data-action="'+name+'"]'),input=name=>page.locator('[data-field="'+name+'"]');
  const idle=()=>page.waitForFunction(()=>!editor.busy&&!editor.picking);
  await button('initialize').click();await idle();const initial=await page.evaluate(()=>editor.snapshot().inputs);
  await button('pick-plane-point').click();assert.equal(await page.evaluate(()=>editor.busy),false);assert.equal(await page.evaluate(()=>editor.picking),true);assert(await button('cut').isDisabled());assert(await button('cancel-pick').isEnabled());
  await page.evaluate(()=>picks.at(-1).options.onProgress({nodes:[],message:'Click a GRID for the plane point.'}));assert.equal(await page.locator('[data-role=node-pick-text]').innerText(),'Click a GRID for the plane point.');
  const nativePoint={id:403,xyz:[1234.56789012345,-.000000123456789,9.87654321098765]};
  await page.evaluate(node=>picks.at(-1).options.onProgress({nodes:[node]}),nativePoint);assert.equal(await input('point_x').inputValue(),initial.point_x);
  await page.evaluate(node=>picks.at(-1).resolve({nodes:[node]}),nativePoint);await idle();
  assert.deepEqual(await page.evaluate(()=>['x','y','z'].map(axis=>Number(document.querySelector('[data-field=point_'+axis+']').value))),nativePoint.xyz);
  assert.equal(await input('normal_x').inputValue(),'1');assert((await page.locator('[data-role=plane-picked]').innerText()).includes('GRID 403'));
  await page.evaluate(()=>WingNumericInputs.commitAll(document));assert.equal(await input('point_x').inputValue(),String(nativePoint.xyz[0]));assert.deepEqual(await page.evaluate(()=>previews.at(-1).plane.point),nativePoint.xyz);
  checks.push('Plane point uses exact stored native XYZ, preserves the normal, activates its preview and survives normal numeric commit without quantizing computed values');
  await input('movement_mode').selectOption('direction');await input('move_x').fill('7');await input('move_y').fill('8');await input('move_z').fill('9');
  const start={id:5001,xyz:[.123456789012345,12.3456789012345,-4.56789012345678]},end={id:5002,xyz:[2.34567890123456,23.4567890123456,6.7890123456789]},delta=end.xyz.map((value,i)=>value-start.xyz[i]);
  await button('pick-translation-vector').click();assert.equal(await page.evaluate(()=>picks.at(-1).options.count),2);await page.evaluate(node=>picks.at(-1).options.onProgress({nodes:[node]}),start);
  assert.equal(await input('move_x').inputValue(),'7');assert((await page.locator('[data-role=node-pick-text]').innerText()).includes('GRID 5001'));
  await page.evaluate(nodes=>picks.at(-1).resolve({nodes}),[start,end]);await idle();assert.equal(await input('movement_mode').inputValue(),'vector');
  assert.deepEqual(await page.evaluate(()=>['x','y','z'].map(axis=>Number(document.querySelector('[data-field=move_'+axis+']').value))),delta);await page.evaluate(()=>WingNumericInputs.commitAll(document));assert.equal(await input('move_x').inputValue(),String(delta[0]));
  const report=await page.locator('[data-role=vector-picked]').innerText();assert(report.includes('GRID 5001')&&report.includes('GRID 5002')&&report.includes('B − A'));
  await input('move_z').fill('0');await button('clear-part').click();await button('translate').click();await idle();assert.deepEqual(await page.evaluate(()=>calls.at(-1).payload.vector),[delta[0],delta[1],0]);assert((await page.locator('[data-role=vector-picked]').innerText()).includes('edited after picking'));
  checks.push('Two GRID picks compute end minus start only when complete, preserve double precision and switch to editable XYZ; setting only Z to zero reaches translation with X and Y unchanged');
  const previous=await page.evaluate(()=>editor.snapshot().inputs);await button('pick-translation-vector').click();await page.evaluate(node=>picks.at(-1).options.onProgress({nodes:[node]}),start);await button('cancel-pick').click();assert.equal(await page.evaluate(()=>picks.at(-1).aborted),true);await page.evaluate(nodes=>picks.at(-1).resolve({nodes}),[{id:1,xyz:[0,0,0]},{id:2,xyz:[1,1,1]}]);await page.waitForTimeout(25);assert.deepEqual(await page.evaluate(()=>editor.snapshot().inputs),previous);
  await button('pick-plane-point').click();await page.keyboard.press('Escape');assert.equal(await page.evaluate(()=>picks.at(-1).aborted),true);assert.equal(await page.evaluate(()=>editor.picking),false);assert.deepEqual(await page.evaluate(()=>editor.snapshot().inputs),previous);
  await button('pick-translation-vector').click();await page.evaluate(()=>picks.at(-1).reject(Error('GRID coordinate service is unavailable.')));await idle();assert((await page.locator('[data-role=message-text]').innerText()).includes('coordinate service'));assert.deepEqual(await page.evaluate(()=>editor.snapshot().inputs),previous);
  checks.push('Cancel, Escape, late provider completion and provider failures retain previous point/vector inputs and restore the editing controls without blocking the workspace');
  await button('parts').click();await idle();assert.equal(await page.evaluate(()=>calls.at(-1).action),'parts');assert.deepEqual(await page.evaluate(()=>calls.at(-1).payload.plane.point),nativePoint.xyz);assert.equal(await page.locator('[data-role=parts-summary] li').count(),2);assert.equal(await page.evaluate(()=>previews.at(-1).show_parts),true);
  await button('pick-part').click();assert.deepEqual(await page.evaluate(()=>picks.at(-1).options.plane.point),nativePoint.xyz);await page.evaluate(()=>picks.at(-1).resolve({part:{id:'part-E20',label:'Aft part'},element_ids:[20,21,22]}));await idle();assert((await page.locator('[data-role=part-selection-text]').innerText()).includes('Aft part'));assert.deepEqual(await page.evaluate(()=>previews.at(-1).selected_element_ids),[20,21,22]);
  await button('translate').click();await idle();assert.deepEqual(await page.evaluate(()=>calls.at(-1).payload.element_ids),[20,21,22]);assert(await page.locator('[data-role=part-selection]').isVisible());await page.locator('[data-role=repeat-tools]').evaluate(el=>el.open=true);await button('copy').click();await idle();assert.deepEqual(await page.evaluate(()=>calls.at(-1).payload.element_ids),[20,21,22]);
  await page.screenshot({path:path.join(out,'fe-edit-picked-points-and-part.png'),fullPage:true});
  await input('selection').selectOption('negative');assert(await page.locator('[data-role=part-selection]').isHidden());await button('translate').click();await idle();assert.equal(await page.evaluate(()=>Object.hasOwn(calls.at(-1).payload,'element_ids')),false);
  await button('pick-part').click();await page.evaluate(()=>picks.at(-1).resolve({part:{id:'part-E20',label:'Aft part'},element_ids:[20,21,22]}));await idle();await button('cut').click();await idle();assert(await page.locator('[data-role=part-selection]').isHidden());
  await button('pick-part').click();await page.evaluate(()=>picks.at(-1).resolve({part:{id:'part-E20',label:'Aft part'},element_ids:[20,21,22]}));await idle();await button('undo').click();await idle();assert(await page.locator('[data-role=part-selection]').isHidden());
  checks.push('Connected-part identification includes the current plane; a 3D-picked part overrides half-space selection for move/copy, while selector changes, new cuts and undo clear stale part membership');
  await button('pick-part').click();await page.keyboard.press('Escape');assert.equal(await page.evaluate(()=>picks.at(-1).aborted),true);
  await button('pick-plane-point').click();await page.evaluate(()=>{context.modelKey='new-study';editor.refresh();});assert.equal(await page.evaluate(()=>picks.at(-1).aborted),true);await page.evaluate(node=>picks.at(-1).resolve({nodes:[node]}),{id:999,xyz:[9,9,9]});await page.waitForTimeout(25);assert.equal(await page.evaluate(()=>editor.session),null);assert.notEqual(await input('point_x').inputValue(),'9');
  await button('initialize').click();await idle();await button('pick-translation-vector').click();await page.setViewportSize({width:390,height:900});await page.evaluate(()=>{document.querySelector('main').style.gridTemplateColumns='minmax(0,1fr)';document.querySelector('main>div:nth-child(2)').style.display='none';});await page.screenshot({path:path.join(out,'fe-edit-picking-narrow.png'),fullPage:true});
  const overflow=await page.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth);assert(overflow<=1);await page.evaluate(()=>editor.destroy());assert.equal(await page.evaluate(()=>picks.at(-1).aborted),true);assert.deepEqual(errors,[]);
  checks.push('Changing Study and destroying the tool abort active picks; stale completions cannot write into another model, and the narrow layout keeps Cancel outside disabled controls');
  fs.writeFileSync(path.join(out,'fe-edit-picking-summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log('FE picking: '+checks.length+' groups passed.');
 }catch(error){fs.writeFileSync(path.join(out,'fe-edit-picking-failure.json'),JSON.stringify({error:error.stack,checks,errors},null,2));await page.screenshot({path:path.join(out,'fe-edit-picking-failure.png'),fullPage:true}).catch(()=>{});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
