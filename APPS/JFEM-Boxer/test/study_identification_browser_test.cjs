"use strict";
// Component browser test; no running user app or Study file is changed.
// node study_identification_browser_test.cjs <output-dir> <playwright-module> [browser]
const assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path");
const[outArg,playwrightArg,browserArg]=process.argv.slice(2);if(!outArg||!playwrightArg)throw Error("Output directory and Playwright module are required");
const out=path.resolve(outArg),web=path.resolve(__dirname,"../web"),{chromium}=require(path.resolve(playwrightArg));
(async()=>{fs.mkdirSync(out,{recursive:true});const browser=await chromium.launch({headless:true,...(browserArg?{executablePath:browserArg}:{})});const page=await browser.newPage({viewport:{width:1400,height:950}}),checks=[],errors=[];page.on("pageerror",e=>errors.push(e.message));
 try{
  await page.setContent('<!doctype html><html><head><style>body{margin:0;background:#132438;color:white;font:14px system-ui}#controls{height:140px;width:380px}#stage{width:800px;background:white}.svgv-host svg{display:block;width:100%;height:300px}#viewport{width:800px;height:300px;background:#0a1725}canvas{display:block;width:100%;height:100%}#small{width:20px;height:20px}#loft{width:500px;height:180px;background:#fff}</style></head><body><div id="controls"></div><div id="stage"><svg viewBox="0 0 800 300"><path id="geometry" d="M100 100L400 80L600 200Z" fill="#2299bb"/></svg></div><div id="viewport"><canvas id="render" width="800" height="300"></canvas></div><svg id="loft" class="loft-distribution-plot" viewBox="0 0 640 220"><path d="M0 200L640 20" stroke="red"/></svg><button><svg id="small" viewBox="0 0 24 24"><path d="M0 0L24 24"/></svg></button></body></html>');
  for(const file of ["study_watermark.css","study_comments.css","startup_study.css","svg_viewport.css"])await page.addStyleTag({path:path.join(web,file)});
  for(const file of ["study_watermark.js","reference_import.js","workspace.js","study_comments.js","startup_study.js","svg_viewport.js"])await page.addScriptTag({path:path.join(web,file)});
  await page.evaluate(()=>{window.changeLog=[];window.identity=WingStudyWatermark.create({document,host:document.getElementById("controls"),onChange:value=>changeLog.push(value)});window.drawing=WingSVGViewport.install(document.querySelector("#stage svg"),{key:"identity-fixture"});});
  assert.equal(await page.locator(".study-watermark-overlay:visible").count(),0);
  await page.locator("#study-identification-text").fill('Student 42 <b>CONFIDENTIAL</b>');await page.locator("#show-study-watermark").check();
  await page.waitForFunction(()=>document.querySelectorAll(".study-watermark-overlay:not([hidden])").length===3);
  assert.equal(await page.locator(".study-watermark-overlay b").count(),0);assert.equal(await page.locator("button .study-watermark-overlay").count(),0);
  assert.equal(await page.locator("#geometry").getAttribute("d"),"M100 100L400 80L600 200Z");
  assert.equal(await page.locator(".study-watermark-overlay").first().evaluate(e=>getComputedStyle(e).pointerEvents),"none");
  checks.push("Identification is literal text in 2D, 3D and loft views; icons and geometry are untouched and pointer events pass through");
  const exported=await page.evaluate(()=>drawing.exportSVG());assert(exported.includes("data-study-watermark"));assert(exported.includes("&lt;b&gt;CONFIDENTIAL&lt;/b&gt;"));assert(!exported.includes("<b>"));
  await page.evaluate(()=>{document.getElementById("stage").style.width="1100px";document.querySelector("#stage svg").style.height="440px";});
  await page.waitForFunction(()=>Math.abs(document.querySelector("#stage .study-watermark-overlay").getBoundingClientRect().width-1100)<1);
  const dimensions=await page.evaluate(()=>{const a=document.querySelector("#stage svg").getBoundingClientRect(),b=document.querySelector("#stage .study-watermark-overlay").getBoundingClientRect();return{dx:a.x-b.x,dy:a.y-b.y,dw:a.width-b.width,dh:a.height-b.height};});for(const value of Object.values(dimensions))assert(Math.abs(value)<1);
  checks.push("SVG exports retain the watermark and the overlay follows an enlarged drawing exactly");
  await page.screenshot({path:path.join(out,"identification-views.png"),fullPage:true});
  await page.locator("#study-identification-text").fill("");await page.waitForFunction(()=>document.querySelectorAll(".study-watermark-overlay:not([hidden])").length===0);
  await page.evaluate(()=>identity.restore(null));assert.deepEqual(await page.evaluate(()=>identity.capture()),{text:"",visible:false});
  checks.push("Clearing text and loading a legacy/new Study remove the previous identification");
  await page.evaluate(()=>{window.startupResult=null;WingStartupStudy.choose({recentStudies:{list:()=>[]},onChoose:(choice,identification)=>{startupResult={choice,identification};}});});
  await page.locator('[data-study-identification="text"]').fill("Assignment ABC");await page.locator('[data-study-identification="visible"]').check();await page.locator('[data-choice="new"]').click();
  assert.deepEqual(await page.evaluate(()=>startupResult),{choice:"new",identification:{text:"Assignment ABC",visible:true}});
  await page.evaluate(()=>{window.newResult="pending";WingStartupStudy.identify({document}).then(value=>newResult=value);});await page.locator(".startup-study-identification-actions button").first().click();await page.waitForFunction(()=>newResult!=="pending");assert.equal(await page.evaluate(()=>newResult),null);
  checks.push("Startup collects optional identification without an extra dialog; cancelling toolbar New Study preserves the current model");
  await page.evaluate(()=>{Object.defineProperty(navigator,"clipboard",{configurable:true,value:{writeText:async text=>window.clipboardText=text}});window.saved=null;WingStudyComments.promptSave({document,notes:null,location:WingWorkspace.studyLocation({name:"Wing.wingfem.json",handle:{path:"C:\\Course\\Wing.wingfem.json"}}),onSave:(text,options)=>{saved={text,options};return true;}});});
  assert.equal(await page.locator(".study-comments-dialog h2 + .study-save-location").count(),1);assert.equal(await page.locator("#study-save-current-path").inputValue(),"C:\\Course\\Wing.wingfem.json");
  await page.locator(".study-save-location-row button").click();assert.equal(await page.evaluate(()=>clipboardText),"C:\\Course\\Wing.wingfem.json");await page.locator(".study-comments-save").click();assert.equal(await page.evaluate(()=>saved.options.preferNative),true);
  await page.evaluate(()=>{WingStudyComments.promptSave({document,notes:null,location:WingWorkspace.studyLocation({name:"Browser.wingfem.json"}),onSave:()=>false});});assert.match(await page.locator(".study-save-location-status").innerText(),/does not expose/);assert.equal(await page.locator("#study-save-system-dialog").isChecked(),false);await page.locator(".study-comments-cancel").click();
  checks.push("Save headline includes a selectable/copyable true full path, while browser-only files report their filename limitation honestly");
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,"checks.json"),JSON.stringify({checks,errors},null,2));console.log(checks.join("\n"));
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
