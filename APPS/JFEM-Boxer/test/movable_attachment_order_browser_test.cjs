'use strict';
// node movable_attachment_order_browser_test.cjs OUTPUT [PLAYWRIGHT]
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const [out,modulePath='playwright']=process.argv.slice(2),web=path.resolve(__dirname,'../web');
if(!out)throw Error('Expected output folder');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const {chromium}=require(modulePath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined}),page=await browser.newPage({viewport:{width:1200,height:1400}}),errors=[],checks=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.setContent('<html><body><div id="canonical" hidden></div><main id="structure"></main></body></html>');
  for(const file of ['style.css','movable_surfaces.css'])await page.addStyleTag({path:path.join(web,file)});
  await page.addStyleTag({content:'body{display:block;overflow:auto;background:#14202c;color:#dceafa;font:14px system-ui;margin:12px}#structure{width:900px;padding:14px;border:1px solid #426078}'});
  await page.addScriptTag({path:path.join(web,'movable_structure.js')});
  await page.evaluate(()=>{
   window.locked=false;window.edits=[];
   window.geometry=[{name:'Flap',kind:'flap',eta_start:.1,eta_end:.9},{name:'Aileron',kind:'aileron',eta_start:.6,eta_end:.95}];
   window.ribs=Array.from({length:9},(_,i)=>({index:i+1,eta:(i+1)/10}));
   const values={'movable_structure.surfaces':geometry.map(s=>({...WingMovableStructure.defaults,surface:s.name})),'movable_structure.attachments':[['Flap',.6],['Aileron',.7],['Flap',.2],['Flap',.4]].map(([surface,eta])=>({...WingMovableStructure.attachmentDefaults,surface,eta,rib:Math.round(eta*10)}))};
   for(const[key,value]of Object.entries(values)){const e=document.createElement('input');e.id='p-'+key;e.value=JSON.stringify(value);document.querySelector('#canonical').append(e);}
   window.installEditor=()=>WingMovableStructure.install(document.querySelector('#structure'),{readGeometry:()=>geometry,readRibs:()=>ribs,readMaterials:()=>[{id:1,name:'Aluminium'}],onEdit:key=>edits.push(key),isLocked:()=>locked});window.editor=installEditor();
  });
  const selected=()=>page.locator('.movable-structure:not([hidden])'),etas=()=>selected().locator('[data-movable-structure-field=eta]').evaluateAll(ee=>ee.map(e=>e.value));
  assert.deepEqual(await etas(),['0.2','0.4','0.6']);assert.equal(await page.evaluate(()=>edits.length),0);
  assert.deepEqual(await page.evaluate(()=>editor.readDrafts()['movable_structure.attachments'].map(a=>[a.surface,a.eta])),[['Aileron',.7],['Flap',.2],['Flap',.4],['Flap',.6]]);
  checks.push('Unsorted legacy attachments display in eta order without dirtying the Study; serialized drafts are canonical across surfaces');
  await selected().locator('[data-movable-structure-field=eta]').nth(1).evaluate(e=>e.dataset.testAttachment='moving');
  const moving=page.locator('[data-test-attachment=moving]');await moving.fill('');
  assert(await moving.evaluate(e=>document.activeElement===e));assert.deepEqual(await etas(),['0.2','','0.6']);
  await moving.fill('.83');assert.deepEqual(await etas(),['0.2','.83','0.6']);assert(await moving.evaluate(e=>document.activeElement===e));
  await moving.press('Tab');assert.deepEqual(await etas(),['0.2','0.6','0.8']);assert.equal(await moving.inputValue(),'0.8');
  let stored=await page.evaluate(()=>JSON.parse(document.getElementById('p-movable_structure.attachments').value));assert.deepEqual(stored.filter(a=>a.surface==='Flap').map(a=>a.eta),[.2,.6,.8]);
  checks.push('Incomplete and valid numeric typing keep focus and field position; committed eta snaps and immediately reorders the same attachment');
  await page.locator('.movable-bearing').filter({has:moving}).locator('.movable-rib-select').selectOption('3');assert.deepEqual(await etas(),['0.2','0.3','0.6']);
  await selected().getByRole('button',{name:'+ Add attachment',exact:true}).click();assert.deepEqual(await etas(),['0.2','0.3','0.6','0.7']);
  await page.locator('.movable-bearing').filter({has:moving}).getByRole('button',{name:'Remove attachment',exact:true}).click();assert.deepEqual(await etas(),['0.2','0.6','0.7']);
  await selected().getByRole('button',{name:'+ Add attachment',exact:true}).click();assert.deepEqual(await etas(),['0.2','0.4','0.6','0.7']);
  await page.evaluate(()=>editor.refresh());assert.deepEqual(await etas(),['0.2','0.4','0.6','0.7']);
  checks.push('Direct rib selection, adding at either end or between stations, removing, and refreshing all retain eta order');
  await page.locator('#movable-structure-edit').selectOption('1');assert.deepEqual(await etas(),['0.7']);await page.locator('#movable-structure-edit').selectOption('0');assert.deepEqual(await etas(),['0.2','0.4','0.6','0.7']);
  const saved=await page.evaluate(()=>editor.readDrafts());await page.evaluate(saved=>{editor.destroy();document.querySelector('#structure').replaceChildren();for(const[key,value]of Object.entries(saved))document.getElementById('p-'+key).value=JSON.stringify(value);editor=installEditor();},saved);
  assert.deepEqual(await page.evaluate(()=>editor.readDrafts()),saved);assert.deepEqual(await etas(),['0.2','0.4','0.6','0.7']);
  assert.match(await selected().locator('.movable-snap-note').first().textContent(),/z\/t >= -0\.5/);
  await page.evaluate(()=>{locked=true;document.querySelector('#structure').dispatchEvent(new Event('parameterlockchange'));});assert(await selected().locator('[data-movable-structure-field=eta]').first().isDisabled());assert.deepEqual(await etas(),['0.2','0.4','0.6','0.7']);
  checks.push('Surface switching, Study serialization/reload, and parameter locking preserve the order; tooltips describe the lower-contour attachment rule');
  assert.deepEqual(errors,[]);await page.screenshot({path:path.join(out,'attachments-in-span-order.png'),fullPage:true});fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(e){await page.screenshot({path:path.join(out,'failure.png'),fullPage:true});throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
