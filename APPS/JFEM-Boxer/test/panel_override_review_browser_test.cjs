'use strict';
// node panel_override_review_browser_test.cjs <evidence-dir> <playwright-module>
// Production modal and styles; the controlled fixture simulates server conflicts.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
const affectedKey='upper:bay2:stringer5:segment1',retainedKey='lower:bay3:stringer4:segment1';
const original=[{key:affectedKey,skin:{thickness:.003,material:2},stringer:{height:.04,web_thickness:.002}},{key:retainedKey,skin:{thickness:.0025}}];
const conflict={code:'panel_override_conflict',message:'The panel boundary changed at this rib bay.',can_reconcile:true,compatible_rows:[{key:affectedKey,stringer:{height:.04,web_thickness:.002}},original[1]],affected_rows:[{key:affectedKey,reason:'Skin element membership changed; stringer membership is unchanged.',parts:['skin'],row:original[0]}],details:{old_rib_count:8,new_rib_count:9,old_stringer_count:12,new_stringer_count:12}};
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],browser=await chromium.launch({headless:true,channel:'chrome'}),page=await browser.newPage({viewport:{width:1280,height:1000},acceptDownloads:true});page.on('pageerror',error=>errors.push(error.message));
 try{
  await page.setContent('<!doctype html><html><head></head><body><button id="underlying">Create FEM</button></body></html>');
  for(const file of ['style.css','study_comments.css','ui_consistency.css'])await page.addStyleTag({path:path.join(web,file)});
  await page.addScriptTag({path:path.join(web,'panel_override_review.js')});
  await page.evaluate(({original,conflict})=>{
   window.original=original;window.conflict=conflict;window.current=true;window.applied=[];window.overrides=structuredClone(original);window.settled=null;
   window.showReview=(payload=conflict)=>{window.settled=null;window.pending=WingPanelOverrideReview.open(payload,{isCurrent:()=>current,onApply:rows=>{applied.push(rows);overrides=structuredClone(rows);return 'rebuild requested';}}).then(result=>{settled=result;return result;});};
  },{original,conflict});
  const modal=page.locator('.panel-override-review'),keep=page.getByRole('button',{name:'Keep all and return',exact:true}),apply=page.getByRole('button',{name:'Keep compatible assignments and rebuild',exact:true});
  await page.evaluate(()=>showReview());assert(await modal.isVisible());assert.equal(await keep.evaluate(button=>button===document.activeElement),true);
  const text=await modal.textContent();assert.match(text,/2 compatible override row\(s\) retained; 1 affected assignment/);assert.match(text,/Upper \/ R2-R3 \/ Stringer 5 \/ Segment 1/);assert.match(text,/Physical ribs: 8.*9/);
  const property=modal.locator('.study-comments-history pre');assert.equal(await property.count(),1);assert.match(await property.textContent(),/skin:[\s\S]*"thickness": 0.003[\s\S]*"material": 2/);assert.doesNotMatch(await property.textContent(),/web_thickness/);
  await modal.screenshot({path:path.join(out,'panel-override-review.png')});
  checks.push('Review identifies the affected physical panel, exact skin values and counts; retained stringer assignments are excluded from the reset list');
  await keep.click();await page.waitForFunction(()=>settled===false);assert.equal(await modal.count(),0);assert.deepEqual(await page.evaluate(()=>overrides),original);assert.equal(await page.evaluate(()=>applied.length),0);
  checks.push('Keep all and return closes the review without applying or removing assignments');
  await page.evaluate(()=>showReview());await page.keyboard.press('Escape');await page.waitForFunction(()=>settled===false);assert.equal(await modal.count(),0);assert.deepEqual(await page.evaluate(()=>overrides),original);assert.equal(await page.evaluate(()=>applied.length),0);
  checks.push('Escape cancels without modifying assignments');
  await page.evaluate(()=>showReview());const downloadEvent=page.waitForEvent('download');await page.getByRole('button',{name:'Download affected assignments',exact:true}).click();const download=await downloadEvent;assert.equal(download.suggestedFilename(),'panel-assignments-review.json');const saved=path.join(out,'panel-assignments-review.json');await download.saveAs(saved);assert.deepEqual(JSON.parse(fs.readFileSync(saved,'utf8')),{affected_rows:conflict.affected_rows,details:conflict.details});assert(await modal.isVisible());assert.equal(await page.evaluate(()=>applied.length),0);
  checks.push('Backup downloads exact affected original assignments and layout details without applying any change');
  await apply.click();await page.waitForFunction(()=>settled==='rebuild requested');assert.deepEqual(await page.evaluate(()=>applied),[conflict.compatible_rows]);assert.deepEqual(await page.evaluate(()=>overrides),conflict.compatible_rows);assert.equal(await modal.count(),0);
  checks.push('Accept passes exactly compatible_rows, including a partially retained stringer-only row, and returns the rebuild result');
  await page.evaluate(()=>{overrides=structuredClone(original);current=true;showReview();current=false;});await apply.click();assert(await modal.isVisible());assert(await apply.isDisabled());assert.match(await modal.locator('[role=alert]').textContent(),/inputs changed after this review/);assert.deepEqual(await page.evaluate(()=>overrides),original);assert.equal(await page.evaluate(()=>applied.length),1);await keep.click();await page.waitForFunction(()=>settled===false);
  checks.push('A stale review blocks Apply, explains the change and leaves current assignments intact');
  await page.evaluate(()=>{current=true;showReview({...conflict,can_reconcile:false});});assert.equal(await apply.count(),0);assert.match(await modal.textContent(),/could not be matched to a verified baseline/);assert.match(await modal.textContent(),/assignments have not been removed/);await keep.click();assert.deepEqual(await page.evaluate(()=>overrides),original);
  checks.push('An unmatched baseline hides the rebuild action and explains recovery without deleting overrides');
  const injection='<img src=x onerror="window.reviewInjected=true"><script>window.reviewInjected=true</script>';
  await page.evaluate(({injection})=>{window.reviewInjected=false;showReview({...conflict,message:injection,affected_rows:[{key:injection,reason:injection,parts:['skin'],row:{skin:{thickness:.003,note:injection}}}]});},{injection});
  assert.equal(await modal.locator('img,script').count(),0);assert.equal(await page.evaluate(()=>reviewInjected),false);assert((await modal.textContent()).includes(injection));assert((await modal.locator('pre').textContent()).includes('window.reviewInjected'));
  checks.push('Server-provided messages, panel keys, reasons and property values render as text, never HTML');
  await keep.click();await page.setViewportSize({width:390,height:844});await page.evaluate(()=>showReview());
  const fit=await modal.evaluate(dialog=>({dialog:dialog.scrollWidth<=dialog.clientWidth+1,buttons:[...dialog.querySelectorAll('button')].every(button=>{const b=button.getBoundingClientRect(),d=dialog.getBoundingClientRect();return b.left>=d.left&&b.right<=d.right;})}));assert(fit.dialog&&fit.buttons,JSON.stringify(fit));await modal.screenshot({path:path.join(out,'panel-override-review-narrow.png')});await keep.click();
  checks.push('The actual dialog styles keep property details and every action inside a narrow viewport');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'panel_override_review.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){await page.screenshot({path:path.join(out,'panel-override-review-failure.png'),fullPage:true});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
