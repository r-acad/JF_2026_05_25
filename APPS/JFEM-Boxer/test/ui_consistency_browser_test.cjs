'use strict';
// Layout regressions use the actual stylesheet stack, independently of Julia.
// node ui_consistency_browser_test.cjs [PLAYWRIGHT] [OUTPUT]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [modulePath='playwright',output]=process.argv.slice(2),web=path.resolve(__dirname,'../web');
const fixture=`<div id="workspace-content" style="width:360px;height:1100px;overflow:auto">
 <section class="workspace-panel parameter-section">
  <div class="parameter-heading"><h2>Structural subdivisions and interpolation</h2><button class="help-button" aria-label="Help">?</button></div>
  <fieldset class="ui-form-section"><legend>Mesh controls</legend>
   <div class="row"><label for="count">Number of elements in the vertical direction</label><input id="count" type="number" value="12"></div>
   <div class="row"><label for="choice">Interpolation method</label><select id="choice"><option>Cosine interpolation along the span</option></select></div>
   <label class="ui-toggle-row"><input id="toggle" type="checkbox" checked>Keep the lifting surface visible</label>
   <label class="layer"><input id="disabled-toggle" type="checkbox" disabled><span>Unavailable result overlay</span></label>
   <p class="pick-note">Mesh subdivisions control element count between adjacent structural stations.</p>
   <details class="ui-form-help" open><summary>How subdivisions work</summary><p>Related fields remain in a single group.</p></details>
  </fieldset>
  <div id="imported-analysis"><fieldset><legend>Buckling output</legend><label class="display-control imported-analysis-toggle"><input id="import-toggle" type="checkbox">Export element strain energy and density</label></fieldset></div>
  <fieldset class="geometry-appearance"><legend>Aerodynamic geometry</legend><div class="geometry-card-header"><label class="geometry-visibility"><input type="checkbox"><span>Deformed aerodynamic loft</span></label><div class="geometry-card-fields"><label class="display-control geometry-inline-control"><span class="geometry-control-caption">Finish</span><select><option>Translucent</option></select></label><input type="color" aria-label="Color" value="#00ffff"></div></div><label class="display-control">Translucency<input type="range"></label></fieldset>
  <fieldset class="movable-surface"><legend>Movable surface</legend><div class="movable-grid"><label>Surface name<input value="Outboard flap"></label><label>Upper skin thickness<input type="number" value="0.002"></label><label>Lower skin thickness<input type="number" value="0.002"></label></div></fieldset>
  <div class="sensitivity-filter-row"><select aria-label="Mode"><option>Wildcard</option></select><input aria-label="Property filter" placeholder="*skin*"><button>Clear filter</button></div>
  <div class="button-row"><button id="primary" class="primary">Run in JFEM</button><button class="mini">Inspect</button><button disabled>Unavailable</button></div>
  <div class="ui-form-disclosure" hidden><button>Must stay hidden</button></div><label class="display-control" hidden>Hidden choice<select><option>Hidden</option></select></label>
  <svg id="movable-plan-view" class="svgv-canvas" viewBox="0 0 100 50"><path d="M10 10H90V40H10Z" fill="#dceef8" stroke="#123"/></svg>
 </section></div>`;
(async()=>{
 const {chromium}=require(modulePath),browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||undefined});
 const page=await browser.newPage({viewport:{width:1400,height:1300}}),checks=[];
 try{
  await page.setContent(fixture);
  const index=fs.readFileSync(path.join(web,'index.html'),'utf8'),styles=[...index.matchAll(/<link[^>]+rel="stylesheet"[^>]+href="([^"?]+)(?:\?[^"]*)?"/g)].map(m=>m[1]);
  if(!styles.includes('ui_consistency.css'))styles.push('ui_consistency.css');
  for(const file of styles)await page.addStyleTag({content:fs.readFileSync(path.join(web,file),'utf8')});
  for(const width of [280,360,1000]){
   await page.locator('#workspace-content').evaluate((el,w)=>el.style.width=w+'px',width);
   const layout=await page.evaluate(()=>{
    const host=document.getElementById('workspace-content'),box=host.getBoundingClientRect(),visible=[...host.querySelectorAll('input,select,button,fieldset')].filter(el=>el.getClientRects().length);
    return {width:box.width,overflow:visible.filter(el=>{const b=el.getBoundingClientRect();return b.left<box.left-1||b.right>box.right+1}).map(el=>el.id||el.outerHTML.slice(0,150)),checkbox:document.getElementById('import-toggle').getBoundingClientRect().width,choice:document.getElementById('choice').getBoundingClientRect(),label:document.querySelector('label[for=choice]').getBoundingClientRect(),grid:getComputedStyle(document.querySelector('.movable-grid')).gridTemplateColumns};
   });
   assert.deepEqual(layout.overflow,[],`Controls overflow a ${width}px pane`);assert.equal(layout.checkbox,15);assert(layout.choice.y>layout.label.y,`Choice label should sit above control at ${width}px`);
   if(width===280)assert.equal(layout.grid.trim().split(/\s+/).length,1);
   checks.push(`Controls fit a ${width}px resizable pane; long choices and imported checkboxes remain usable`);
  }
  assert.equal(await page.locator('[hidden]:visible').count(),0);checks.push('Hidden controls remain hidden after flex and grid rules');
  // Injecting the base stylesheet starts the real 120ms button transition
  // from the browser's native background. Sample its final semantic color,
  // not an intermediate RGB value that depends on machine/frame timing.
  await page.locator('#primary').evaluate(el=>Promise.all(el.getAnimations().map(animation=>animation.finished.catch(()=>{}))));
  const appearance=await page.evaluate(()=>({canvas:getComputedStyle(document.getElementById('movable-plan-view')).backgroundColor,primary:getComputedStyle(document.getElementById('primary')).backgroundColor,disabled:document.getElementById('disabled-toggle').disabled,checked:document.getElementById('toggle').checked,control:getComputedStyle(document.getElementById('count')).height}));
  assert.equal(appearance.canvas,'rgb(255, 255, 255)');assert.equal(appearance.primary,'rgb(43, 127, 212)');assert(appearance.disabled&&appearance.checked);assert(parseFloat(appearance.control)>=32);checks.push('White drawing, semantic primary color, and native checkbox states are preserved');
  await page.locator('#count').focus();assert.equal(await page.locator('#count').evaluate(el=>getComputedStyle(el).outlineStyle),'solid');checks.push('Keyboard focus remains visible');
  if(output){fs.mkdirSync(output,{recursive:true});await page.locator('#workspace-content').evaluate(el=>el.style.width='360px');await page.screenshot({path:path.join(output,'form-consistency.png')});fs.writeFileSync(path.join(output,'style-summary.json'),JSON.stringify({passed:true,checks},null,2));}
  console.log(JSON.stringify({passed:true,checks}));
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
