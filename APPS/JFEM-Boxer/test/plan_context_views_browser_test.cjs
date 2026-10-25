'use strict';
// node test/plan_context_views_browser_test.cjs EVIDENCE_DIR PLAYWRIGHT
// Real SVG editors, styles, gestures and detached-page messaging; the loft
// response is intentionally offset to distinguish 2D datum from 3D geometry.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {chromium}=require(process.argv[3]),out=path.resolve(process.argv[2]),web=path.resolve(__dirname,'../web');
const params={
 'planform.area':32,'planform.aspect_ratio':8,'planform.taper_ratio':.5,'planform.sweep':20,
 'planform.sweep_ref_xc':.25,'planform.root_ref_x':1,'planform.root_ref_y':2,'planform.root_ref_z':3,
 'planform.dihedral':0,'planform.twist_tip':16,'planform.twist_axis_xc':.25,
 'planform.leading_edge_points':[{eta:.4,dxc:-.12}],'planform.trailing_edge_points':[{eta:.6,dxc:.13}],
 'box.front_spar_xc':.2,'box.rear_spar_xc':.55,'box.front_spar_points':[],'box.rear_spar_points':[],
 'box.stringer_angle':0,'box.end_eta':.75,'box.rib_pitch':.6,'ribs.masters':[],
 'leading_edge.enabled':true,'leading_edge.start_rib':2,'leading_edge.end_rib':9,'leading_edge.disabled_bays':'3',
 'leading_edge.rib_orientation':'flight_direction','leading_edge.rib_angle':90,'leading_edge.rib_kink_side':'inboard',
 'fuel.enabled':true,'fuel.start_rib':2,'fuel.end_rib':8,'fuel.disabled_bays':'4',
 'movable_surfaces.items':[
  {name:'Flap & tab',kind:'flap',edge:'trailing',eta_start:.25,eta_end:.72,hinge_start:.78,hinge_end:.71,deflection:16,color:'#b388ff'},
  {name:'Slat',kind:'slat',edge:'leading',eta_start:.1,eta_end:.8,hinge_start:.12,hinge_end:.18,deflection:-12,color:'#29b6d1'}
 ]
};
(async()=>{
 fs.mkdirSync(out,{recursive:true});const errors=[],checks=[];
 const scripts=['numbers.js','planform_view.js','spar_view.js','rib_layout.js','leading_edge_gaps.js','svg_viewport.js','fuel_tank_view.js','dimensioned_plan_view.js','movable_surfaces.js'];
 const styles=['style.css','planform_view.css','spar_view.css','fuel_tank_view.css','dimensioned_plan_view.css','svg_viewport.css','movable_surfaces.css'];
 const server=http.createServer((req,res)=>{
  const name=new URL(req.url,'http://localhost').pathname.slice(1);
  if(name&&/^[\w.-]+\.(js|css|html)$/.test(name)&&fs.existsSync(path.join(web,name))){res.setHeader('Content-Type',(name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html')+'; charset=utf-8');return res.end(fs.readFileSync(path.join(web,name)));}
  res.setHeader('Content-Type','text/html; charset=utf-8');res.end('<!doctype html><html><head>'+styles.map(s=>'<link rel="stylesheet" href="/'+s+'">').join('')+'<style>body{display:block;overflow:auto;padding:20px;background:#13202b;color:#dcebf6}section{width:1000px;max-width:100%;margin-bottom:30px}h2{font-size:20px}[hidden]{display:none!important}</style></head><body><section id="fuel"></section><section id="movable"><input type="hidden" id="p-movable_surfaces.items"></section><section id="dimensioned"></section>'+scripts.map(s=>'<script src="/'+s+'"></script>').join('')+'</body></html>');
 });await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch({channel:'chrome',headless:true}),page=await browser.newPage({viewport:{width:1400,height:1100},acceptDownloads:true});page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto('http://127.0.0.1:'+server.address().port);
  await page.evaluate(initial=>{
   window.params=structuredClone(initial);window.previewCalls=0;window.preview3D=null;
   document.getElementById('p-movable_surfaces.items').value=JSON.stringify(params['movable_surfaces.items']);
   window.fuel=WingFuelTankView.install(document.getElementById('fuel'),{readValues:()=>params});
   window.dimensioned=WingDimensionedPlanView.install(document.getElementById('dimensioned'),{readValues:()=>params});
   window.movable=WingMovableSurfaces.install(document.getElementById('movable'),{readValues:()=>params,onPreview:d=>preview3D=d,requestPreview:async values=>{
    previewCalls++;const c=WingSparView.contextGeometry(values);return{outline:c.planform.right.map(p=>[p[0]+100,p[1],p[2]]),surfaces:c.movables.map(s=>({definition:s,outline:s.outline.map(p=>[p[0]+100,p[1],p[2]]),hinge_curve:s.hinge.map(p=>[p[0]+100,p[1],p[2]])}))};
   }});
  },params);
  await page.waitForFunction(()=>document.getElementById('movable-status').textContent.startsWith('2 movable'));
  for(const id of ['fuel','dimensioned'])assert.equal(await page.locator('#'+id+' .plan-context-movable').count(),2);
  assert.equal(await page.locator('#movable .plan-context-movable').count(),0); // Main footprints already own these shapes.
  assert.equal(await page.locator('#movable [data-movable-footprint]').count(),2);
  assert.equal(await page.locator('#movable .plan-context .sf-spar').count(),2);
  assert(await page.locator('#movable .plan-context-rib').count()>5);
  assert(await page.locator('#movable .plan-context-leading').count()>5);
  assert(await page.locator('#fuel .plan-context-leading').count()>5);
  assert.equal(await page.locator('#fuel .plan-context-rib').count(),0);
  assert.equal(await page.locator('#fuel .plan-context .sf-spar').count(),0);
  assert.equal(await page.locator('#fuel .ftv-spar').count(),2);
  assert.equal(await page.locator('#dimensioned .plan-context-leading').count(),0);
  assert.equal(await page.locator('#dimensioned .plan-context-rib').count(),0);
  assert.equal(await page.locator('#dimensioned .dpv-spar').count(),2);
  assert.equal(await page.locator('#movable .plan-context').evaluate(e=>getComputedStyle(e).pointerEvents),'none');
  assert.equal(await page.locator('#dimensioned .plan-context-movable title').first().textContent(),'Flap & tab: neutral movable-surface footprint');
  checks.push('Fuel, movable and dimensioned views share spars, ribs, active leading edge and neutral control footprints without duplicate primary geometry');
  const neutral=await page.evaluate(()=>{
   const c=WingSparView.contextGeometry(params),p=c.planform.right,xmin=Math.min(...p.map(p=>p[1])),ymin=Math.min(...p.map(p=>p[0])),scale=Math.min(800/(Math.max(...p.map(p=>p[1]))-xmin),325/(Math.max(...p.map(p=>p[0]))-ymin)),map=p=>[50+(p[1]-xmin)*scale,45+(p[0]-ymin)*scale];
   return{actual:document.querySelector('#movable [data-movable-footprint]').getAttribute('points'),expected:c.movables[0].outline.map(p=>map(p).join(',')).join(' '),backendX:preview3D.outline[0][0],planX:c.planform.right[0][0]};
  });assert.equal(neutral.actual,neutral.expected);assert.equal(neutral.backendX-neutral.planX,100);
  checks.push('Movable 2D plan uses the same untwisted datum as structural editors; 3D loft data is retained separately');
  await page.locator('#dimensioned [data-dpv=showSpars]').uncheck();await page.locator('#dimensioned [data-dpv=showRibs]').uncheck();
  assert.equal(await page.locator('#dimensioned .dpv-spar,#dimensioned .sf-spar,#dimensioned .dpv-rib,#dimensioned .plan-context-rib').count(),0);
  assert.equal(await page.locator('#dimensioned .plan-context-movable').count(),2);
  await page.locator('#dimensioned [data-dpv=mirror]').check();
  assert.equal(await page.locator('#dimensioned .plan-context-movable').count(),4);
  const mirrored=await page.evaluate(()=>{
   const d=WingDimensionedPlanView.derive(params),map=WingDimensionedPlanView.projection(d.planform,true).map,mirror=p=>[p[0],2*d.planform.points.rootReference[1]-p[1],p[2]];
   return{actual:document.querySelector('#dimensioned [data-mirror-context] polygon').getAttribute('points'),expected:d.planContext.movables[0].outline.map(p=>map(mirror(p)).join(',')).join(' ')};
  });assert.equal(mirrored.actual,mirrored.expected);
  await page.locator('#dimensioned [data-dpv=filledFigures]').uncheck();assert.equal(await page.locator('#dimensioned .plan-context-movable polygon').first().evaluate(e=>getComputedStyle(e).fill),'none');
  checks.push('Layer toggles, outline-only drawing and mirrored footprints retain the translated root reference exactly');
  const downloadPromise=page.waitForEvent('download');await page.locator('#dimensioned [data-dpv=export]').click();const download=await downloadPromise;
  const svgFile=path.join(out,'dimensioned-context.svg');await download.saveAs(svgFile);const exported=fs.readFileSync(svgFile,'utf8');assert.match(exported,/plan-context-movable/);assert.match(exported,/Flap &amp; tab/);assert(!exported.includes('NaN'));
  checks.push('Standalone dimensioned SVG export includes styled neutral footprints and preserves annotation/layer options');
  await page.locator('#movable svg').scrollIntoViewIfNeeded();
  const gesture=await page.locator('#movable .sf-front').evaluate(e=>{const m=e.getScreenCTM(),a=e.points[0],p=new DOMPoint(a.x,a.y).matrixTransform(m);return{x:p.x,y:p.y};});
  const beforeZoom=await page.evaluate(()=>document.getElementById('movable-plan-view').wingViewport.capture().viewport.scale);
  await page.mouse.move(gesture.x+15,gesture.y+10);await page.mouse.down();await page.mouse.move(gesture.x+180,gesture.y+70,{steps:8});await page.mouse.up();
  assert(await page.evaluate(before=>document.getElementById('movable-plan-view').wingViewport.capture().viewport.scale>before,beforeZoom));
  await page.evaluate(()=>document.getElementById('movable-plan-view').wingViewport.fit());
  checks.push('Context strokes do not intercept left-drag window zoom or alter the view controls');
  const popupPromise=page.waitForEvent('popup');
  await page.evaluate(()=>{
   window.addEventListener('message',e=>{if(e.origin===location.origin&&e.data?.channel==='WingFEGen.plan-view.v1'&&e.data.type==='ready')e.source.postMessage({channel:e.data.channel,token:e.data.token,type:'initialize',revision:1,values:params,saved:WingDimensionedPlanView.validateState(),sharedReference:null},location.origin);});
   window.detached=window.open('/plan_view.html#context-regression','plan-context-regression');
  });const popup=await popupPromise;popup.on('pageerror',e=>errors.push(e.message));
  await popup.waitForSelector('.plan-context-movable');assert.equal(await popup.locator('.plan-context-movable').count(),2);
  assert.notEqual(await popup.locator('.plan-context-movable polygon').first().evaluate(e=>getComputedStyle(e).stroke),'none');
  await popup.screenshot({path:path.join(out,'detached-context.png'),fullPage:true});
  checks.push('The real detached plan page loads context styles and draws live control footprints through its normal opener protocol');
  const oldPoints=await page.locator('#fuel .plan-context-movable polygon').first().getAttribute('points');
  await page.evaluate(()=>{
   params={...params,'planform.leading_edge_points':[{eta:.4,dxc:-.2}],'movable_surfaces.items':params['movable_surfaces.items'].slice(0,1),'leading_edge.disabled_bays':'3-5'};
   fuel.refresh();dimensioned.refresh();
   document.querySelectorAll('.movable-surface')[1].querySelector('button.ghost').click();
   detached.postMessage({channel:'WingFEGen.plan-view.v1',token:'context-regression',type:'values',values:params},location.origin);
  });
  await page.waitForFunction(()=>document.getElementById('movable-status').textContent.startsWith('1 movable'));
  await popup.waitForFunction(()=>document.querySelectorAll('.plan-context-movable').length===1);
  assert.equal(await page.locator('#fuel .plan-context-movable').count(),1);assert.equal(await page.locator('#movable [data-movable-footprint]').count(),1);
  assert.notEqual(await page.locator('#fuel .plan-context-movable polygon').first().getAttribute('points'),oldPoints);
  checks.push('Geometry edits, leading-edge gaps and surface removal refresh every view and detached drawing without stale footprints');
  const requestCount=await page.evaluate(()=>previewCalls);await page.locator('#movable .movable-surface button.ghost').click();
  await page.waitForFunction(()=>document.getElementById('movable-status').textContent.startsWith('No movable'));
  assert.equal(await page.locator('#movable [data-movable-footprint]').count(),0);assert.equal(await page.locator('#movable .plan-context .sf-spar').count(),2);assert.equal(await page.evaluate(()=>previewCalls),requestCount);
  checks.push('An empty movable-surface form retains useful structural context without requesting an unnecessary loft preview');
  await page.locator('#fuel').screenshot({path:path.join(out,'fuel-context.png')});await page.locator('#movable').screenshot({path:path.join(out,'movable-context.png')});
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'plan_context_views.json'),JSON.stringify({passed:true,checks,errors},null,2));console.log(JSON.stringify({passed:true,checks}));await popup.close();
 }catch(error){await page.screenshot({path:path.join(out,'plan-context-failure.png'),fullPage:true});throw error;}finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
