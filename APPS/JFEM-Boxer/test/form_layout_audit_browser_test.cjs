'use strict';
// Run against an owned QA server. No solver run or saved input is modified.
// node form_layout_audit_browser_test.cjs URL OUTPUT PLAYWRIGHT
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [url,out,modulePath]=process.argv.slice(2),{chromium}=require(modulePath);
(async()=>{fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu','--disable-gpu-sandbox']}),page=await browser.newPage({viewport:{width:1700,height:1100}}),errors=[],inventory=[];page.on('pageerror',e=>errors.push(e.message));
try{await page.goto(url,{timeout:120000});await page.getByRole('button',{name:'Start new study',exact:true}).click();await page.waitForFunction(()=>state.data?.nodes?.count&&workspaceOperationAvailable(),null,{timeout:240000});
await page.evaluate(()=>{document.getElementById('auto-save').checked=false;state.autosave?.destroy();document.getElementById('auto-mesh').checked=false;document.getElementById('auto-mesh').dispatchEvent(new Event('change',{bubbles:true}));});
// Exercise repeated editors instead of auditing only their empty introductions.
await page.evaluate(()=>{document.getElementById('movable-add')?.click();document.getElementById('movable-structure-add')?.click();document.querySelector('.movable-bearings + .movable-actions button')?.click();document.getElementById('engine-add')?.click();for(const b of document.querySelectorAll('[data-loft-add]'))b.click();document.getElementById('btn-create-fuel-tank')?.click();});
const before=await page.evaluate(()=>collectParams());
await page.evaluate(()=>{const p=collectParams();buildForm(state.schema,p);buildForm(state.schema,p);});
assert.deepEqual(await page.evaluate(()=>collectParams()),before,'Layout and repeated form construction must preserve every model field');
assert.deepEqual(await page.evaluate(()=>{const ids=[...document.querySelectorAll('[id]')].map(e=>e.id);return ids.filter((id,i)=>ids.indexOf(id)!==i);}),[],'Canonical controls must not be duplicated');
for(const id of ['group-loft','group-movable-surfaces','group-movable-structures']){
 await page.evaluate(id=>activateWorkspaceTab(document.getElementById(id).dataset.workspacePanel),id);
 assert.equal(await page.locator('#'+id+' > .parameter-heading :is(.help-icon,.help-button)').count(),1);
 assert.equal(await page.locator('#'+id+' .group-note > button[aria-label^="Help:"]').count(),0);
 await page.locator('#'+id+' > .parameter-heading .help-button').click();
 assert(await page.locator('#help-dialog').isVisible(),'Contextual help keeps its live handler after moving');
 assert((await page.locator('#help-dialog').innerText()).length>150);
 await page.locator('#btn-close-help').click();
}
await page.evaluate(()=>activateWorkspaceTab('movablestructure'));
assert(await page.locator('#movable-structure-select').isHidden(),'No redundant empty add selector when every surface is already structured');
await page.evaluate(()=>{const select=document.getElementById('movable-structure-select');const option=document.createElement('option');option.value=option.textContent='Availability check';select.append(option);});
assert(await page.locator('#movable-structure-select').isVisible(),'The selector returns as soon as a structure can be added');
await page.evaluate(()=>document.getElementById('movable-structure-select').replaceChildren());
const tabs=await page.evaluate(()=>WORKSPACE_TABS.map(([group,id,label])=>({group,id,label})));
for(const width of [300,360,540,660,'max'])for(const tab of tabs){await page.evaluate(({tab,width})=>{setWorkspaceMaximized(null);activateWorkspaceTab(tab.id);if(width==='max')setWorkspaceMaximized(tab.id);else setPaneWidth(width);const host=document.getElementById('workspace-content');host.scrollTop=0;for(const d of host.querySelectorAll('details'))if(!d.closest('[hidden]'))d.open=true;},{tab,width});await page.waitForTimeout(30);
const row=await page.evaluate(()=>{const host=document.getElementById('workspace-content'),b=host.getBoundingClientRect(),visible=e=>e.getClientRects().length>0&&!e.closest('[hidden]'),controls=[...host.querySelectorAll('input:not([type=hidden]),select,textarea,button')].filter(visible),overflow=[];
for(const e of controls){const r=e.getBoundingClientRect();let scrolling=false;for(let p=e.parentElement;p&&p!==host;p=p.parentElement){const s=getComputedStyle(p);if(['auto','scroll'].includes(s.overflowX)&&p.scrollWidth>p.clientWidth+1){scrolling=true;break;}}if(!scrolling&&(r.left<b.left-1||r.right>b.right+1))overflow.push({id:e.id,tag:e.tagName,label:e.getAttribute('aria-label')||e.closest('label')?.textContent?.trim().slice(0,90)||e.textContent.trim().slice(0,90),left:r.left-b.left,right:r.right-b.right,outer:e.outerHTML.slice(0,150)});}
return{actualWidth:b.width,scrollWidth:host.scrollWidth,height:host.scrollHeight,controls:controls.length,headings:[...host.querySelectorAll('h2,h3,legend,summary')].filter(visible).map(e=>e.textContent.trim()),overflow};});inventory.push({...tab,width,...row});
if((width===360&&['planform','airfoils','loft','movablesurfaces','movablestructure','engines','material','sections','analysis','cases','displayproperties','displayloads','stressreport'].includes(tab.id))||(width==='max'&&['loft','movablestructure','engines','ribs','analysis','displayloads','cases'].includes(tab.id))){
 // All disclosures were inspected above; use their normal closed state in
 // overview screenshots so open setting panels do not obscure the drawing.
 await page.evaluate(()=>{for(const d of document.querySelectorAll('.svgv-image-options,.ui-form-help,.form-help'))d.open=false;});
 await page.screenshot({path:path.join(out,tab.id+'-'+width+'.png')});
}
}
fs.writeFileSync(path.join(out,'inventory.json'),JSON.stringify({errors,inventory},null,2));
const overflow=inventory.filter(r=>r.overflow.length).map(r=>({tab:r.id,width:r.width,overflow:r.overflow}));
assert.deepEqual(errors,[]);assert.deepEqual(overflow,[],'Every form control must fit its pane or a deliberate table scroller');
assert.equal(tabs.length,42,'Audit inventory must include every current sub-tab');
const summary={passed:true,tabs:tabs.length,samples:inventory.length,checks:['All 42 sub-tabs reviewed at 300/360/540/660px and maximized','Repeated form builds preserve all parameters and unique control IDs','Contextual group help replaces duplicate generic actions and retains working handlers','Empty Add-structure selector disappears and returns with available options','Expanded drawing settings remain within the resizable pane'],errors};
fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(summary,null,2));console.log(JSON.stringify(summary));
}catch(e){fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:e.stack,errors},null,2));throw e;}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
