"use strict";
const fs = require("node:fs"), path = require("node:path"), zlib = require("node:zlib"), assert = require("node:assert/strict");
const { chromium } = require(process.argv[3]), out = path.resolve(process.argv[2]);
const schema = JSON.parse(fs.readFileSync(process.argv[4], "utf8")), web = path.resolve(__dirname, "../web");
function png() {
  const width = 256, height = 128, pixels = Buffer.alloc((1 + width * 3) * height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const offset = y * (1 + width * 3) + 1 + x * 3, grid = x % 32 < 2 || y % 32 < 2;
    pixels[offset] = grid ? 58 : 218; pixels[offset + 1] = grid ? 113 : 224; pixels[offset + 2] = grid ? 148 : 204;
  }
  const crc32 = buffer => { let crc = -1; for (const byte of buffer) { crc ^= byte; for (let i = 0; i < 8; i++) crc = crc & 1 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1; } return (crc ^ -1) >>> 0; };
  const chunk = (name, payload) => { const data = Buffer.concat([Buffer.from(name), payload]), result = Buffer.alloc(payload.length + 12); result.writeUInt32BE(payload.length); data.copy(result, 4); result.writeUInt32BE(crc32(data), result.length - 4); return result; };
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header), chunk("IDAT", zlib.deflateSync(pixels)), chunk("IEND", Buffer.alloc(0))]);
}
(async () => {
  fs.mkdirSync(out, { recursive: true }); const imageFile = path.join(out, "alignment-grid.png"); fs.writeFileSync(imageFile, png());
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{}) });
  const page = await browser.newPage({ viewport: { width: 1450, height: 1050 } }), checks = [], errors = [], requests = [];
  page.on("pageerror", error => errors.push(error.message)); page.on("request", request => { if (/^https?:/.test(request.url())) requests.push(request.url()); });
  const control = name => page.locator(`[data-dpv="${name}"]`), svg = () => page.locator("#planview svg"), capture = () => page.evaluate(() => testView.capture());
  const geometry = () => page.locator(".dpv-geometry").evaluate(element => JSON.stringify(Array.from(element.querySelectorAll(".pf-wing,.pf-base,.dpv-spar,.dpv-rib")).map(shape => [shape.tagName, shape.getAttribute("points")])));
  // Browser SVGPoint matrices use float32; permit less than a thousandth of a pixel.
  const near = (a, b) => assert(Math.abs(a - b) < 1e-4 + 1e-6 * Math.abs(b), `${a} != ${b}`);
  const screenOrigins = () => page.evaluate(() => {
    const origin = selector => { const m = document.querySelector(selector).getScreenCTM(); return { x: m.e, y: m.f, scale: m.a }; };
    return { image: origin(".dpv-background-image"), geometry: origin(".dpv-geometry") };
  });
  async function drag(dx, dy, modifier = null, during = null, cancel = false, button = "right") {
    const bounds = await svg().boundingBox(), x = bounds.x + bounds.width / 2, y = bounds.y + bounds.height / 2;
    if (modifier) await page.keyboard.down(modifier);
    await page.mouse.move(x, y); await page.mouse.down({ button }); await page.mouse.move(x + dx, y + dy, { steps: 4 });
    if (during) await during(); if (cancel) await page.keyboard.press("Escape"); await page.mouse.up({ button });
    if (modifier) await page.keyboard.up(modifier);
  }
  async function wheel(delta, modifier = null) {
    const bounds = await svg().boundingBox();
    await svg().evaluate(element => element.addEventListener("wheel", event => { const p = element.createSVGPoint(); p.x = event.clientX; p.y = event.clientY; const q = p.matrixTransform(element.getScreenCTM().inverse()); window.lastAnchor = { x: q.x, y: q.y }; }, { once: true }));
    await page.mouse.move(bounds.x + bounds.width * .62, bounds.y + bounds.height * .47);
    const modifiers = Array.isArray(modifier) ? modifier : modifier ? [modifier] : [];
    for (const key of modifiers) await page.keyboard.down(key); await page.mouse.wheel(0, delta); for (const key of modifiers.slice().reverse()) await page.keyboard.up(key);
    await page.waitForTimeout(160); return page.evaluate(() => window.lastAnchor);
  }
  try {
    await page.setContent('<!doctype html><html><head><style>html,body{margin:0;height:100%;background:#101b26}#planview{height:100vh}</style></head><body><main id="planview"></main></body></html>');
    for (const file of ["planform_view.css", "dimensioned_plan_view.css", "svg_viewport.css"]) await page.addStyleTag({ path: path.join(web, file) });
    for (const file of ["numbers.js", "planform_view.js", "spar_view.js", "rib_layout.js", "leading_edge_gaps.js", "svg_viewport.js", "fuel_tank_view.js", "dimensioned_plan_view.js"]) await page.addScriptTag({ path: path.join(web, file) });
    await page.evaluate(schema => {
      window.testParams = { ...schema.values, "planform.area": 32, "planform.aspect_ratio": 8, "planform.dihedral": 0,
        "planform.leading_edge_points": [], "planform.trailing_edge_points": [], "box.end_eta": .75, "box.rib_pitch": .6,
        "box.front_spar_points": [], "box.rear_spar_points": [], "leading_edge.enabled": false };
      window.notifications = 0; window.testView = WingDimensionedPlanView.install(document.getElementById("planview"), { readValues: () => testParams,
        onChange: () => { notifications++; window.savedMetadata = JSON.stringify(testView.capture()); } });
      window.savedMetadata = JSON.stringify(testView.capture());
    }, schema);
    const originalParameters = await page.evaluate(() => JSON.stringify(testParams)), originalGeometry = await geometry();
    const arrows=await page.evaluate(()=>Array.from(document.querySelectorAll('.dpv-geometry marker[id$="-dim"]'),m=>({width:m.getAttribute('viewBox'),x:m.getAttribute('refX'),y:m.getAttribute('refY'),orientation:m.getAttribute('orient'),path:m.querySelector('path').getAttribute('d')})));
    assert(arrows.length>0);for(const arrow of arrows){assert.equal(arrow.width,'0 0 9 6');assert.equal(arrow.x,'9');assert.equal(arrow.y,'3');assert.equal(arrow.orientation,'auto-start-reverse');assert.equal(arrow.path,'M0 0 L9 3 L0 6 Z');}
    await control('theme').click();await page.screenshot({path:path.join(out,'dimension-arrows-white.png')});await control('theme').click();
    checks.push('Dimension arrowheads point toward the measured endpoint with their tip anchored exactly to the extension line');
    assert.equal((await capture()).mirror, false); assert.equal((await capture()).theme, "dark");
    assert(await page.locator(".dpv-image-status").isHidden()); assert(!await page.locator("body").innerText().then(t => t.includes("Optional: load an image")));
    const initialStage = await page.locator(".dpv-stage").boundingBox(); assert(initialStage.height > 930, `stage uses ${initialStage.height} of1050px`);
    assert(await page.locator(".dpv-image-settings").isHidden());
    checks.push("Half wing is the default, compact controls hide optional status and the drawing fills the remaining viewport");
    assert.equal(await control("edit").count(), 0); assert.equal(await page.locator(".dpv-gesture-guide").count(),0);assert(await page.locator(".dpv-help").isHidden());await control("help").click();assert.match(await page.locator(".dpv-help").innerText(), /Ctrl.*Cmd/s);await control("help").click();
    assert.equal(await page.locator("[data-rib]").count(), 11); assert.equal(await page.locator("[data-spar]").count(), 2);
    const blank = await capture(); await drag(24, 15); assert.notDeepEqual((await capture()).viewport, blank.viewport); assert.deepEqual((await capture()).transform, blank.transform);
    const noImage = await capture(); await drag(20, 10, "Control"); await wheel(-100, "Meta"); assert.deepEqual(await capture(), noImage);
    await control("fit-view").click(); assert.deepEqual((await capture()).viewport, { x: 0, y: 0, scale: 1 });
    checks.push("Normal navigation works without an image; modifier gestures require an image and no edit toggle remains");

    await control("file").setInputFiles(imageFile); await page.waitForFunction(() => testView.capture().image !== null);
    await control("image-tools").click();
    let saved = await capture(); assert.equal(saved.image.width, 256); assert.equal(saved.image.height, 128); assert(await control("scale").isEnabled());
    assert.equal(await geometry(), originalGeometry); assert.deepEqual(saved.viewport, { x: 0, y: 0, scale: 1 });
    checks.push("Actual image upload retains an independent registration inside the common viewport group");

    await control("theme").click(); assert.equal((await capture()).theme, "white");
    const themed = await page.evaluate(() => ({background:getComputedStyle(document.querySelector(".dpv-stage")).backgroundColor,
      wing:getComputedStyle(document.querySelector(".pf-wing")).stroke,text:getComputedStyle(document.querySelector(".pf-dim-label")).fill}));
    assert.equal(themed.background,"rgb(255, 255, 255)"); assert.equal(themed.wing,"rgb(23, 102, 134)"); assert.equal(themed.text,"rgb(36, 55, 72)");
    const downloadEvent = page.waitForEvent("download"); await control("export").click(); const download = await downloadEvent;
    assert.equal(download.suggestedFilename(),"wing-plan-view.svg"); const exportFile=path.join(out,"wing-plan-view.svg"); await download.saveAs(exportFile);
    const exportText=fs.readFileSync(exportFile,"utf8"); assert(exportText.includes("data:image/png;base64,")); assert(!/<link|<script|foreignObject/.test(exportText));
    const standalone=await browser.newPage({viewport:{width:1450,height:1050}}); await standalone.goto(require("node:url").pathToFileURL(exportFile).href);
    assert.equal(await standalone.locator("parsererror").count(),0); assert.equal(await standalone.locator("[data-rib]").count(),11);
    assert.equal(await standalone.locator(".pf-wing").evaluate(e=>getComputedStyle(e).stroke),themed.wing);
    assert.equal(await standalone.locator(".pf-dim-label").first().evaluate(e=>getComputedStyle(e).fill),themed.text);
    assert.equal(await standalone.locator(".dpv-background-image").count(),1); await standalone.screenshot({path:path.join(out,"export-white-standalone.png")}); await standalone.close();
    await page.screenshot({path:path.join(out,"plan-view-white.png")}); const whiteState=await capture(); await control("theme").click(); assert.equal((await capture()).theme,"dark");
    await page.evaluate(v=>testView.restore(v),whiteState); assert.equal((await capture()).theme,"white"); await control("theme").click();
    checks.push("White background stays readable, persists, and SVG download embeds the image and standalone appearance without external styles");

    const beforePan = await capture(), beforeOrigins = await screenOrigins(), metadata = await page.evaluate(() => savedMetadata), notices = await page.evaluate(() => notifications);
    await page.evaluate(() => { window.imageNode = document.querySelector(".dpv-background-image"); window.geometryNode = document.querySelector(".dpv-geometry").firstChild; });
    await drag(30, -16, null, async () => {
      assert.equal(await page.evaluate(() => imageNode === document.querySelector(".dpv-background-image") && geometryNode === document.querySelector(".dpv-geometry").firstChild), true);
      assert.equal(await page.evaluate(() => savedMetadata), metadata);
    }); const afterPan = await capture(), afterOrigins = await screenOrigins();
    assert.deepEqual(afterPan.transform, beforePan.transform); assert.notDeepEqual(afterPan.viewport, beforePan.viewport);
    near(afterOrigins.image.x - beforeOrigins.image.x, 30); near(afterOrigins.geometry.x - beforeOrigins.geometry.x, 30);
    near(afterOrigins.image.y - beforeOrigins.image.y, -16); near(afterOrigins.geometry.y - beforeOrigins.geometry.y, -16);
    assert.equal(await page.evaluate(() => notifications), notices + 1); assert.equal(await geometry(), originalGeometry);
    checks.push("Right drag pans image and drawing equally, reuses DOM nodes and saves once on release");

    saved = await capture(); const anchor = await wheel(-180), zoomed = await capture();
    assert(zoomed.viewport.scale > saved.viewport.scale); assert.deepEqual(zoomed.transform, saved.transform);
    near((anchor.x - zoomed.viewport.x) / zoomed.viewport.scale, (anchor.x - saved.viewport.x) / saved.viewport.scale);
    near((anchor.y - zoomed.viewport.y) / zoomed.viewport.scale, (anchor.y - saved.viewport.y) / saved.viewport.scale);
    assert.equal(await geometry(), originalGeometry);
    checks.push("Normal wheel zooms the common viewport under the pointer without changing image alignment");

    for (const modifier of ["Control", "Meta"]) {
      saved = await capture(); const before = await screenOrigins(); await drag(23, -11, modifier); const after = await capture(), screen = await screenOrigins();
      assert.deepEqual(after.viewport, saved.viewport); assert.notDeepEqual(after.transform, saved.transform);
      near(screen.image.x - before.image.x, 23); near(screen.image.y - before.image.y, -11); assert.deepEqual(screen.geometry, before.geometry);
      const matrix = await svg().evaluate(element => ({ x: element.getScreenCTM().a, y: element.getScreenCTM().d }));
      near(after.transform.x - saved.transform.x, 23 / matrix.x / saved.viewport.scale); near(after.transform.y - saved.transform.y, -11 / matrix.y / saved.viewport.scale);
    }
    checks.push("Ctrl and Cmd drag adjust only the image, correctly accounting for a zoomed common viewport");

    for (const modifier of ["Control", "Meta"]) {
      saved = await capture(); const wheelAnchor = await wheel(-100, modifier), after = await capture(); assert.deepEqual(after.viewport, saved.viewport); assert(after.transform.scale > saved.transform.scale);
      const point = { x: (wheelAnchor.x - saved.viewport.x) / saved.viewport.scale, y: (wheelAnchor.y - saved.viewport.y) / saved.viewport.scale };
      near((point.x - after.transform.x) / after.transform.scale, (point.x - saved.transform.x) / saved.transform.scale);
      near((point.y - after.transform.y) / after.transform.scale, (point.y - saved.transform.y) / saved.transform.scale);
    }
    checks.push("Ctrl and Cmd wheel zoom only the image and preserve its pixel under the pointer");

    for (const modifier of [null, "Control"]) { saved = await capture(); await drag(40, 15, modifier, null, true); assert.deepEqual(await capture(), saved); }
    saved = await capture(); await drag(12, 9, null, null, false, "middle"); assert.deepEqual(await capture(), saved);
    checks.push("Escape cancels either drag mode; middle-button dragging leaves the view unchanged");

    saved = await capture(); await svg().focus(); await svg().press("Shift+ArrowDown"); near((await capture()).viewport.y, saved.viewport.y + 10); assert.deepEqual((await capture()).transform, saved.transform);
    saved = await capture(); await svg().press("Control+ArrowRight"); assert.deepEqual((await capture()).viewport, saved.viewport); near((await capture()).transform.x, saved.transform.x + 1 / saved.viewport.scale);
    saved = await capture(); await control("scale").fill("150"); await control("scale").press("Tab"); near((await capture()).transform.scale, Math.min(700 / 256, 330 / 128) * 1.5); assert.deepEqual((await capture()).viewport, saved.viewport);
    await control("reset").click(); near((await capture()).transform.scale, Math.min(700 / 256, 330 / 128));
    const aligned = (await capture()).transform; await control("fit-view").click(); assert.deepEqual((await capture()).viewport, { x: 0, y: 0, scale: 1 }); assert.deepEqual((await capture()).transform, aligned);
    checks.push("Keyboard navigation, explicit image controls and Fit view operate on the intended independent transform");

    await drag(12, 8); await wheel(-80); await drag(15, -8, "Control"); saved = await capture();
    fs.writeFileSync(path.join(out, "saved-plan-view.json"), JSON.stringify(saved, null, 2));
    await page.evaluate(value => testView.restore(JSON.parse(JSON.stringify(value))), saved); assert.deepEqual(await capture(), saved);
    const legacy = { ...saved }; delete legacy.viewport; await page.evaluate(value => testView.restore(value), legacy);
    assert.deepEqual((await capture()).viewport, { x: 0, y: 0, scale: 1 }); assert.deepEqual((await capture()).transform, legacy.transform);
    await page.evaluate(value => testView.restore(value), saved); assert.deepEqual(await capture(), saved);
    checks.push("Both transforms persist independently, while older saved image states gain an identity viewport");

    for (const modifiers of [[], ["Control"], ["Meta"]]) {
      const before = await capture(), target = modifiers.length ? "transform" : "viewport", other = target === "viewport" ? "transform" : "viewport";
      await wheel(-140, modifiers); const standard = await capture(); await page.evaluate(value => testView.restore(value), before);
      await wheel(-140, [...modifiers, "Alt"]); const fine = await capture();
      near(Math.log(fine[target].scale / before[target].scale), Math.log(standard[target].scale / before[target].scale) / 10);
      assert.deepEqual(fine[other], before[other]);
      await page.evaluate(value => testView.restore(value), before);
    }
    checks.push("Alt reduces logarithmic wheel zoom by ten for common, Ctrl-image and Cmd-image modes");

    for (const modifier of ["", "Control+", "Meta+"]) {
      const before = await capture(), target = modifier ? "transform" : "viewport"; await svg().focus();
      await svg().press(modifier + "Equal"); const standard = await capture(); await page.evaluate(value => testView.restore(value), before); await svg().focus();
      await svg().press(modifier + "Alt+Equal"); const fine = await capture();
      near(Math.log(fine[target].scale / before[target].scale), Math.log(standard[target].scale / before[target].scale) / 10);
      await svg().press(modifier + "Alt+Minus"); near((await capture())[target].scale, before[target].scale);
      await page.evaluate(value => testView.restore(value), before);
    }
    const beforeButtons = await capture(); await control("larger").click(); const standardButton = await capture(); await page.evaluate(value => testView.restore(value), beforeButtons);
    await control("larger").click({ modifiers: ["Alt"] }); const fineButton = await capture();
    near(Math.log(fineButton.transform.scale / beforeButtons.transform.scale), Math.log(standardButton.transform.scale / beforeButtons.transform.scale) / 10);
    await control("smaller").click({ modifiers: ["Alt"] }); near((await capture()).transform.scale, beforeButtons.transform.scale);
    assert.deepEqual(fineButton.viewport, beforeButtons.viewport); await page.evaluate(value => testView.restore(value), beforeButtons);
    checks.push("Alt also refines keyboard +/- and image scale buttons without changing absolute numeric entry");

    const strokeSnapshot = () => page.evaluate(() => {
      const geometry = document.querySelector(".dpv-geometry"), matrix = geometry.getScreenCTM(), scale = Math.hypot(matrix.a, matrix.b);
      return {
        strokes: Array.from(geometry.querySelectorAll(".pf-wing,.pf-base,.pf-reference,.pf-dimension,.pf-extension,.pf-box-end,.dpv-spar,.dpv-rib,marker path,text")).map(element => ({ effect: getComputedStyle(element).vectorEffect, width: getComputedStyle(element).strokeWidth })),
        arrows: Array.from(geometry.querySelectorAll("marker")).map(element => ({ units: element.getAttribute("markerUnits"), width: Number(element.getAttribute("markerWidth")) * scale, height: Number(element.getAttribute("markerHeight")) * scale })),
        circles: Array.from(geometry.querySelectorAll("circle")).map(element => Number(element.getAttribute("r")) * scale),
        labels: Array.from(geometry.querySelectorAll("text")).map(element => { const rect = element.getBoundingClientRect(); return { width: rect.width, height: rect.height }; })
      };
    });
    const beforePresentation = await capture(); await page.evaluate(value => testView.restore({ ...value, viewport: { x: 0, y: 0, scale: 1 } }), beforePresentation);
    const baselinePresentation = await strokeSnapshot();
    for (const zoom of [.25, 4, 50]) {
      await page.evaluate(({ value, zoom }) => testView.restore({ ...value, viewport: { x: 500 - 500 * zoom, y: 300 - 300 * zoom, scale: zoom } }), { value: beforePresentation, zoom });
      const presentation = await strokeSnapshot(); assert.deepEqual(presentation.strokes, baselinePresentation.strokes); assert(presentation.strokes.every(stroke => stroke.effect === "non-scaling-stroke"));
      presentation.arrows.forEach((arrow,i) => { assert.equal(arrow.units, "userSpaceOnUse"); near(arrow.width, baselinePresentation.arrows[i].width); near(arrow.height, baselinePresentation.arrows[i].height); });
      presentation.circles.forEach((radius, i) => near(radius, baselinePresentation.circles[i]));
      presentation.labels.forEach((label, i) => { assert(Math.abs(label.width - baselinePresentation.labels[i].width) < .12); assert(Math.abs(label.height - baselinePresentation.labels[i].height) < .12); });
    }
    await page.evaluate(value => { const point = document.querySelector(".pf-origin"), x = Number(point.getAttribute("cx")), y = Number(point.getAttribute("cy")); testView.restore({ ...value, viewport: { x: 500 - 4 * x, y: 300 - 4 * y, scale: 4 } }); }, beforePresentation);
    await page.screenshot({ path: path.join(out, "plan-view-thin-strokes-400pct.png") });
    await page.evaluate(value => testView.restore(value), beforePresentation);
    checks.push("Strokes, arrowheads, origin markings and readable label sizes stay constant from25% to5000% zoom");

    await control("opacity").fill("0.35"); const placement = await capture(); await control("mirror").uncheck(); await control("showRibs").uncheck(); assert.equal(await page.locator("[data-rib]").count(), 0); await control("showRibs").check();
    await page.evaluate(() => { testParams["box.rib_pitch"] = 1.2; testView.refresh(); }); assert.equal(await page.locator("[data-rib]").count(), 6);
    assert.deepEqual((await capture()).transform, placement.transform); assert.deepEqual((await capture()).viewport, placement.viewport);
    assert.equal(await page.evaluate(() => { const p = { ...testParams, "box.rib_pitch": .6 }; return JSON.stringify(p); }), originalParameters);
    checks.push("Visibility, opacity and live rib updates preserve navigation and image registration without modifying model parameters");

    saved = await capture(); const bad = path.join(out, "invalid.png"); fs.writeFileSync(bad, "invalid image"); await control("file").setInputFiles(bad);
    await page.waitForFunction(() => document.querySelector(".dpv-error").textContent.includes("could not be decoded")); assert.deepEqual(await capture(), saved);
    await control("file").setInputFiles(imageFile); await page.waitForFunction(() => document.querySelector(".dpv-error").hidden); assert.deepEqual((await capture()).viewport, saved.viewport);
    await control("fit-view").click(); await control("help").click(); assert.match(await page.locator(".dpv-help").innerText(), /Ctrl.*Cmd/s); await control("help").click();
    await page.screenshot({ path: path.join(out, "plan-view-gestures.png") }); await page.setViewportSize({ width: 760, height: 980 }); assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    await page.screenshot({ path: path.join(out, "plan-view-gestures-narrow.png") });
    saved = await capture(); await control("remove").click(); assert.equal((await capture()).image, null); assert.deepEqual((await capture()).viewport, saved.viewport); await drag(10, 5); assert.notDeepEqual((await capture()).viewport, saved.viewport);
    checks.push("Invalid uploads preserve both transforms; help and narrow layout are clear, and navigation still works after image removal");

    await page.evaluate(()=>{testParams["ribs.masters"]=[{eta:.4,mode:"rear_spar_angle",angle:75,pitch:.4}];testParams["leading_edge.enabled"]=true;testParams["leading_edge.rib_orientations"]=[{rib:1,mode:"front_spar_angle",angle:150}];testView.refresh();});
    const oriented=await page.evaluate(()=>WingDimensionedPlanView.derive(testParams));assert(oriented.valid,oriented.error);assert(oriented.ribs.some(r=>Math.abs(r.front[1]-r.rear[1])>.001));assert.equal(await page.locator('.dpv-leading.dpv-fallback:not(.dpv-mirrored)').count(),1);
    await page.evaluate(()=>{const layout=WingRibLayout.leading(testParams);testParams._rib_geometry={ribs:layout.ribs.map(r=>({number:r.number,eta:r.eta,front_eta:r.frontEta,front:r.front,rear:r.rear,leading:r.leading,le_fallback:r.leFallback,le_status:r.leStatus,upper:[r.front,r.rear],lower:[r.front,r.rear]}))};testView.refresh();});assert(await page.locator("[data-upper-rib]").count()>0);assert(await page.locator("[data-lower-rib]").count()>0);await control("fit-view").click();await page.screenshot({path:path.join(out,"plan-view-oriented-ribs.png")});
    checks.push("Master-oriented box ribs and independent LE directions render separately; actual generated surface polylines and red fallback extensions are shown");

    await page.setViewportSize({width:1450,height:1050});await page.evaluate(()=>{testParams["planform.root_ref_x"]=125;testParams["planform.root_ref_y"]=-28;delete testParams._rib_geometry;testView.refresh();testView.restore({...testView.capture(),viewport:{x:0,y:0,scale:1}});});
    await page.locator('[data-svgv="snap-enabled"]').check();await page.locator('[data-svgv="measure"]').selectOption("distance");
    const measured=await page.evaluate(()=>{const shape=document.querySelector('.dpv-spar[data-spar="front"]'),m=shape.getScreenCTM(),points=[shape.points.getItem(0),shape.points.getItem(shape.points.numberOfItems-1)],data=WingDimensionedPlanView.derive(testParams),positions=data.spars.activeVertices[WingSparView.POINT_KEYS[0]].map(row=>row.position);return{screen:points.map(p=>({x:m.a*p.x+m.c*p.y+m.e,y:m.b*p.x+m.d*p.y+m.f})),physical:[positions[0],positions.at(-1)]};});
    for(const point of measured.screen)await page.mouse.click(point.x+2,point.y+2);assert.equal((await capture()).measurements.length,0);assert.match(await page.locator('[data-svgv="dimension-status"]').textContent(),/place label/);const midpoint={x:(measured.screen[0].x+measured.screen[1].x)/2,y:(measured.screen[0].y+measured.screen[1].y)/2+70};await page.mouse.move(midpoint.x,midpoint.y);assert.equal(await page.locator('.svgv-dimension-draft').count(),1);await page.mouse.click(midpoint.x,midpoint.y);
    const annotation=(await capture()).measurements[0];annotation.points.forEach((point,i)=>{near(point.x,measured.physical[i][1]);near(point.y,measured.physical[i][0]);});assert(annotation.label);const value=await page.locator('.svgv-dimension:not(.svgv-dimension-draft)').getAttribute('data-dimension-value');near(Number(value),Math.hypot(measured.physical[1][0]-measured.physical[0][0],measured.physical[1][1]-measured.physical[0][1]));
    const complete=await capture();await page.keyboard.press("Escape");await page.evaluate(value=>{testView.restore({});testView.restore(value);},complete);assert.deepEqual(await capture(),complete);const exportedDimension=await page.evaluate(()=>WingSVGViewport.serializeSVG(document.querySelector('#planview svg'),{theme:testView.capture().theme}));assert(exportedDimension.includes('svgv-dimension'));fs.writeFileSync(path.join(out,'detached-placed-dimension.svg'),exportedDimension);await page.screenshot({path:path.join(out,'detached-snapped-dimension.png')});checks.push("Detached plan view snaps actual spar vertices at translated root coordinates, places and persists its label independently, and exports the completed dimension");

    assert.deepEqual(errors, []); assert.deepEqual(requests, []);
    fs.writeFileSync(path.join(out, "summary.json"), JSON.stringify({ passed: true, checks, errors, requests }, null, 2));
    console.log(`Dimensioned plan view gestures Chrome passed ${checks.length} interaction groups.`);
  } catch (error) { fs.writeFileSync(path.join(out, "failure.json"), JSON.stringify({ error: error.stack, checks, errors, requests }, null, 2)); await page.screenshot({ path: path.join(out, "failure.png") }); throw error; }
  finally { await browser.close(); }
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
