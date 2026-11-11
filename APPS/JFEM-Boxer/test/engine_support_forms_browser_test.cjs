'use strict';
// Actual form styles and automatic help must not prevent attachment/support edits.
// node engine_support_forms_browser_test.cjs OUTPUT PLAYWRIGHT_MODULE
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const [out,modulePath='playwright']=process.argv.slice(2),web=path.resolve(__dirname,'../web');
if(!out)throw Error('Expected output folder');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const {chromium}=require(modulePath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined}),page=await browser.newPage({viewport:{width:1100,height:1200}}),errors=[],checks=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.setContent('<main id="workspace-content"><section id="group-engines" class="parameter-section"><div class="parameter-heading"><h2>Engines</h2></div><input id="p-engines.items" type="hidden" value="[]"></section><section id="group-rbe3-and-supports" class="parameter-section"><select id="p-supports.mode"><option value="root">Root</option><option value="custom">Custom</option></select><div id="row-supports.items"><input id="p-supports.items" type="hidden" value="[]"></div></section></main>');
  for(const file of ['style.css','engines.css','supports.css','ui_consistency.css','form_help.css'])await page.addStyleTag({path:path.join(web,file)});
  await page.addStyleTag({content:'body{display:block;overflow:auto;background:#14202c;color:#dceafa;font:14px system-ui;margin:12px}#workspace-content{width:380px;padding:14px}'});
  for(const file of ['engines.js','supports.js','form_help.js'])await page.addScriptTag({path:path.join(web,file)});
  await page.evaluate(()=>{
   window.locked=false;window.edits=[];window.ribs=Array.from({length:7},(_,i)=>({index:i+1,eta:i/6}));
   window.engines=WingEngines.install(document.getElementById('group-engines'),{readRibs:()=>ribs,isLocked:()=>locked,onEdit:key=>{edits.push(key);engines.refresh();}});
   window.supports=WingSupports.install(document.getElementById('group-rbe3-and-supports'),{readRibs:()=>ribs,isLocked:()=>locked,onEdit:key=>edits.push(key)});
   window.help=WingFormHelp.install(document);
  });
  await page.locator('[id="p-supports.mode"]').selectOption('custom');await page.locator('#support-add').click();
  await page.waitForFunction(()=>document.querySelector('.support-dof input').hasAttribute('aria-describedby'));
  const dof=n=>page.locator('.support-dof').nth(n-1),color=n=>dof(n).locator('.support-dof-caption').evaluate(el=>getComputedStyle(el).backgroundColor);
  // The tooltip injector inserts its own span after the input. Selection must
  // still be legible and clicking any numbered tile must toggle its own DOF.
  const selected=await dof(3).locator('input').isChecked();assert(selected);
  const before=await color(3);await dof(1).click();
  assert(await dof(1).locator('input').isChecked());assert.equal(await color(1),before);
  await dof(3).click();assert(!(await dof(3).locator('input').isChecked()));assert.notEqual(await color(3),before);
  await dof(6).locator('input').focus();await page.keyboard.press('Space');
  assert.equal(await page.evaluate(()=>JSON.parse(document.getElementById('p-supports.items').value)[0].dofs),'16');
  await page.locator('[aria-label="Constraint rib"]').fill('5');await page.locator('[aria-label="Constraint location"]').selectOption('rear_lower');
  assert.deepEqual(await page.evaluate(()=>supports.readDrafts()['supports.items']),[{rib:5,target:'rear_lower',dofs:'16'}]);
  checks.push('Custom constraints select distinct DOFs by mouse and keyboard, show checked state with automatic tooltips, and persist target/rib/DOFs.');
  await page.locator('#engine-add').click();
  for(const key of ['front_rib','aft_rib'])await page.locator('[data-engine-rib='+key+']').selectOption('5');
  assert.equal(await page.evaluate(()=>engines.readDrafts()['engines.items'][0].front_rib),5);
  await page.evaluate(()=>{window.ribs=[];engines.refresh();});
  const front=page.locator('[data-engine-field=front_rib]');assert(await front.isVisible());assert(!(await front.isDisabled()));
  await front.fill('6');await page.locator('[data-engine-field=aft_rib]').fill('4');
  assert.deepEqual(await page.evaluate(()=>{const row=engines.readDrafts()['engines.items'][0];return[row.front_rib,row.aft_rib];}),[6,4]);
  await page.evaluate(()=>{window.ribs=Array.from({length:7},(_,i)=>({index:i+1,eta:i/6}));engines.refresh();});
  assert.equal(await page.locator('[data-engine-rib=front_rib]').inputValue(),'6');assert.equal(await page.locator('[data-engine-rib=aft_rib]').inputValue(),'4');
  assert(await front.isHidden());
  checks.push('Attachment ribs stay editable before or between FEM generations; the numbered catalog restores without replacing entered attachments.');
  await page.evaluate(()=>{locked=true;for(const id of ['group-engines','group-rbe3-and-supports'])document.getElementById(id).dispatchEvent(new Event('parameterlockchange'));});
  assert(await page.locator('[data-engine-rib=front_rib]').isDisabled());for(let n=1;n<=6;n++)assert(await dof(n).locator('input').isDisabled());
  await page.evaluate(()=>{locked=false;for(const id of ['group-engines','group-rbe3-and-supports'])document.getElementById(id).dispatchEvent(new Event('parameterlockchange'));});
  assert(!(await page.locator('[data-engine-rib=front_rib]').isDisabled()));await dof(2).click();assert(await dof(2).locator('input').isChecked());
  checks.push('Mesh locking protects physical edits and unlocking restores all engine/support controls.');
  assert.deepEqual(errors,[]);await page.screenshot({path:path.join(out,'engine-support-forms.png'),fullPage:true});fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png'),fullPage:true});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
