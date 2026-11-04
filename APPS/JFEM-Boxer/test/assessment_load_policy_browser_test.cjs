'use strict';
// Actual Boxer UI over a small generated fixture. Synthetic signed membrane and
// bar recovery supplies exact factor-ratio oracles; no FE solver is started.
// Fixture: schema.json, params.json, payload.msgpack, legacy_normalized_params.json.
// node assessment_load_policy_browser_test.cjs OUT FIXTURE PLAYWRIGHT [BROWSER]
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const[outArg,fixtureArg,playwrightArg,browserArg]=process.argv.slice(2);
if(!outArg||!fixtureArg||!playwrightArg){console.error('Usage: node assessment_load_policy_browser_test.cjs OUT FIXTURE PLAYWRIGHT [BROWSER]');process.exit(2);}
const out=path.resolve(outArg),fixture=path.resolve(fixtureArg),web=path.resolve(__dirname,'../web');
const{chromium}=require(path.resolve(playwrightArg)),read=file=>JSON.parse(fs.readFileSync(path.join(fixture,file),'utf8'));
const schema=read('schema.json'),parameters=read('params.json'),legacy=read('legacy_normalized_params.json'),payload=fs.readFileSync(path.join(fixture,'payload.msgpack'));
schema.defaults=parameters;schema.values=parameters;
const near=(a,b,message)=>assert(Number.isFinite(a)&&Math.abs(a-b)<=1e-8*Math.max(Math.abs(b),1),`${message}: ${a} != ${b}`);
const strengthKey='assessment.strength_safety_factor',bucklingKey='assessment.buckling_policy_factor';
(async()=>{
 fs.mkdirSync(out,{recursive:true});const checks=[],errors=[],requests=[],observed={};
 const phase=name=>{console.log('Load policy browser: '+name);fs.writeFileSync(path.join(out,'progress.json'),JSON.stringify({phase:name,at:new Date().toISOString(),checks},null,2));};
 const browser=await chromium.launch({headless:true,...(browserArg?{executablePath:path.resolve(browserArg)}:{}),args:['--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1700,height:1120},acceptDownloads:true});page.setDefaultTimeout(60000);
 const debuggerSession=await page.context().newCDPSession(page);await debuggerSession.send('Debugger.enable');
 const origin='http://127.0.0.1:43994';let workerDelay=0;
 try{
  page.on('pageerror',error=>errors.push(error.stack||error.message));
  await page.route(origin+'/**',async route=>{
   const url=new URL(route.request().url()),body=route.request().method()==='POST'?route.request().postDataJSON():null;
   if(url.pathname.startsWith('/api/'))requests.push({path:url.pathname});
   if(url.pathname==='/api/input')return route.fulfill({json:schema});
   if(url.pathname==='/api/validate_workspace'){
    const p=body.parameters||body.params||body;
    if(!Object.hasOwn(p,strengthKey)&&!Object.hasOwn(p,bucklingKey))return route.fulfill({json:{ok:true,parameters:{...p,...legacy}}});
    if(![strengthKey,bucklingKey].every(key=>typeof p[key]==='number'&&Number.isFinite(p[key])&&p[key]>0))return route.fulfill({status:400,json:{error:'Assessment load policy factors must be finite and greater than zero.'}});
    return route.fulfill({json:{ok:true,parameters:p}});
   }
   if(['/api/generate','/api/prepare_workspace'].includes(url.pathname))return route.fulfill({body:payload,contentType:'application/msgpack'});
   if(url.pathname==='/api/activity')return route.fulfill({json:{ok:true,events:[]}});
   if(url.pathname==='/api/last_deck')return route.fulfill({json:{ok:true,available:false}});
   if(url.pathname==='/api/jfem_probe')return route.fulfill({json:{found:true}});
   if(url.pathname.startsWith('/api/'))return route.fulfill({status:404,json:{error:'Isolated load-policy UI fixture; no solver is available.'}});
   if(url.pathname==='/rf_compute_worker.js'&&workerDelay){const code=fs.readFileSync(path.join(web,'rf_compute_worker.js'),'utf8');return route.fulfill({contentType:'application/javascript',body:code+'\nconst originalPolicyTestReceiver=self.onmessage;self.onmessage=event=>setTimeout(()=>originalPolicyTestReceiver(event),'+workerDelay+');\n'});}
   const file=url.pathname.startsWith('/shared/')?path.join(web,'../..',url.pathname.slice('/shared/'.length)):path.join(web,url.pathname==='/'?'index.html':decodeURIComponent(url.pathname));
   return fs.existsSync(file)?route.fulfill({path:file}):route.fulfill({status:404,body:'Missing test asset'});
  });
  await page.goto(origin+'/');await page.locator('.startup-study-dialog [data-choice="new"]').click();
  await page.waitForFunction(()=>typeof state!=='undefined'&&state.autoMeshReady&&!state.workspaceBusy,null,{timeout:30000});
  if(!await page.evaluate(()=>!!state.data))await page.locator('#btn-create').click();
  await page.waitForFunction(()=>state.data&&!state.meshRequestInFlight,null,{timeout:30000});
  phase('generated fixture loaded');
  await page.evaluate(()=>{state.autoMeshEnabled=false;document.getElementById('auto-mesh').checked=false;cancelAutoMeshTimer();state.engine.stopRenderLoop();activateWorkspaceTab('analysis');});
  const strength=page.locator('[id="p-assessment.strength_safety_factor"]'),buckling=page.locator('[id="p-assessment.buckling_policy_factor"]');
  near(Number(await strength.inputValue()),1.5,'New strength safety default');near(Number(await buckling.inputValue()),1,'New buckling policy default');
  near(await page.evaluate(()=>collectParams()['loads.load_factor']),1,'New physical case multiplier');
  assert.match(await page.locator('#analysis-policy-options').innerText(),/LIMIT/);assert.match(await page.locator('#analysis-policy-options').innerText(),/ULTIMATE/);
  checks.push('New Analysis inputs default to strength safety 1.5 and buckling policy 1, with physical case multiplier 1 and explicit LIMIT/ULTIMATE explanations.');

  const target=await page.evaluate(()=>{
   state.values['output.solution']='101';document.getElementById('p-output.solution').value='101';
   const materials=WingMaterialAllowables.materialsFromGroups(state.data.groups).filter(m=>m.type==='MAT1');
   const rows=materials.map(m=>({material_id:m.id,mode:'stress',stress:300e6}));state.values['materials.allowables']=rows;document.getElementById('p-materials.allowables').value=JSON.stringify(rows);state.allowablesReadCache=null;
   const records={};for(const[eid,e]of state.elements){
    if(!['quad','tria','shell','bar','solid'].includes(e.group?.kind)||e.group.name==='aero')continue;
    const t=e.group.properties?.thickness_m||.0015,vm=Math.sqrt(180e6**2-180e6*30e6+30e6**2);
    records[eid]=e.group.kind==='bar'?{stress:{axial:-180e6,von_mises:180e6},stress_units:'Pa',forces:{axial:-180e6*(e.group.properties?.section?.area_m2||.0001),moment_a1:0,moment_a2:0,moment_b1:0,moment_b2:0,shear_1:0,shear_2:0,torque:0}}:
     {stress:{z1:{normal_x:-180e6,normal_y:-30e6,shear_xy:0,von_mises:vm,fiber_dist:-t/2},z2:{normal_x:-180e6,normal_y:-30e6,shear_xy:0,von_mises:vm,fiber_dist:t/2}},stress_units:'Pa',forces:{fx:-180e6*t,fy:-30e6*t,fxy:0,mx:0,my:0,mxy:0,qx:0,qy:0}};
   }
   state.modelSignature=formSignature();const cases=modelCases(),result=(id)=>({analysis:'SOL101',available:true,status:'complete',matches:true,modes:[],contours:[],summary:[],static:{disp:new Float32Array(state.nodeIds.length*3),maxDisp:0},signature:state.modelSignature,meshIdentity:state.meshIdentity,elementResults:records,caseLabel:'Synthetic LIMIT membrane case '+id});
   state.resultCases=new Map(cases.map(c=>[Number(c.id),result(c.id)]));state.activeCase=Number(cases[0].id);state.results=state.resultCases.get(state.activeCase);state.activeMode=-1;
   setModelDirty(false);markStudySaved();refreshMaterialAssessmentControls();
   globalThis.__policyOriginal={data:state.data,cases:state.resultCases,result:state.results,records:JSON.stringify(records),signature:state.modelSignature,meshIdentity:state.meshIdentity};
   const e=[...state.elements.values()].find(e=>e.group.kind==='bar'&&/^STRINGERS(?:_|$)/.test(e.group.name))||[...state.elements.values()].find(e=>e.group.kind==='quad');
   if(!e)throw Error('The generated fixture has no inspectable structural element.');return{eid:e.id,pid:Number(e.group.pid)};
  });
  observed.target=target;
  await page.evaluate(()=>activateWorkspaceTab('stressreport'));await page.waitForFunction(()=>state.stressReport?.report&&!state.stressReport.pending);
  assert.match(await page.locator('#stress-report-load-policy').innerText(),/1\.5/);
  await page.locator('#stress-report-edit-policy').click();assert.equal(await page.evaluate(()=>workspaceUI.activeTab),'analysis');
  assert.equal(await strength.evaluate(el=>document.activeElement===el),true);
  checks.push('Stress Report exposes the active load policy and its Edit button opens and focuses the canonical Analysis safety-factor input.');

  async function modeRows(mode){
   console.log('Load policy browser: assessment '+mode);
   await page.evaluate(()=>activateWorkspaceTab('stressreport'));await page.locator('#stress-report-failure-mode').selectOption(mode);
   await page.waitForFunction(m=>{const report=state.stressReport.report;return !state.stressReport.pending&&report?.failureMode===m&&JSON.stringify(report.assessmentPolicy)===JSON.stringify(readAssessmentPolicy());},mode,{timeout:15000});
   return page.evaluate(()=>({complete:state.stressReport.report.complete,policy:state.stressReport.report.assessmentPolicy,rows:state.stressReport.report.rows.map(row=>({key:row.rowKey||row.panelKey||String(row.pid),pid:row.pid,rf:row.reserveFactor,complete:row.complete,noDemand:row.noDemand||row.euler?.noCompression||row.blade?.noCompression||row.skinBuckling?.noDestabilizingLoad,stress:row.envelopeStress,assessmentStress:row.assessmentStress}))}));
  }
  const modes=['von_mises','euler_column','stringer_blade','skin_buckling','spar_web_buckling','rib_web_buckling','spar_cap_buckling','rib_stiffener_buckling','rib_stiffener_blade'];
  const baseline={};for(const mode of modes)baseline[mode]=await modeRows(mode);
  assert(baseline.von_mises.rows.some(row=>row.complete&&Number.isFinite(row.rf)),'The fixture must assess material strength.');
  for(const mode of modes.slice(1))assert(baseline[mode].rows.some(row=>row.complete&&!row.noDemand&&Number.isFinite(row.rf)),'The RF-rich fixture must assess positive demand for '+mode);
  const summary=value=>Object.fromEntries(Object.entries(value).map(([mode,report])=>[mode,{complete:report.complete,count:report.rows.length,assessed:report.rows.filter(row=>row.complete&&Number.isFinite(row.rf)).length,first:report.rows.find(row=>row.complete&&Number.isFinite(row.rf))}]));
  observed.baseline=summary(baseline);
  async function edit(input,value){await page.evaluate(()=>activateWorkspaceTab('analysis'));await input.fill(String(value));await input.blur();}
  workerDelay=150;await edit(strength,1.8);
  const strengthOnly={};for(const mode of modes){const next=strengthOnly[mode]=await modeRows(mode);const old=new Map(baseline[mode].rows.map(row=>[row.key,row]));for(const row of next.rows){const before=old.get(row.key);if(!row.complete||!before?.complete||!Number.isFinite(before.rf)||row.noDemand)continue;near(row.rf,before.rf*(mode==='von_mises'?1.5/1.8:1),'Changing safety affects only strength '+mode+' '+row.key);if(Number.isFinite(row.stress))near(row.stress,before.stress,'Recovered LIMIT stress remains unchanged');else assert.equal(row.stress,before.stress);}}
  workerDelay=0;checks.push('Changing safety 1.5 to 1.8 reduces every assessed strength RF by 1.5/1.8, while all assessed buckling RFs and physical LIMIT stresses remain unchanged; delayed genuine workers exercise superseded-request handling.');
  await edit(buckling,1.2);
  const both={};for(const mode of modes){const next=both[mode]=await modeRows(mode);const old=new Map(strengthOnly[mode].rows.map(row=>[row.key,row]));for(const row of next.rows){const before=old.get(row.key);if(!row.complete||!before?.complete||!Number.isFinite(before.rf)||row.noDemand)continue;near(row.rf,before.rf*(mode==='von_mises'?1:1/1.2),'Changing buckling policy affects only buckling '+mode+' '+row.key);}}
  observed.custom=summary(both);
  checks.push('Changing buckling policy 1 to 1.2 reduces each assessed plate, blade and column RF by 1/1.2, independently of strength safety.');
  const unchanged=await page.evaluate(()=>({data:state.data===__policyOriginal.data,cases:state.resultCases===__policyOriginal.cases,result:state.results===__policyOriginal.result,records:JSON.stringify(state.results.elementResults)===__policyOriginal.records,signature:formSignature()===__policyOriginal.signature&&state.modelSignature===__policyOriginal.signature,mesh:state.meshIdentity===__policyOriginal.meshIdentity,dirty:state.modelDirty,studyDirty:state.studyDirty,policy:readAssessmentPolicy()}));
  assert.deepEqual(unchanged,{data:true,cases:true,result:true,records:true,signature:true,mesh:true,dirty:false,studyDirty:true,policy:{strengthSafetyFactor:1.8,bucklingPolicyFactor:1.2}});
  checks.push('Factor-only edits preserve exact model, recovery arrays, result objects, mesh and FE signatures; only the Study becomes unsaved. No solve or remesh is requested.');

  await modeRows('von_mises');await page.locator('#stress-report-reserve').click();
  const targetRow=await page.evaluate(pid=>state.stressReport.report.rows.find(row=>row.pid===pid),target.pid);assert(targetRow?.complete);
  const materialRF=await page.evaluate(eid=>currentMaterialAssessment()?.details.get(eid)?.reserve_factor,target.eid);near(materialRF,targetRow.reserveFactor,'Generic material contour agrees with property strength RF for constant recovery');
  await page.locator('#stress-report-field-kind').selectOption('rf:von_mises');await page.locator('#stress-report-show-field').click();
  await page.waitForFunction(({eid,rf})=>Math.abs((state.rfField?.contour.byId.get(eid)??Infinity)-rf)<1e-8,{eid:target.eid,rf:targetRow.reserveFactor});
  assert(targetRow.reserveFactor<1&&targetRow.reserveFactor*1.8/1.5>1,'The target should cross RF 1 when the safety factor changes.');
  await page.locator('#stress-report-field-only-failing').check();await page.waitForFunction(eid=>state.rfVisibleElementIds?.has(eid),target.eid);
  await edit(strength,1.5);await modeRows('von_mises');await page.waitForFunction(eid=>state.rfField?.contour.available>0&&state.rfVisibleElementIds&&!state.rfVisibleElementIds.has(eid),target.eid);
  assert.equal(await page.locator('#stress-report-table tr[data-pid="'+target.pid+'"]').count(),0,'Passing property disappears from the failing-only table.');
  await edit(strength,1.8);await modeRows('von_mises');await page.waitForFunction(eid=>state.rfVisibleElementIds?.has(eid),target.eid);assert.equal(await page.locator('#stress-report-table tr[data-pid="'+target.pid+'"]').count(),1);
  checks.push('Policy-only edits move the target through RF 1; the failing-only property table and actual 3D visibility update without changing the FE solution.');
  for(const format of ['csv','markdown','html']){const waiting=page.waitForEvent('download');await page.locator('#stress-report-export-'+format).click();const download=await waiting,file=path.join(out,'policy-'+download.suggestedFilename());await download.saveAs(file);const text=fs.readFileSync(file,'utf8');assert.match(text,/LIMIT/);assert.match(text,/ULTIMATE/);assert.match(text,/1\.8/);}
  checks.push('Actual CSV, Markdown and HTML report downloads retain the current LIMIT/ULTIMATE basis and custom safety factor.');
  await page.evaluate(eid=>{activateWorkspaceTab('inspect');showElement(eid);},target.eid);await page.waitForFunction(()=>state.rfInspectionCache?.contour.available>0);
  assert.match(await page.locator('#inspect-rf-assessment').innerText(),/reserve|rf/i);
  checks.push('Generic material utilization, numerical 3D strength-RF field and Inspect remain consistent with the policy-factored Stress Report.');

  phase('native SOL105 renderer checks');const compact=await page.evaluate(()=>{
   globalThis.__policyBeforeModes=state.results;
   state.results={modeKind:'buckling',compactBuckling:true,bucklingRoots:[{mode:1,load_factor:3,static_subcase_id:1,buckling_subcase_id:2,peak_translation:{nodes:[{node_id:10,property_ids:[1]}]}},{mode:2,load_factor:1500,static_subcase_id:1,buckling_subcase_id:2}]};
   globalThis.__policyRawRoots=JSON.stringify(state.results.bucklingRoots);
   let host=document.getElementById('buckling-compact-results');if(!host){host=document.createElement('div');host.id='buckling-compact-results';document.getElementById('results-summary').after(host);}WingBucklingOutputs.render(host,state.results,{assessmentPolicy:readAssessmentPolicy()});
   return{headers:[...host.querySelectorAll('th')].map(el=>el.textContent),rows:[...host.querySelectorAll('tr')].slice(1).map(tr=>[...tr.querySelectorAll('td')].map(td=>td.textContent))};
  });
  assert(compact.headers.includes('Buckling-policy RF'));near(Number(compact.rows[0][1]),3,'Raw compact eigenvalue');near(Number(compact.rows[0][2]),2.5,'Compact policy RF');assert.equal(compact.rows[1][2],'999');
  await page.evaluate(()=>{const host=document.createElement('section');host.id='policy-native-widget-qa';host.style.cssText='position:fixed;left:20px;top:20px;width:850px;z-index:10000;background:#142838;color:#e8f3fa;padding:22px;border:1px solid #65849c';document.body.append(host);WingBucklingOutputs.render(host,state.results,{assessmentPolicy:readAssessmentPolicy()});});await page.locator('#policy-native-widget-qa').screenshot({path:path.join(out,'sol105-policy-widget.png'),timeout:10000});await page.evaluate(()=>document.getElementById('policy-native-widget-qa').remove());
  await edit(buckling,1.5);
  const changedCompact=await page.evaluate(()=>({raw:JSON.stringify(state.results.bucklingRoots)===__policyRawRoots,rows:[...document.querySelectorAll('#buckling-compact-results tr')].slice(1).map(tr=>[...tr.querySelectorAll('td')].map(td=>td.textContent))}));
  assert(changedCompact.raw);near(Number(changedCompact.rows[0][1]),3,'Raw compact eigenvalue after policy edit');near(Number(changedCompact.rows[0][2]),2,'Refreshed compact policy RF');
  await page.evaluate(()=>{state.results={modeKind:'buckling',compactBuckling:false,modes:[{mode:1,loadFactor:3},{mode:2,loadFactor:1500}]};globalThis.__policyRawModes=JSON.stringify(state.results.modes);WingBucklingOutputs.render(document.getElementById('buckling-compact-results'),state.results,{assessmentPolicy:readAssessmentPolicy()});});
  await edit(buckling,1.2);
  const full=await page.evaluate(()=>({raw:JSON.stringify(state.results.modes)===__policyRawModes,rows:[...document.querySelectorAll('#buckling-compact-results tr')].slice(1).map(tr=>[...tr.querySelectorAll('td')].map(td=>td.textContent))}));
  assert(full.raw);near(Number(full.rows[0][1]),3,'Raw full eigenvalue after policy edit');near(Number(full.rows[0][2]),2.5,'Full-mode policy RF');assert.equal(full.rows[1][2],'999');
  await page.evaluate(()=>{state.results=__policyBeforeModes;refreshMaterialAssessmentControls();});
  checks.push('Actual compact and full SOL105 renderers show separate policy RFs, update on a policy edit, cap displayed RF at 999 and leave every native root unchanged.');

  phase('imported policy visibility');await page.evaluate(()=>{state.importedDeck={name:'Synthetic policy-only import.bdf',signature:'synthetic-policy-visibility',solution:'101',source_format:'nastran',cases:state.data.load_cases,source:{kind:'reference',name:'Synthetic.bdf',text:'SOL 101\nCEND\nBEGIN BULK\nENDDATA\n',analysis:{solution:'source'}}};syncImportedModelMode();activateWorkspaceTab('analysis');});
  assert.equal(await page.locator('#form').evaluate(el=>el.hidden),true);assert(await strength.isVisible());assert(await buckling.isVisible());assert(!await strength.isDisabled());assert(!await buckling.isDisabled());
  await edit(strength,1.9);await edit(buckling,1.25);
  const importedPolicy=await page.evaluate(()=>({collected:[collectParams()['assessment.strength_safety_factor'],collectParams()['assessment.buckling_policy_factor']],saved:[state.values['assessment.strength_safety_factor'],state.values['assessment.buckling_policy_factor']]}));
  assert.deepEqual(importedPolicy,{collected:[1.9,1.25],saved:[1.9,1.25]});
  await page.evaluate(()=>{state.importedDeck=null;syncImportedModelMode();});await edit(strength,1.8);await edit(buckling,1.2);await modeRows('von_mises');
  checks.push('With a synthetic external-deck identity, generated forms hide but the shared Analysis policy stays visible and editable; both collected and saved imported-Study values update.');

  phase('bounded screenshots');await page.evaluate(()=>activateWorkspaceTab('analysis'));await strength.scrollIntoViewIfNeeded();await page.screenshot({path:path.join(out,'analysis-load-policy.png'),timeout:15000});
  await page.evaluate(()=>activateWorkspaceTab('stressreport'));await page.locator('#stress-report-load-policy').scrollIntoViewIfNeeded();await page.screenshot({path:path.join(out,'stress-report-load-policy.png'),timeout:15000});
  for(const value of ['0','-1','']){
   phase('invalid factor and inspection recovery '+JSON.stringify(value));
   await page.evaluate(()=>activateWorkspaceTab('analysis'));phase('invalid fill '+JSON.stringify(value));await strength.fill(String(value),{timeout:10000});phase('invalid blur '+JSON.stringify(value));await strength.blur({timeout:10000});phase('invalid collect '+JSON.stringify(value));const invalid=await page.evaluate(()=>{try{collectParams();return false;}catch{return true;}});assert(invalid,'Invalid safety factor must not be accepted: '+value);
   await page.evaluate(()=>activateWorkspaceTab('stressreport'));await page.waitForFunction(()=>!state.stressReport.pending&&!state.stressReport.report);assert.match(await page.locator('#stress-report-table').innerText(),/factor|policy|positive|greater than zero/i);
   await page.evaluate(eid=>{activateWorkspaceTab('inspect');showElement(eid);},target.eid);assert.match(await page.locator('#inspect-rf-assessment').innerText(),/unavailable|factor|policy|invalid/i);
   await edit(strength,1.8);await modeRows('von_mises');await page.evaluate(eid=>{activateWorkspaceTab('inspect');showElement(eid);},target.eid);await page.waitForFunction(()=>state.rfInspectionCache?.contour.available>0);assert.doesNotMatch(await page.locator('#inspect-rf-assessment').innerText(),/factor must|invalid policy|must be finite/i);
  }
  checks.push('Zero, negative and empty factors are rejected and withhold the current RF assessment instead of silently restoring a default or retaining current-looking RFs.');

  phase('save current policy');const saved=await page.evaluate(async()=>{
   window.policyWrites=[];window.showSaveFilePicker=async()=>({kind:'file',name:'LoadPolicy.wingfem.json',requestPermission:async()=> 'granted',createWritable:async()=>({write:async text=>policyWrites.push(text),close:async()=>{},abort:async()=>{}})});
   state.studyPreferNativeSave=false;const result=await saveModelDefinition({saveAs:true,noteText:'Assessment factors changed without changing physical LIMIT loads.'});if(!result)throw Error('Actual Study Save As failed');return JSON.parse(policyWrites.at(-1));
  });
  near(saved.parameters[strengthKey],1.8,'Saved strength safety');near(saved.parameters[bucklingKey],1.2,'Saved buckling policy');near(saved.parameters['loads.load_factor'],1,'Saved physical multiplier');
  phase('reload current policy');await page.evaluate(async saved=>{if(!await loadModelDefinition(new File([JSON.stringify(saved)],'LoadPolicy.wingfem.json',{type:'application/json'}),{recent:true}))throw Error('Actual policy Study reload failed');activateWorkspaceTab('analysis');},saved);
  await page.waitForFunction(()=>!state.workspaceBusy);near(Number(await strength.inputValue()),1.8,'Reloaded strength safety');near(Number(await buckling.inputValue()),1.2,'Reloaded buckling policy');
  assert.equal(await page.evaluate(()=>collectParams()['assessment.migration_note']),undefined);
  checks.push('Actual Study Save As and reload retain both policy factors independently of the physical load multiplier, without adding a legacy migration warning to a modern Study.');

  const old=structuredClone(saved);delete old.parameters[strengthKey];delete old.parameters[bucklingKey];delete old.parameters['assessment.migration_note'];old.parameters['loads.load_factor']=1.5;
  phase('load legacy policy');await page.evaluate(async saved=>{if(!await loadModelDefinition(new File([JSON.stringify(saved)],'LegacyPolicy.wingfem.json',{type:'application/json'}),{recent:true}))throw Error('Legacy Study reload failed');activateWorkspaceTab('analysis');},old);
  await page.waitForFunction(()=>!state.workspaceBusy);near(Number(await strength.inputValue()),1.5,'Legacy strength policy default');near(Number(await buckling.inputValue()),1,'Legacy buckling policy default');near(await page.evaluate(()=>collectParams()['loads.load_factor']),1.5,'Preserved explicit old case multiplier');
  assert.match(await page.locator('#sizing-load-policy-legacy').innerText(),/older|legacy|multiplier|already|ultimate/i);
  checks.push('An authentic backend-normalized legacy Study preserves its explicit 1.5 physical multiplier and displays the migration review warning; it is not silently divided or reclassified.');
  phase('save legacy policy warning');const legacySaved=await page.evaluate(async()=>{state.studyPreferNativeSave=false;if(!await saveModelDefinition({saveAs:true,noteText:'Preserve the legacy multiplier review note.'}))throw Error('Legacy Study Save As failed');return JSON.parse(policyWrites.at(-1));});
  assert.match(legacySaved.parameters['assessment.migration_note'],/older|legacy|multiplier|already|ultimate/i);
  phase('reload legacy policy warning');await page.evaluate(async saved=>{if(!await loadModelDefinition(new File([JSON.stringify(saved)],'LegacyPolicySaved.wingfem.json',{type:'application/json'}),{recent:true}))throw Error('Saved legacy Study reload failed');activateWorkspaceTab('analysis');},legacySaved);
  await page.waitForFunction(()=>!state.workspaceBusy);assert.match(await page.locator('#sizing-load-policy-legacy').innerText(),/older|legacy|multiplier|already|ultimate/i);
  checks.push('The legacy load-basis warning survives actual Save As and a second reload after the new factor fields have been added.');

  assert(!requests.some(request=>/jfem_run|sensitivity_run|vlm_run|aerodynamic_job/.test(request.path)),'Postprocessing policy edits must never launch a solver.');
  assert.equal(requests.filter(request=>request.path==='/api/rf_sections').length,0,'Factor edits need no new section geometry.');
  assert.deepEqual(errors,[]);
  phase('complete');fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({passed:true,checks,observed,unchanged,requests,errors,syntheticRecovery:true,actualGeneratedFixture:true,noSolverStarted:true},null,2));console.log(JSON.stringify({passed:true,checks},null,2));
 }catch(error){
  const debug=await Promise.race([page.evaluate(()=>({active:workspaceUI?.activeTab,dirty:state?.modelDirty,studyDirty:state?.studyDirty,policy:typeof readAssessmentPolicy==='function'?readAssessmentPolicy():null,pending:state.stressReport?.pending,selectedMode:document.getElementById('stress-report-failure-mode')?.value,status:document.getElementById('stress-report-status')?.textContent,report:state.stressReport?.report&&{mode:state.stressReport.report.failureMode,policy:state.stressReport.report.assessmentPolicy,note:state.stressReport.report.note,excluded:state.stressReport.report.excludedCases},log:document.getElementById('log')?.innerText})).catch(()=>null),new Promise(resolve=>setTimeout(()=>resolve({debugTimedOut:true}),3000))]);
  let pausedFrames=null;if(debug?.debugTimedOut){try{const pause=new Promise(resolve=>debuggerSession.once('Debugger.paused',event=>resolve(event.callFrames.map(frame=>({functionName:frame.functionName,url:frame.url,location:frame.location})))));await debuggerSession.send('Debugger.pause');pausedFrames=await Promise.race([pause,new Promise(resolve=>setTimeout(()=>resolve(null),3000))]);await debuggerSession.send('Debugger.resume');}catch{}}
  fs.writeFileSync(path.join(out,'failure.json'),JSON.stringify({error:error.stack,checks,observed,errors,requests,debug,pausedFrames},null,2));await page.screenshot({path:path.join(out,'failure.png'),timeout:5000}).catch(()=>{});throw error;
 }finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
