'use strict';
// Real application integration: new Study/draft rib catalogs, form signatures,
// selection persistence and help-enhanced custom DOFs. No solver is launched.
// node engine_support_app_browser_test.cjs URL OUTPUT PLAYWRIGHT_MODULE
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const [url,out,modulePath='playwright']=process.argv.slice(2);
if(!url||!out)throw Error('Expected URL and output folder');fs.mkdirSync(out,{recursive:true});
(async()=>{
 const {chromium}=require(modulePath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined,args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']}),page=await browser.newPage({viewport:{width:1600,height:1100}}),errors=[],checks=[];
 page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(90000);
 try{
  await page.goto(url);await page.getByRole('button',{name:'Start new study',exact:true}).click();
  await page.waitForFunction(()=>state.autoMeshReady&&!state.workspaceBusy&&!state.loadingInput);
  await page.evaluate(()=>{document.getElementById('auto-mesh').checked=false;document.getElementById('auto-save').checked=false;state.autosave?.destroy();});
  const original=await page.evaluate(()=>({catalog:currentSupportRibs(),mesh:!!state.data?.nodes}));assert(original.catalog.length>4);
  await page.evaluate(()=>activateWorkspaceTab('engines'));await page.locator('#engine-add').click();
  const front=page.locator('[data-engine-rib=front_rib]'),aft=page.locator('[data-engine-rib=aft_rib]');
  await front.selectOption('3');await aft.selectOption('4');
  assert.deepEqual(await page.evaluate(()=>{const e=collectParams()['engines.items'][0];return[e.front_rib,e.aft_rib];}),[3,4]);
  // A new/dirtied layout should immediately offer its physical ribs without
  // first needing to mesh an engine with potentially incorrect attachments.
  await page.evaluate(()=>{const input=document.getElementById('p-box.rib_pitch');input.value=String(Number(input.value)*.8);input.dispatchEvent(new Event('input',{bubbles:true}));});
  const changed=await page.evaluate(()=>currentSupportRibs());assert(changed.length>original.catalog.length);
  assert(!(await front.isDisabled()));await front.selectOption('5');await aft.selectOption('6');
  assert.deepEqual(await page.evaluate(()=>{const e=collectParams()['engines.items'][0];return[e.front_rib,e.aft_rib];}),[5,6]);
  assert.match(await front.locator('option:checked').textContent(),/^R5 · eta /);
  checks.push('Engine ribs can be selected in a new Study before FEM generation; changing rib pitch refreshes draft choices and collects the chosen attachments.');
  await page.evaluate(()=>activateWorkspaceTab('supports'));await page.locator('[id="p-supports.mode"]').selectOption('custom');await page.locator('#support-add').click();
  const dof=n=>page.locator('.support-row').last().locator('.support-dof').nth(n-1);
  await page.waitForFunction(()=>document.querySelector('.support-dof input')?.hasAttribute('aria-describedby'));
  await dof(1).click();await dof(2).click();await dof(6).click();
  await page.locator('[aria-label="Constraint rib"]').last().fill('3');await page.locator('[aria-label="Constraint location"]').last().selectOption('front_lower');
  const custom=await page.evaluate(()=>collectParams()['supports.items'].at(-1));assert.deepEqual(custom,{rib:3,target:'front_lower',dofs:'1236'});
  const colors=await Promise.all([1,4].map(n=>dof(n).locator('.support-dof-caption').evaluate(el=>getComputedStyle(el).backgroundColor)));assert.notEqual(colors[0],colors[1]);
  const params=await page.evaluate(()=>collectParams());await page.evaluate(params=>{buildForm(state.schema,params);syncImportedModelMode();},params);await page.evaluate(()=>activateWorkspaceTab('supports'));
  assert.deepEqual(await page.evaluate(()=>collectParams()['supports.items'].at(-1)),custom);
  await page.evaluate(()=>activateWorkspaceTab('engines'));assert.deepEqual(await page.evaluate(()=>{const e=collectParams()['engines.items'][0];return[e.front_rib,e.aft_rib];}),[5,6]);
  checks.push('Real custom-constraint tiles select/paint correct DOFs and survive canonical parameter collection and a complete form rebuild alongside engine attachments.');
  await page.evaluate(()=>activateWorkspaceTab('display'));
  const canvas=page.locator('#render'),rect=await canvas.boundingBox();
  async function orbit(){
   const before=await page.evaluate(()=>state.camera.alpha);
   await page.mouse.move(rect.x+rect.width*.55,rect.y+rect.height*.5);await page.mouse.down({button:'left'});await page.mouse.move(rect.x+rect.width*.55+85,rect.y+rect.height*.5+30,{steps:8});await page.mouse.up({button:'left'});
   await page.waitForTimeout(200);assert(Math.abs(await page.evaluate(()=>state.camera.alpha)-before)>.001);
  }
  await orbit();await page.evaluate(()=>workspaceOperation(async()=>true,'Testing navigation restoration'));
  assert(!(await page.locator('#app').evaluate(el=>el.inert)));await orbit();
  checks.push('Actual Babylon orbit remains responsive after engine/support edits and form rebuilding, and workspace-operation input detachment restores navigation.');
  assert.deepEqual(errors,[]);await page.screenshot({path:path.join(out,'engine-catalog.png')});await page.evaluate(()=>activateWorkspaceTab('supports'));await page.screenshot({path:path.join(out,'custom-constraints.png')});fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,errors,initialHadFEM:original.mesh,originalRibs:original.catalog.length,draftRibs:changed.length,custom},null,2));console.log(JSON.stringify({passed:true,checks}));
 }catch(error){await page.screenshot({path:path.join(out,'failure.png')});fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,errors},null,2));throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
