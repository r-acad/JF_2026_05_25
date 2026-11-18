'use strict';
const assert=require('node:assert/strict'),path=require('node:path');
const {chromium}=require(process.env.WINGFEGEN_PLAYWRIGHT_MODULE||'playwright');
const web=path.join(__dirname,'../web');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
 const page=await browser.newPage();const errors=[],checks=[];page.on('pageerror',error=>errors.push(error.message));
 try{
  await page.setContent('<!doctype html><title>Boxer app control</title><body><section id="form"></section><select id="inspect-entity"><option value="all">All</option><option value="nodes">GRID</option></select><p id="mesh-status">Model current</p><div id="model-error" hidden><p id="model-error-text"></p></div><button id="btn-load-model">Load Study</button><button id="btn-read-reference">Read Nastran</button><button id="btn-read-abaqus">Read Abaqus</button></body>');
  for(const name of ['boxer_commands.js','minimum_gauge_inputs.js','boxer_app_control.js'])await page.addScriptTag({path:path.join(web,name)});
  await page.evaluate(()=>{
   window.calls={edited:[],build:0,read:0,post:[],rf:0,imports:[],loaded:[]};window.rejectBuild=false;window.hold=false;
   const values={'planform.area':27.5,'properties.t_skin_upper':.0015,'loads.cases':[{id:1,label:'Positive',enabled:true},{id:2,label:'Negative',enabled:true}],
    'materials.shells':[],'properties.panels':[{key:'upper:bay1:stringer1:segment1',skin:{thickness:.0016}},{key:'upper:bay1:stringer2:segment1',skin:{thickness:.004}}],
    'properties.ribs':[],'properties.spar_bays':[],'properties.components':[]};
   window.state={autoMeshReady:true,studyEpoch:4,studyRevision:9,studyViewRevision:2,studyDirty:false,modelDirty:false,values:structuredClone(values),loadCases:structuredClone(values['loads.cases']),editingCase:1,
    camera:{alpha:.7},data:{nodes:{count:12},groups:[{name:'Skin'}]},results:{modes:['static']},resultCases:new Map([[1,{label:'Positive',available:true}],[2,{label:'Negative',available:true}]]),
    nodeIds:new Int32Array([11,22,33]),elements:new Map([[100,{group:{name:'Skin',kind:'quad',pid:1},nodes:[0,1,2]}]]),
    parameterLocks:{isLocked:key=>window.locked===key}};
   window.original={data:state.data,results:state.results,camera:state.camera};
   window.schema=Object.keys(values).map(key=>({key,label:key,kind:key==='planform.area'||key==='properties.t_skin_upper'?'float':'table'}));
   window.build=(schema,values)=>{
    calls.build++;const host=document.getElementById('form');host.replaceChildren();
    for(const spec of schema){const input=document.createElement('input');input.id='p-'+spec.key;
     if(spec.kind==='float'){input.type='number';input.dataset.parameterUnitKey=spec.key;if(spec.key==='properties.t_skin_upper')input.dataset.parameterDisplayUnit='mm';input.value=String(values[spec.key]*(spec.key==='properties.t_skin_upper'?1000:1));}
     else{input.type='hidden';input.value=JSON.stringify(values[spec.key]);}host.append(input);
    }
    state.loadCases=structuredClone(values['loads.cases']);
    if(window.rejectBuild&&values['planform.area']===13.37)throw Error('Fixture incompatible local form');
   };
   window.read=()=>{calls.read++;const result=structuredClone(state.values);for(const spec of schema){const input=document.getElementById('p-'+spec.key);result[spec.key]=spec.kind==='float'?Number(input.value)/(spec.key==='properties.t_skin_upper'?1000:1):JSON.parse(input.value);}return result;};
   window.fetcher=async(url,init)=>{
    const body=JSON.parse(init.body);calls.post.push({url,body});
    if(url==='/api/chat/open_study')return{ok:true,json:async()=>({ok:true,handle:{name:'Fixture.wingfem.json',path:body.path,token:'test-only'}})};
    if(hold)await new Promise(resolve=>{window.release=resolve;});
    const candidate={...body.parameters,...body.values};
    if(candidate['planform.area']<=0)return{ok:false,json:async()=>({ok:false,error:'Area must be positive'})};
    for(const row of candidate['properties.panels'])if(row.key.startsWith('upper:')&&row.skin.thickness<candidate['properties.t_skin_upper'])throw Error('Minimum reconciliation was not performed before validation');
    return{ok:true,json:async()=>({ok:true,values:structuredClone(body.values),warnings:[]})};
   };
   build(schema,state.values);
   window.controller=WingBoxerAppControl.create({state,document,connect:false,fetch:fetcher,getSchema:()=>schema,readParameters:read,buildForm:build,
    parameterEdited:key=>{calls.edited.push(key);state.studyDirty=true;state.modelDirty=true;state.studyRevision++;},hasDrafts:()=>false,
    navigate:tab=>{window.tab=tab;return tab!=='missing';},getWorkspace:()=>({active_tab:window.tab||'weights',title:window.tab==='log'?'Log':'Mass properties'}),fitView:()=>{window.fit=true;},newStudy:args=>{window.newArgs=args;return true;},requestStudySave:()=>true,
    confirmReplacement:()=>Promise.resolve(window.replaceChoice??'discard'),nativeFile:handle=>Promise.resolve(new File(['{}'],handle.name)),
    loadModelDefinition:(file,options)=>{calls.loaded.push({name:file.name,handle:options.handle});return true;},
    loadReferenceSource:args=>{calls.imports.push(args);return true;},createFEM:()=>{calls.fem=(calls.fem||0)+1;return true;},runJfem:()=>true,stopJfem:()=>true,
    installAerodynamicStudy:()=>{},showElement:(id,options)=>{state.selectedElement=id;calls.inspect={id,options};},showNode:index=>{state.selectedNode=index;},inspectFilterChanged:()=>{}});
  });
  const result=await page.evaluate(()=>controller.execute({command:'update_parameters',arguments:{values:{'properties.t_skin_upper':.003}}}));
  assert.equal(result.atomic,true);assert.equal(result.minimum_gauge_changes,1);
  const after=await page.evaluate(()=>({values:read(),same:{data:state.data===original.data,results:state.results===original.results,camera:state.camera===original.camera},post:calls.post[0]}));
  assert.equal(after.values['planform.area'],27.5);assert.equal(after.values['loads.cases'].length,2);assert.equal(after.values['properties.t_skin_upper'],.003);
  assert.equal(after.values['properties.panels'][0].skin.thickness,.003);assert.equal(after.values['properties.panels'][1].skin.thickness,.004);
  assert.deepEqual(after.same,{data:true,results:true,camera:true});assert.equal(after.post.body.values['properties.panels'][0].skin.thickness,.003);
  assert.equal(await page.locator('[id="p-properties.t_skin_upper"]').inputValue(),'3');
  checks.push('One canonical gauge edit preserves nondefault geometry/cases and non-null FEM/results/camera identity, reconciles smaller local overrides before validation and preserves larger ones.');

  const before=await page.evaluate(()=>read());
  const rejected=await page.evaluate(async()=>{try{await controller.updateParameters({'planform.area':-1,'properties.t_skin_upper':.005});return '';}catch(error){return error.message;}});
  assert.match(rejected,/positive/);assert.deepEqual(await page.evaluate(()=>read()),before);
  await page.evaluate(()=>{window.rejectBuild=true;});
  const rolled=await page.evaluate(async()=>{try{await controller.updateParameters({'planform.area':13.37});return '';}catch(error){return error.message;}});
  assert.match(rolled,/previous Study was restored/);assert.deepEqual(await page.evaluate(()=>read()),before);
  await page.evaluate(()=>{window.rejectBuild=false;window.locked='planform.area';});
  assert.match(await page.evaluate(async()=>{try{await controller.updateParameters({'planform.area':15});return '';}catch(error){return error.message;}}),/locked/);
  await page.evaluate(()=>{window.locked=null;});
  checks.push('Server validation, local form reconstruction and parameter locks all protect the previous Study atomically.');

  await page.evaluate(()=>{window.hold=true;window.pending=controller.updateParameters({'planform.area':22}).then(()=>'',error=>error.message);});
  await page.waitForFunction(()=>typeof window.release==='function');
  await page.evaluate(()=>{document.getElementById('p-planform.area').value='31';state.studyRevision++;window.hold=false;release();});
  assert.match(await page.evaluate(()=>pending),/Study changed during validation/);assert.equal((await page.evaluate(()=>read()))['planform.area'],31);
  assert.equal(await page.evaluate(()=>!!state.assistantParameterBusy),false);
  checks.push('A user edit made while Julia validates an assistant patch wins; the stale patch is discarded and the busy flag clears.');

  await page.evaluate(()=>{
   const rows=Array.from({length:10000},(_,index)=>({pid:index+1,label:'P'+(index+1),names:['Skin'],reserveFactor:index%3?.8:2,complete:true,status:'complete',combined:{governingModeLabel:'Skin buckling',governingCase:'Negative'}}));
   const iterator=rows[Symbol.iterator].bind(rows);window.rfWalks=0;rows[Symbol.iterator]=()=>{window.rfWalks++;return iterator();};
   state.stressReport={report:{failureMode:'minimum_rf',rows,estimated:false,source:{studyEpoch:4,capturedAt:'test',meshIdentity:'mesh'}},get pending(){return false;}};
  });
  const cached=await page.evaluate(()=>{controller.snapshot();controller.snapshot();const before=calls.read;const rf=controller.readReserveFactors({only_below_one:true,limit:3});controller.snapshot();return{rf,walks:rfWalks,reads:calls.read-before};});
  assert.equal(cached.walks,1);assert.equal(cached.reads,0);assert.equal(cached.rf.rows.length,3);assert(cached.rf.rows.every(row=>row.reserve_factor<1));
  assert.equal(cached.rf.summary.estimated,true);assert.equal(cached.rf.summary.stale,true);assert.equal(cached.rf.summary.source_basis,'retained_previous_analysis');
  await page.evaluate(()=>{state.stressReport.report.estimated=true;});
  assert.equal((await page.evaluate(()=>controller.snapshot())).reserve_factors.assessed_at_edited_properties,true);
  checks.push('Ten thousand cached RF rows are summarized once; snapshots perform no parameter collection or RF work and identify retained versus fixed-load estimated data.');

  await page.evaluate(()=>{
   const host=document.createElement('main');host.id='workspace-content';host.innerHTML='<section data-workspace-panel="weights"><h2>Mass properties</h2><p>Total mass 456 kg</p><span hidden>hidden-secret</span><span style="display:none">css-secret</span><span data-boxer-private="settings">private-token</span><details><summary>More</summary>closed-detail</details><table><thead><tr><th>Component</th><th>Mass (kg)</th></tr></thead><tbody><tr><td>Skin</td><td>100</td></tr><tr><td>Stringers</td><td>200</td></tr></tbody></table></section><section data-workspace-panel="log" hidden><h2>Log</h2><p>Factorization completed</p></section>';
   document.body.append(host);window.tab='weights';
  });
  const panel=await page.evaluate(async()=>{const before={read:calls.read,rf:calls.rf,fem:calls.fem||0};const result=await controller.execute({command:'invoke_action',arguments:{id:'read_panel',arguments:{offset:1,limit:1}}});return{result,before,after:{read:calls.read,rf:calls.rf,fem:calls.fem||0},revision:controller.snapshot().study.revision};});
  assert.equal(panel.result.title,'Mass properties');assert.match(panel.result.text,/Total mass 456 kg/);assert.doesNotMatch(panel.result.text,/hidden-secret|css-secret|private-token|closed-detail|Factorization/);
  assert.deepEqual(panel.result.tables[0].headers,['Component','Mass (kg)']);assert.deepEqual(panel.result.tables[0].rows,[['Stringers','200']]);assert.equal(panel.result.results_out_of_sync,true);assert.equal(panel.result.recalculated,false);assert.equal(typeof panel.revision,'number');assert.deepEqual(panel.before,panel.after);
  const logPanel=await page.evaluate(()=>{window.tab='log';document.querySelector('[data-workspace-panel="weights"]').hidden=true;document.querySelector('[data-workspace-panel="log"]').hidden=false;return controller.readPanel();});
  assert.match(logPanel.text,/Factorization completed/);assert.doesNotMatch(logPanel.text,/456 kg/);assert.equal(logPanel.tables.length,0);
  checks.push('Read current view returns bounded visible mass/log text and paged tables, omits hidden/private content, marks stale results and starts no FEM, parameter collection or RF work.');

  await page.evaluate(()=>controller.execute({command:'invoke_action',arguments:{id:'inspect_element',arguments:{id:100}}}));
  assert.deepEqual(await page.evaluate(()=>calls.inspect),{id:100,options:{assess:false}});
  await page.evaluate(()=>controller.execute({command:'invoke_action',arguments:{id:'inspect_node',arguments:{id:22}}}));
  assert.equal(await page.evaluate(()=>state.selectedNode),1);
  const property=await page.evaluate(()=>controller.execute({command:'inspect',arguments:{property_id:1}}));
  assert.equal(property.member_count,1);assert.equal(property.selected.element_id,100);assert.equal(property.rf_calculation_started,false);
  await page.evaluate(()=>controller.execute({command:'inspect',arguments:{node_id:33}}));assert.equal(await page.evaluate(()=>state.selectedNode),2);
  await page.evaluate(()=>controller.execute({command:'inspect',arguments:{element_id:100}}));assert.equal(await page.evaluate(()=>state.selectedElement),100);
  assert.match(await page.evaluate(async()=>{try{await controller.execute({command:'inspect',arguments:{property_id:888}});return '';}catch(error){return error.message;}}),/no elements/);
  const imported=await page.evaluate(()=>controller.execute({command:'invoke_action',arguments:{id:'read_nastran',arguments:{path:'C:/models/airframe.bdf'}}}));
  assert.equal(imported.status,'waiting_for_user');
  await page.waitForFunction(()=>calls.imports.length===1);
  assert.deepEqual(await page.evaluate(()=>calls.imports[0]),{path:'C:/models/airframe.bdf',format:'reference'});
  const opened=await page.evaluate(()=>controller.execute({command:'invoke_action',arguments:{id:'open_study',arguments:{path:'C:/studies/wing.json'}}}));
  assert.equal(opened.status,'waiting_for_user');await page.waitForFunction(()=>calls.loaded.length===1);
  assert.equal(await page.evaluate(()=>calls.loaded[0].handle.path),'C:/studies/wing.json');
  checks.push('Curated nested arguments inspect exact model IDs without RF computation and reuse native deck/Study workflows with unsaved-change protection.');
  await page.evaluate(()=>{state.importedDeck={name:'Airframe.dat',source:{name:'Airframe.dat'}};});
  const importedState=await page.evaluate(()=>controller.snapshot());assert.equal(importedState.mode,'imported_deck');assert.equal(importedState.study.title,'Airframe.dat');assert.deepEqual(importedState.parameters,{});
  assert.equal((await page.evaluate(()=>controller.commands.listActions('run_aerodynamics')))[0].enabled,false);
  assert.match(await page.evaluate(async()=>{try{await controller.execute({command:'invoke_action',arguments:{id:'run_aerodynamics'}});return '';}catch(error){return error.message;}}),/disabled/);
  assert.match(await page.evaluate(async()=>{try{await controller.updateParameters({'planform.area':20});return '';}catch(error){return error.message;}}),/generated Study/);
  checks.push('Imported FE models expose their real source identity and units; dormant wing defaults cannot be mistaken for the imported model or used to launch a wing aerodynamic run.');
  const navigation=await page.evaluate(()=>{
   const tabs=[['Geometry','ribs','Ribs'],['Model','ribproperties','Ribs'],['Geometry','planform','Planform'],['Solve','stressreport','Stress Report']];
   const menus={structure:{label:'Structure',tabs:new Set(['ribs'])},properties:{label:'Properties',tabs:new Set(['ribproperties'])},geometrymenu:{label:'Geometry',tabs:new Set(['planform'])},resultsmenu:{label:'Results',tabs:new Set(['stressreport'])}};
   const resolve=value=>WingBoxerAppControl.resolveNavigation(value,tabs,menus);
   const result={id:resolve('ribs'),group:resolve('Structure / Ribs'),case:resolve('properties / ribs'),menu:resolve('geometrymenu'),label:resolve('Results / Stress Report')};
   for(const value of ['Ribs','not-a-real-tab'])try{resolve(value);result[value]='';}catch(error){result[value]=error.message;}
   return result;
  });
  assert.deepEqual({id:navigation.id,group:navigation.group,case:navigation.case,menu:navigation.menu,label:navigation.label},{id:'ribs',group:'ribs',case:'ribproperties',menu:'geometrymenu',label:'stressreport'});
  assert.match(navigation.Ribs,/ambiguous/);assert.match(navigation['not-a-real-tab'],/Unknown/);
  assert.match(await page.evaluate(async()=>{try{await controller.execute({command:'navigate',arguments:{tab:'missing'}});return '';}catch(error){return error.message;}}),/Unknown/);
  checks.push('Navigation resolves exact IDs and unambiguous menu/view labels, rejects ambiguous or nonexistent names and never claims a failed navigation succeeded.');
  await page.evaluate(()=>controller.destroy());assert.deepEqual(errors,[]);
  console.log(JSON.stringify({passed:true,checks,errors},null,2));
 }finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
