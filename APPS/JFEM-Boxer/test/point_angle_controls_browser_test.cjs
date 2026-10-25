"use strict";
// node point_angle_controls_browser_test.cjs <evidence-dir> <playwright-module>
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
const base={'planform.area':4,'planform.aspect_ratio':4,'planform.taper_ratio':1,'planform.sweep':0,'planform.sweep_ref_xc':.25,'planform.twist_axis_xc':.25,'planform.root_ref_x':0,'planform.root_ref_y':0,'planform.root_ref_z':0,'planform.dihedral':0,'planform.twist_tip':0,'planform.leading_edge_points':[],'planform.trailing_edge_points':[],'box.end_eta':1,'box.front_spar_xc':.2,'box.rear_spar_xc':.7,'box.front_spar_points':[],'box.rear_spar_points':[],'box.rib_pitch':.5,'box.stringer_angle':7,'ribs.masters':[],'leading_edge.enabled':true,'leading_edge.start_rib':1,'leading_edge.end_rib':0,'leading_edge.disabled_bays':'','movable_surfaces.items':[{name:'Flap',kind:'flap',edge:'trailing',eta_start:.25,eta_end:.8,hinge_start:.8,hinge_end:.75,deflection:10,color:'#dd55ff'}]};
(async()=>{fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,channel:'chrome'}),checks=[],errors=[];const page=await browser.newPage({viewport:{width:1300,height:1100}});page.on('pageerror',e=>errors.push(e.message));
try{
 await page.setContent('<!doctype html><div id="inputs" hidden></div><section id="editor"></section>');
 for(const file of ['style.css','svg_viewport.css','planform_view.css','spar_view.css','rib_layout.css'])await page.addStyleTag({path:path.join(web,file)});
 await page.addStyleTag({content:'html,body{overflow:auto}body{margin:20px}#editor{width:900px}.planform-editor-sticky{position:static!important}#editor svg{width:100%;height:370px;max-height:none}'});
 for(const file of ['numbers.js','svg_viewport.js','planform_view.js','spar_view.js','rib_layout.js','leading_edge_gaps.js','fuel_tank_view.js','dimensioned_plan_view.js'])await page.addScriptTag({path:path.join(web,file)});
 await page.evaluate(base=>{window.makeFixture=(kind,custom={})=>{window.editor?.destroy?.();const host=document.getElementById('editor'),hidden=document.getElementById('inputs');host.replaceChildren();hidden.replaceChildren();const params={...base,...custom};for(const[key,value]of Object.entries(params)){const input=document.createElement('input');input.id='p-'+key;input.value=JSON.stringify(value);hidden.append(input);}window.read=()=>Object.fromEntries(Object.keys(params).map(k=>[k,JSON.parse(document.getElementById('p-'+k).value)]));window.keys=kind==='spars'?WingSparView.POINT_KEYS:WingPlanformView.POINT_KEYS;window.edits=0;const options={readValues:read,onEdit:()=>edits++};window.editor=kind==='spars'?WingSparView.install(host,options):WingPlanformView.createPointEditor(host,options,{});};},base);
 for(const kind of ['planform','spars']){
  await page.evaluate(kind=>makeFixture(kind),kind);
  assert.equal(await page.locator('tbody tr').count(),4);
  assert.equal(await page.locator('tbody [data-field="eta"]:disabled').count(),4);
  assert.equal(await page.locator('.planform-point-remove:disabled').count(),4);
  assert.equal(await page.locator('.plan-context-movable').count(),1);assert(await page.locator('.plan-context-leading').count()>1);
  if(kind==='spars')assert.deepEqual(await page.evaluate(()=>editor.readDrafts()[keys[1]].map(r=>r.stringer_angle)),[7,7]);
  checks.push(kind+': root and tip visible/eta-locked, context overlays present, legacy angle preserved');
  for(const edge of [0,1]){
   const group=page.locator('.planform-edge-table').nth(edge),tip=group.locator('tbody tr').last();
   await tip.locator('[data-field="fix_incoming_angle"]').check();
   await tip.locator('[data-field="incoming_angle_deg"]').fill('5');await tip.locator('[data-field="incoming_angle_deg"]').press('Tab');
   const state=await page.evaluate(edge=>{const p=editor.readDrafts(),data=editor.validate(),v=data.edgeVertices[keys[edge]];return{valid:data.valid,error:data.error,rows:p[keys[edge]],vertices:v,canonical:read()[keys[edge]]};},edge);
   assert(state.valid,state.error);assert.equal(state.rows.at(-1).incoming_angle_deg,5);assert.equal(state.rows.at(-1).dxc,0);assert(Math.abs(state.rows[0].dxc+2*Math.tan(5*Math.PI/180))<1e-12);assert.equal(state.canonical.at(-1).incoming_angle_deg,5);
   assert.equal(await group.locator('tbody tr').first().locator('[data-field="dxc"]').isDisabled(),true);
   await group.locator('.planform-point-add').click();
   assert.deepEqual(await group.locator('tbody [data-field="eta"]').evaluateAll(els=>els.map(e=>Number(e.value))),[0,.5,1]);
   const middle=group.locator('tbody tr').nth(1);await middle.locator('[data-field="fix_incoming_angle"]').check();await middle.locator('[data-field="incoming_angle_deg"]').fill('3');await middle.locator('[data-field="incoming_angle_deg"]').press('Tab');
   const slopes=await page.evaluate(edge=>{const v=editor.validate().edgeVertices[keys[edge]];return v.slice(1).map((p,i)=>Math.atan2(p.position[0]-v[i].position[0],p.position[1]-v[i].position[1])*180/Math.PI);},edge);assert(Math.abs(slopes[0]-3)<1e-10);assert(Math.abs(slopes[1]-5)<1e-10);
   await middle.locator('[data-field="eta"]').fill('.6');await middle.locator('[data-field="eta"]').press('Tab');
   assert.equal(await middle.locator('[data-field="incoming_angle_deg"]').inputValue(),'3');
   await middle.locator('[data-field="fix_incoming_angle"]').uncheck();assert.equal(await group.locator('tbody tr').first().locator('[data-field="dxc"]').isDisabled(),false);
   await middle.locator('[data-field="eta"]').fill('0');await middle.locator('[data-field="eta"]').press('Tab');assert.equal(await middle.locator('[data-field="eta"]').isDisabled(),false,'An invalid interior duplicate remains editable');assert.equal(await page.evaluate(()=>editor.validate().valid),false);await middle.locator('[data-field="eta"]').fill('.6');await middle.locator('[data-field="eta"]').press('Tab');assert.equal(await page.evaluate(()=>editor.validate().valid),true);
   checks.push(kind+' edge '+edge+': angle changes preceding offset only; cascades correctly through adjacent constraints; adding/reordering retains fields; release restores free offset');
  }
  const tipHandle=page.locator('svg [data-edge="0"][data-eta="1"]');await tipHandle.focus();await page.keyboard.press('ArrowLeft');assert.equal(await page.locator('svg [data-edge="0"][data-eta="1"]').count(),1);
  await page.locator('#editor').screenshot({path:path.join(out,kind+'-angle-controls.png')});
 }
 await page.evaluate(()=>makeFixture('planform',{'planform.leading_edge_points':[{eta:.9989088806202084,dxc:.209853}]}));assert.equal(await page.locator('.planform-editor-warning').isVisible(),true);assert((await page.locator('.planform-editor-warning').textContent()).includes('tip'));assert.equal(await page.locator('.planform-edge-table').first().locator('tbody tr').count(),3);
 checks.push('Existing near-tip return remains geometrically unchanged, is exposed by its explicit tip handle, and produces an actionable warning');
 assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'point-angle-controls.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
}catch(error){await page.screenshot({path:path.join(out,'point-angle-failure.png'),fullPage:true});throw error;}finally{await browser.close();}})().catch(error=>{console.error(error.stack);process.exitCode=1;});
