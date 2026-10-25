'use strict';
// node point_add_precision_browser_test.cjs <evidence-dir> <playwright-module>
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
const base={'planform.area':4,'planform.aspect_ratio':4,'planform.taper_ratio':.4,'planform.sweep':10,'planform.sweep_ref_xc':.25,'planform.twist_axis_xc':.25,'planform.root_ref_x':0,'planform.root_ref_y':0,'planform.root_ref_z':0,'planform.dihedral':0,'planform.twist_tip':0,'box.end_eta':1,'box.front_spar_xc':.2,'box.rear_spar_xc':.55,'box.rib_pitch':.5,'box.stringer_angle':0,'ribs.masters':[]};
const original=[{eta:.123456789,dxc:.0123456789},{eta:.765432198,dxc:-.0234567891}];
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],browser=await chromium.launch({headless:true,channel:'chrome'}),page=await browser.newPage({viewport:{width:1200,height:1100}});page.on('pageerror',error=>errors.push(error.message));
 try{
  await page.setContent('<style>body{font:14px system-ui}#editor{width:850px}svg{width:800px;height:340px}input{width:180px}[hidden]{display:none!important}.pf-point-hit{fill:transparent}.pf-point-dot{fill:blue}.pf-wing{fill:#def}.planform-editor-sticky{position:static!important}</style><div id="inputs" hidden></div><section id="editor"></section>');
  for(const file of ['planform_view.js','spar_view.js','rib_layout.js'])await page.addScriptTag({path:path.join(web,file)});
  await page.evaluate(({base,original})=>{
   window.makeFixture=(kind,custom)=>{
    window.editor?.destroy?.();const host=document.getElementById('editor'),hidden=document.getElementById('inputs');host.replaceChildren();hidden.replaceChildren();
    const params={...base,'planform.leading_edge_points':[],'planform.trailing_edge_points':[],'box.front_spar_points':[],'box.rear_spar_points':[]},keys=kind==='spars'?WingSparView.POINT_KEYS:WingPlanformView.POINT_KEYS;
    for(let edge=0;edge<2;edge++)params[keys[edge]]=(custom||original).map(p=>({...p,...(kind==='spars'&&edge===1?{stringer_angle:1.23456789}:{})}));
    for(const [key,value]of Object.entries(params)){const input=document.createElement('input');input.id='p-'+key;input.value=JSON.stringify(value);hidden.append(input);}
    const options={readValues:()=>Object.fromEntries(Object.keys(params).map(key=>[key,JSON.parse(document.getElementById('p-'+key).value)])),onEdit:()=>{}};
    window.editor=kind==='spars'?WingSparView.install(host,options):WingPlanformView.createPointEditor(host,options,{});window.keys=keys;
    window.tableState=edge=>{const table=host.querySelector('[data-key="'+keys[edge]+'"]');return{rows:[...table.querySelectorAll('tbody tr')].map(row=>Object.fromEntries([...row.querySelectorAll('input')].map(input=>[input.dataset.field,Number(input.value)]))).filter(row=>row.eta>0&&row.eta<1),canonical:JSON.parse(document.getElementById('p-'+keys[edge]).value),active:document.activeElement?.dataset.field,activeValue:document.activeElement?.value,selected:[...host.querySelectorAll('.pf-selected')].map(el=>Number(el.dataset.eta))};};
   };
  },{base,original});
  for(const kind of ['planform','spars']){
   await page.evaluate(kind=>makeFixture(kind),kind);
   for(const edge of [0,1]){
    const group=page.locator('.planform-edge-table[data-edge="'+edge+'"]');await group.locator('.planform-point-add').click();
    const state=await page.evaluate(edge=>tableState(edge),edge),added=state.rows.find(row=>!original.some(point=>point.eta===row.eta));
    assert(added);assert.equal(added.eta,.4444);assert.equal(added.eta,Number(added.eta.toPrecision(4)));assert.equal(added.dxc,Number(added.dxc.toPrecision(4)));
    const eta=added.eta,a=original[0],b=original[1],fraction=(eta-a.eta)/(b.eta-a.eta),chord=e=>1-.6*e,expected=((1-fraction)*a.dxc*chord(a.eta)+fraction*b.dxc*chord(b.eta))/chord(eta);
    assert.equal(added.dxc,Number(expected.toPrecision(4)));assert.deepEqual(state.rows.map(row=>row.eta),[original[0].eta,.4444,original[1].eta]);
    for(const point of original)assert.equal(state.rows.find(row=>row.eta===point.eta).dxc,point.dxc,'Existing precise offset is unchanged');
    assert.equal(state.active,'eta');assert.equal(Number(state.activeValue),.4444);assert(state.selected.includes(.4444));
    if(kind==='spars'&&edge===1){assert.equal(added.stringer_angle,0);assert.equal(state.rows[0].stringer_angle,1.23456789);}
    checks.push(kind+' '+edge+': added values have four significant figures, interpolation uses rounded eta, rows are sorted and existing values retain precision');
   }
   // Change the first row past the other rows: keep its DOM node/focus and
   // subsequently remove that very row rather than its old numeric index.
   await page.evaluate(()=>{const input=document.querySelector('.planform-edge-table[data-edge="0"] [data-field="eta"]:not(:disabled)');window.moving=input;input.focus();input.value='.90123456789';input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));});
   let state=await page.evaluate(()=>tableState(0));assert.deepEqual(state.rows.map(row=>row.eta),[.4444,original[1].eta,.90123456789]);assert.equal(state.activeValue,'.90123456789');assert.equal(await page.evaluate(()=>document.activeElement===moving),true);
   assert.equal(await page.evaluate(()=>moving.closest('tr').querySelector('th').textContent),kind==='spars'?'F4':'L4');
   assert(state.selected.includes(.90123456789));
   await page.evaluate(()=>moving.closest('tr').querySelector('.planform-point-remove').click());state=await page.evaluate(()=>tableState(0));assert.deepEqual(state.rows.map(row=>row.eta),[.4444,original[1].eta]);
   checks.push(kind+': committed eta edits reorder rows immediately, preserve focus/selection/precision and keep Remove attached to the edited point');
   if(kind==='spars'){
    await page.evaluate(()=>{const input=document.querySelector('.planform-edge-table[data-edge="1"] [data-field="eta"]:not(:disabled)');window.snapping=input;input.focus();input.value='.95';input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));});
    const expected=await page.evaluate(()=>WingSparView.snapPoint(editor.readDrafts(),1,3).eta);
    await page.evaluate(()=>snapping.closest('tr').querySelector('.planform-point-snap').click());state=await page.evaluate(()=>tableState(1));
    assert(state.rows.some(row=>row.eta===expected&&row.dxc===original[0].dxc));assert(state.rows.some(row=>row.eta===original[1].eta&&row.dxc===original[1].dxc));
    checks.push('spar Snap to rib follows the reordered row, with the original precise offset');
   }
  }
  await page.evaluate(()=>makeFixture('planform'));await page.locator('.planform-edge-table[data-edge="0"] .planform-point-add').click();
  const dot=page.locator('.pf-point[data-edge="0"][data-eta="0.4444"] .pf-point-dot');await dot.scrollIntoViewIfNeeded();const bounds=await dot.boundingBox(),x=bounds.x+bounds.width/2,y=bounds.y+bounds.height/2;
  await page.mouse.move(x,y);await page.mouse.down();await page.mouse.move(x+17.2,y+6.1,{steps:4});await page.mouse.up();
  const dragged=await page.evaluate(()=>tableState(0)),moved=dragged.rows.find(row=>!original.some(point=>point.eta===row.eta));
  assert(moved&&moved.eta>.4444);assert(dragged.selected.includes(moved.eta));assert.equal(dragged.canonical.find(row=>row.eta===moved.eta).dxc,moved.dxc);assert.notEqual(moved.eta,Number(moved.eta.toPrecision(4)),'The four-significant-figure rule applies to automatic additions, not user drags');
  checks.push('Dragging an added point preserves its selected identity and exact user-defined coordinates');
  // Repeated addition must not introduce equal eta values after rounding.
  await page.evaluate(()=>makeFixture('planform',[{eta:.00001234567,dxc:.0000001234567},{eta:.99999999,dxc:.0000009876543}]));
  for(let i=0;i<24;i++)await page.locator('.planform-edge-table[data-edge="0"] .planform-point-add').click();
  const dense=await page.evaluate(()=>tableState(0));assert.equal(dense.rows.length,26);assert.equal(new Set(dense.rows.map(row=>row.eta)).size,26);assert(dense.rows.every((row,index)=>!index||row.eta>dense.rows[index-1].eta));
  for(const row of dense.rows.slice(1,-1)){assert.equal(row.eta,Number(row.eta.toPrecision(4)));assert.equal(row.dxc,Number(row.dxc.toPrecision(4)));}
  checks.push('Repeated additions remain strictly ordered and unique after rounding, including very small offsets');
  assert.deepEqual(errors,[]);await page.locator('#editor').screenshot({path:path.join(out,'point-add-precision.png')});fs.writeFileSync(path.join(out,'point_add_precision.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){await page.screenshot({path:path.join(out,'point-add-failure.png'),fullPage:true});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
