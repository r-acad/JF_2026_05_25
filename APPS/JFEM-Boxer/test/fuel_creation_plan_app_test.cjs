"use strict";
// node fuel_creation_plan_app_test.cjs <fixture-dir> <evidence-dir> [playwright-module]
// Fixture: schema.json and payload.msgpack (gaps_ prefixes also accepted),
// describing four physical bays with fuel dry bays 2,4 and two airfoil sections.
// CHROME_PATH optionally selects a browser executable; otherwise use Playwright Chromium.
const fs=require("node:fs"),path=require("node:path"),assert=require("node:assert/strict");
const msgpack=require("../web/vendor/msgpack.min.js");
if(!process.argv[2]||!process.argv[3])throw Error("Usage: node fuel_creation_plan_app_test.cjs <fixture-dir> <evidence-dir> [playwright-module]");
const web=path.resolve(__dirname,"../web"),fixture=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]);
const fixtureFile=name=>{const file=path.join(fixture,name);return fs.existsSync(file)?file:path.join(fixture,"gaps_"+name);};
const {chromium}=require(process.argv[4]||"playwright");
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],posts=[];
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}),args:["--use-angle=swiftshader","--enable-unsafe-swiftshader"]});
 const context=await browser.newContext({viewport:{width:1450,height:1000}}),page=await context.newPage();
 const schema=JSON.parse(fs.readFileSync(fixtureFile("schema.json"),"utf8"));
 schema.values["fuel.enabled"]=false;schema.defaults["fuel.enabled"]=false;
 context.on("page",p=>p.on("pageerror",e=>errors.push(e.message)));page.on("pageerror",e=>errors.push(e.message));
 await context.route("http://127.0.0.1:43998/**",async route=>{
  const request=route.request(),url=new URL(request.url());if(request.method()==="POST")posts.push(url.pathname);
  if(url.pathname==="/api/input")return route.fulfill({json:schema});
  if(["/api/generate","/api/prepare_workspace"].includes(url.pathname)){
   const payload=msgpack.decode(fs.readFileSync(fixtureFile("payload.msgpack")));
   payload.model_params={...payload.model_params,...request.postDataJSON()};
   payload.fuel.enabled=payload.model_params["fuel.enabled"];
   return route.fulfill({body:Buffer.from(msgpack.encode(payload)),contentType:"application/msgpack"});
  }
  if(url.pathname==="/api/last_deck")return route.fulfill({json:{ok:true,available:false}});
  if(url.pathname==="/api/jfem_probe")return route.fulfill({json:{found:false}});
  if(url.pathname.startsWith("/api/"))return route.fulfill({status:404,json:{ok:false,error:"Isolated browser test endpoint"}});
  return route.fulfill({path:path.join(web,url.pathname==="/"?"index.html":decodeURIComponent(url.pathname))});
 });
 try{
  await page.goto("http://127.0.0.1:43998/");await page.locator('.startup-study-dialog [data-choice="new"]').click();
  await page.waitForFunction(()=>typeof state!=="undefined"&&state.data&&state.autoMeshReady&&!state.workspaceBusy,null,{timeout:120000});
  await page.evaluate(()=>{state.autoMeshEnabled=false;document.getElementById("auto-mesh").checked=false;cancelAutoMeshTimer();syncManualMeshAction();});
  await page.locator("#tab-fuel").click();
  assert.equal(await page.locator("#tab-fuel").isDisabled(),false);
  assert.equal(await page.locator("#tab-fuel").getAttribute("data-fuel-defined"),"false");
  assert(await page.locator("#btn-create-fuel-tank").isVisible());assert(await page.locator(".fuel-tank-view").isHidden());assert(await page.locator("#panel-fuel-volume").isHidden());
  assert.deepEqual(await page.locator('#group-fuel-tank button:visible, #group-fuel-tank input:visible').evaluateAll(els=>els.map(el=>el.id)),["btn-create-fuel-tank"]);
  await page.screenshot({path:path.join(out,"undefined-tank.png")});
  checks.push("Undefined tank tab stays accessible with a grey label and only Create Fuel Tank in its form");
  const initialPosts=posts.length;
  await page.locator("#btn-create-fuel-tank").focus();await page.keyboard.press("Enter");
  assert(await page.locator('[id="p-fuel.enabled"]').isChecked());assert(await page.locator(".fuel-tank-view").isVisible());
  assert(await page.locator("#panel-fuel-volume").isVisible());assert(await page.locator("#btn-create-fuel-tank").isHidden());
  assert.equal(await page.locator("#tab-fuel").getAttribute("data-fuel-defined"),"true");
  assert.equal(await page.locator('[id="p-fuel.disabled_bays"]').inputValue(),"2,4");
  assert.equal(posts.length,initialPosts);checks.push("Keyboard creation enables canonical fuel state, retains range/exclusions and shows the full existing form without a solver request");
  await page.screenshot({path:path.join(out,"created-tank.png")});
  const popup=page.waitForEvent("popup");await page.locator("#btn-open-plan-view").click();const plan=await popup;
  await plan.waitForSelector('.dpv-fuel-wet');
  assert.equal(await plan.locator('.dpv-fuel-wet').count(),2);assert.equal(await plan.locator('.dpv-fuel-dry').count(),2);
  await page.locator('[id="p-fuel.disabled_bays"]').fill("1-4");await plan.waitForFunction(()=>document.querySelectorAll('.dpv-fuel-wet').length===0);
  assert.equal(await plan.locator('.dpv-fuel-dry').count(),1);
  await page.locator('[id="p-fuel.disabled_bays"]').fill("2");await plan.waitForFunction(()=>document.querySelectorAll('.dpv-fuel-wet').length===2);
  await plan.locator('[data-dpv="mirror"]').check();assert.equal(await plan.locator('.dpv-fuel-wet').count(),4);assert.equal(await plan.locator('.dpv-fuel-dry').count(),2);
  await plan.locator('[data-dpv="showSpars"]').uncheck();await plan.locator('[data-dpv="showRibs"]').uncheck();assert.equal(await plan.locator('.dpv-fuel-wet').count(),4);
  await plan.screenshot({path:path.join(out,"dimensioned-plan-tank.png")});
  const fills=await plan.locator('.dpv-fuel:not(.dpv-mirrored)').evaluateAll(els=>els.map(el=>({kind:el.dataset.fuelRegion,fill:getComputedStyle(el).fill,opacity:Number(getComputedStyle(el).fillOpacity)})));
  assert(fills.every(fill=>fill.fill!=='none'&&fill.opacity>0&&fill.opacity<.3));assert(fills.filter(fill=>fill.kind==='wet').every(fill=>fill.opacity>fills.find(fill=>fill.kind==='dry').opacity));
  await plan.locator('[data-dpv="showSpars"]').check();await plan.locator('[data-dpv="showRibs"]').check();await plan.screenshot({path:path.join(out,"dimensioned-plan-filled-dark.png")});
  await plan.locator('[data-dpv="theme"]').click();await plan.screenshot({path:path.join(out,"dimensioned-plan-filled-white.png")});
  checks.push("Wet tank regions have a light translucent fill in dark and white views; dry bays remain distinct and underlying ribs/spars stay visible");
  checks.push("Detached Dimensioned plan updates exact wet/dry outlines live, mirrors them and retains them when structural layers are hidden");
  await page.locator('[id="p-fuel.enabled"]').uncheck();await plan.waitForFunction(()=>document.querySelectorAll('.dpv-fuel').length===0);
  assert(await page.locator("#btn-create-fuel-tank").isVisible());assert(await page.locator("#panel-fuel-volume").isHidden());
  await page.locator("#btn-create-fuel-tank").click();assert.equal(await page.locator('[id="p-fuel.disabled_bays"]').inputValue(),"2");
  await page.evaluate(()=>{const values=collectParams();buildForm(state.schema,values);});
  assert(await page.locator(".fuel-tank-view").isVisible());assert(await page.locator("#btn-create-fuel-tank").isHidden());
  checks.push("Disabling a tank clears the detached outline; recreating and rebuilding an existing definition preserve its settings and full form");
  await page.evaluate(()=>{state.importedDeck={name:"Read-only reference"};state.fuelTankView.refresh();document.getElementById("p-fuel.enabled").checked=false;document.getElementById("btn-create-fuel-tank").onclick();});
  assert(!(await page.locator('[id="p-fuel.enabled"]').isChecked()));assert(await page.locator("#btn-create-fuel-tank").isHidden());
  await page.evaluate(()=>{state.importedDeck=null;state.fuelTankView.refresh();});
  assert(await page.locator("#btn-create-fuel-tank").isVisible());
  checks.push("Imported-deck context hides and guards the generated-tank creation action");
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,"summary.json"),JSON.stringify({passed:true,checks,errors,posts},null,2));
  console.log(`Fuel creation and detached plan: ${checks.length} app interaction groups passed.`);
 }catch(error){fs.writeFileSync(path.join(out,"failure.json"),JSON.stringify({error:error.stack,checks,errors,posts},null,2));await page.screenshot({path:path.join(out,"failure.png")});throw error;}
 finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
