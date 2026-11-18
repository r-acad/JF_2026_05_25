/* Exact generated-property edits from RF results. Canonical values stay in SI. */
(function(root,factory){
 'use strict';
 const common=typeof module==='object'&&module.exports;
 const api=factory(root,common?require('./panel_table_data.js'):root.WingPanelTableData,common?require('./component_table_data.js'):root.WingComponentTableData,common?require('./numeric_inputs.js'):root.WingNumericInputs);
 if(common)module.exports=api;else root.WingRFPropertyEditor=api;
})(globalThis,function(root,panelData,componentData,numericInputs){
 'use strict';
 const clone=value=>JSON.parse(JSON.stringify(value)),finite=value=>typeof value==='number'&&Number.isFinite(value);
 const PARTS={1:['ribwebs','rib_web'],2:['ribstiffeners','rib_stiffener'],3:['sparwebs','front_web'],4:['sparwebs','rear_web'],
  8:['sparcaps','front_upper_cap'],9:['sparcaps','front_lower_cap'],10:['sparcaps','rear_upper_cap'],11:['sparcaps','rear_lower_cap'],
  12:['leskins','leading_upper_skin'],13:['leskins','leading_lower_skin'],14:['leribs','leading_rib'],15:['ribwebs','rib_web'],
  16:['ribstiffeners','rib_stiffener'],17:['sparwebs','front_web'],18:['sparwebs','rear_web']};
 const FAMILIES={sparwebs:'spar_web',sparcaps:'spar_cap',ribwebs:'rib_web',ribstiffeners:'rib_stiffener',leskins:'leading_edge_skin',leribs:'leading_edge_rib',runouts:'runout'};
 const numberText=value=>finite(value)?numericInputs?.format(value)??String(Number(value.toPrecision(5))):String(value??'');
 // Keep the underlying RF for sorting and governing-case selection. The UI
 // caps only the number it prints, never the physical assessment.
 const rfText=value=>finite(value)?Number(Math.min(999,value).toPrecision(5)).toString():'Unavailable';
 function assessmentSummary(report,pid,focus={}){
  const propertyIds=(focus.propertyIdsByPid?.[pid]||focus.propertyIds||[pid]).map(Number);
  focus=focus.byProperty?.[pid]||focus;
  const rows=(report?.rows||[]).filter(item=>(propertyIds.includes(Number(item.pid))||(item.propertyIds||[]).some(id=>propertyIds.includes(Number(id))))&&(!focus.panelKeys||focus.panelKeys.includes(item.panelKey)));
  const noDemand=item=>item.noDemand===true||item.combined?.sentinel===true||item.euler?.noCompression===true||item.blade?.noCompression===true||item.skinBuckling?.noDestabilizingLoad===true;
  const ordered=rows.slice().sort((a,b)=>Number(noDemand(a))-Number(noDemand(b))||(finite(a.reserveFactor)?a.reserveFactor:Infinity)-(finite(b.reserveFactor)?b.reserveFactor:Infinity));
  const row=ordered[0];
  if(!row)return{available:false,reason:'No reserve-factor assessment is available for this property.',failures:[]};
  const standaloneMode={von_mises:'Von Mises stress',principal_strain:'Laminate principal strain',euler_column:'Euler column buckling',stringer_blade:'Stringer blade instability',skin_buckling:'Skin panel buckling',spar_web_buckling:'Spar-web buckling',rib_web_buckling:'Rib-web buckling',spar_cap_buckling:'Spar-cap column buckling',rib_stiffener_buckling:'Rib-stiffener column buckling',rib_stiffener_blade:'Rib-stiffener blade instability'}[report?.failureMode]||'';
  const candidates=rows.flatMap(item=>item.combined?.assessments||(standaloneMode?[{...item,noDemand:noDemand(item),modeLabel:standaloneMode,failureMode:report.failureMode,scope:item.label||'Full property P'+pid,caseLabel:item.envelopeCaseLabel||''}]:[]));
  const uniqueChecks=new Map();for(const item of candidates){const key=[item.failureMode,item.sourceRowKey||'',item.scopeKey||'',item.scope||'',item.caseKey||'',!item.sourceRowKey&&!item.scopeKey&&!item.scope?JSON.stringify(item):''].join('|');if(!uniqueChecks.has(key))uniqueChecks.set(key,item);}
  const allAssessments=[...uniqueChecks.values()];
  const assessments=focus.assessments?allAssessments.filter(a=>['von_mises','principal_strain'].includes(a.failureMode)||focus.assessments.some(s=>s===a||s.failureMode===a.failureMode&&(s.sourceRowKey?s.sourceRowKey===a.sourceRowKey:s.scopeKey?s.scopeKey===a.scopeKey:s.scope===a.scope))):allAssessments,failures=[];
  for(const item of assessments){
   const cases=(item.caseResults||[]).filter(c=>finite(c.reserveFactor)&&c.reserveFactor<1&&!c.noDemand);
   const records=cases.length?cases:[item];
   for(const c of records)if(finite(c.reserveFactor)&&c.reserveFactor<1&&!c.noDemand)failures.push({
    value:c.reserveFactor,mode:item.modeLabel||item.failureMode,scope:item.scope||'',caseLabel:c.label||c.caseLabel||item.caseLabel||'',
    approximate:!!(c.approximate||c.approximation)});
  }
  failures.sort((a,b)=>a.value-b.value||a.mode.localeCompare(b.mode));
  const checks=assessments.map(item=>({value:finite(item.reserveFactor)?item.reserveFactor:null,complete:item.complete===true,
   mode:item.modeLabel||item.failureMode,modeKey:item.failureMode,scope:item.scope||'',scopeKey:item.scopeKey,sourceRowKey:item.sourceRowKey,
   caseLabel:item.caseLabel||'',noDemand:!!item.noDemand,approximate:!!(item.approximate||item.approximation),reason:item.reason||item.reserveFactorReason||''}));
  const scoped=focus.assessments&&row.combined,known=assessments.filter(a=>a.complete&&finite(a.reserveFactor)&&!a.noDemand),governing=known.reduce((best,a)=>!best||a.reserveFactor<best.reserveFactor?a:best,null),complete=assessments.length>0&&assessments.every(a=>a.complete);
  return{available:scoped?complete:rows.every(item=>item.complete===true&&finite(item.reserveFactor)),value:scoped?(governing?.reserveFactor??(complete?99:null)):row.reserveFactor,
   mode:scoped?(governing?.modeLabel||'No demand in applicable checks'):row.combined?.governingModeLabel||standaloneMode,caseLabel:scoped?(governing?.caseLabel||''):row.envelopeCaseLabel||'',scope:scoped?(governing?.scope||''):row.combined?.governingScope||row.label||'',
   reason:scoped?assessments.filter(a=>!a.complete).map(a=>a.reason||'Incomplete physical assessment.').join(' '):rows.filter(item=>!item.complete).map(item=>item.reserveFactorReason||item.reason||'Incomplete physical assessment.').join(' ')||row.reserveFactorReason||'',checks,failures,estimated:!!report.estimated,stale:!!report.stale&&!report.estimated,
   approximate:!!(row.approximate||row.approximation||assessments.some(a=>a.approximate||a.approximation)),
   incomplete:assessments.filter(a=>!a.complete).map(a=>(a.modeLabel||a.failureMode)+': '+(a.reason||a.reserveFactorReason||'Incomplete physical assessment.'))};
 }
 // One stable row per physical failure check remains visible after RF=1.
 function renderAssessmentChecks(doc,host,assessment){
  const checks=assessment?.checks?.length?assessment.checks:(assessment?.failures||[]).map(item=>({...item,complete:true}));
  if(!checks.length)return;
  const table=doc.createElement('table'),caption=doc.createElement('caption');caption.textContent='Minimum RF by failure check';table.append(caption);
  const head=doc.createElement('tr');for(const title of['RF','Failure mode','Critical load case / physical region']){const th=doc.createElement('th');th.textContent=title;head.append(th);}table.append(head);
  for(const item of checks){
   const tr=doc.createElement('tr');tr.dataset.failureMode=item.modeKey||'';tr.dataset.scopeKey=item.scopeKey||item.sourceRowKey||'';
   const value=doc.createElement('td');value.textContent=item.complete&&finite(item.value)?rfText(item.value)+(item.approximate?' (approx.)':''):'Unavailable';
   value.className=!item.complete||!finite(item.value)?'rf-check-unavailable':item.value<1?'rf-check-failing':'rf-check-passing';tr.append(value);
   const mode=doc.createElement('td');mode.textContent=item.mode||'';tr.append(mode);
   const scope=doc.createElement('td');scope.textContent=[item.caseLabel,item.scope].filter(Boolean).join(' - ');if(item.reason)scope.title=item.reason;tr.append(scope);table.append(tr);
  }
  host.append(table);
  if(assessment.failures?.length){
   const details=doc.createElement('details'),summary=doc.createElement('summary');summary.textContent='All load-case RFs below 1 ('+assessment.failures.length+')';details.append(summary);
   const cases=doc.createElement('table');for(const item of assessment.failures){const tr=doc.createElement('tr');for(const text of[rfText(item.value),item.mode,[item.caseLabel,item.scope].filter(Boolean).join(' - ')]){const td=doc.createElement('td');td.textContent=text;tr.append(td);}cases.append(tr);}details.append(cases);host.append(details);
  }
 }
 // Modal previews never write canonical Study inputs. Each new valid draft
 // cancels its predecessor, including already queued asynchronous replies.
 function previewController({read,onPreview,onResult,onReset,onStatus,delay=300,window:win=root}={}){
  let timer=null,controller=null,sequence=0,key=null,closed=false;
  const stop=()=>{sequence++;if(timer!==null)win.clearTimeout(timer);timer=null;controller?.abort();controller=null;};
  function refresh(){
   if(closed||typeof onPreview!=='function')return;
   const snapshot=read(),stamp=JSON.stringify([snapshot.valid,snapshot.edits]);if(key===stamp)return;key=stamp;stop();
   if(!snapshot.edits?.length){onReset?.();onStatus?.('',false);return;}
   if(!snapshot.valid){onReset?.();onStatus?.('Enter valid property values to estimate the panel reserve factors.',false);return;}
   const mine=sequence;onStatus?.('Estimating RFs for the draft properties…',true,{phase:'queued',restart:true});
   timer=win.setTimeout(async()=>{timer=null;controller=typeof AbortController==='function'?new AbortController():null;
    const onProgress=detail=>{if(!closed&&mine===sequence)onStatus?.(detail?.message||'Updating affected reserve factors…',true,detail);};
    try{const result=await onPreview({...snapshot,signal:controller?.signal,onProgress});if(closed||mine!==sequence)return;onResult?.(result);const counts=(result.report||result).incremental,scope=counts?' Updated '+counts.evaluatedRows+' physical checks; reused '+counts.reusedRows+' unchanged checks.':'';onStatus?.('Draft RF estimate at fixed internal loads.'+scope+' Apply to keep these properties; rerun FE analysis to verify.',false,{phase:'complete',counts});}
    catch(error){if(closed||mine!==sequence)return;if(error?.name==='AbortError'){onStatus?.('',false,{phase:'cancelled'});return;}onReset?.();onStatus?.('Draft RF estimate unavailable: '+(error?.message||String(error)),false);}
   },delay);
  }
  return{refresh,close(){closed=true;stop();onStatus?.('',false,{phase:'cancelled'});},reset(){key=null;stop();onReset?.();onStatus?.('',false);}};
 }
 function inputs(context={}){
  const data=context.data||context;
  return{...context,parameters:context.parameters||{},panels:context.panels||data.stiffened_panels?.panels||[],
   elements:context.groups||data.groups||context.elements||data.elements||[],ribs:context.ribs||data.annotations?.ribs||[],
   layout_token:context.layout_token||data.stiffened_panels?.layout_token||'',readOnly:!!(context.readOnly||context.importedDeck||context.imported||data.imported_deck||context.generated===false)};
 }
 function locate(context,pid){
  const raw=inputs(context),fail=reason=>({editable:false,pid,reason});
  if(!Number.isSafeInteger(pid)||pid<1)return fail('Choose one valid property ID.');
  if(raw.readOnly)return fail('Imported FE properties are read-only here. Edit the original input file and reload it.');
  if(raw.busy||raw.updating)return fail('Wait for the Study operation or mesh update to finish before editing this property.');
  if(!panelData||!componentData)return fail('Restart JFEM-Boxer and refresh the page to load the property editors.');
  if(!raw.elements.some(group=>Number(group.pid)===pid))return fail('This property is absent from the current generated model. Refresh the RF table after creating FEM.');
  let kind,item,snapshot,api,key;
  for(const panel of raw.panels){
   if(Number(panel.shell_pid)===pid){kind='skins';item=panel;break;}
   if([panel.stringer_pid,panel.stringer_web_pid,panel.stringer_flange_pid].some(value=>value!=null&&Number(value)===pid)){kind='stringers';item=panel;break;}
  }
  if(pid===13){
   kind='runouts';key='stringer_runout:1';api=componentData;snapshot=api.compact(raw,kind);item=snapshot.panels.find(row=>row.key===key);
  }else if(item){
   if(!raw.layout_token)return fail('Create FEM before editing an individual panel property.');
   snapshot=panelData.compact(raw);api=panelData;key=item.key;
  }else{
   const family=Math.floor(pid/1000000),index=pid%1000000,mapping=PARTS[family];
   if(!mapping||index<1)return fail('This property has no independent local editor. Shared defaults and movable-surface properties are edited in their Properties or Structure forms.');
   [kind]=mapping;key=mapping[1]+':'+index;api=componentData;snapshot=api.compact(raw,kind);item=snapshot.panels.find(row=>row.key===key);
   if(!item)return fail('This physical rib or bay is no longer present. Create FEM and refresh the RF table.');
  }
  return{editable:true,pid,kind,key,item,snapshot,api};
 }
 function resolve(context,pid){
  pid=Number(pid);const found=locate(context,pid);if(!found.editable)return found;
  const{kind,key,item,snapshot,api}=found,values=api.effective(snapshot,item,kind),inherited=api.inherited(snapshot,item,kind);
  const family=kind==='skins'?item.skin+'_skin':kind==='stringers'?'stringer':FAMILIES[kind];
  // Request all possible gauge limits, including currently dormant flange or
  // sandwich fields. The dialog activates only the fields of its final section.
  const minimums=panelData.gauge.dimensions(snapshot.parameters,family,{...values,enabled:true,kind:'sandwich',flange_width:1})
   .map(({field,minimum})=>({field,minimum}));
  const componentLabel=componentData.CATALOG[kind]?.rows[item.stringer-1];
  return{editable:true,pid,kind,key,parameter:api.PARAMETER,layoutToken:snapshot.layout_token,
   label:kind==='runouts'?'P13 · Shared stringer runout connectors':'P'+pid+' · '+(componentLabel?componentLabel+' · ':'')+(item.label||('Panel '+item.id)),
   note:kind==='runouts'?'Changes apply to every actual P13 stringer runout connector in the model. The square section is centered on the connector GRID line. Set its minimum side in Properties / Stringers.':kind==='stringers'&&snapshot.parameters['stringers.model']==='shell'?'This edits the physical stringer section. Its web and attached flange properties, and their mesh, update together.':'Local overrides affect this physical property region; shared minimum gauges remain unchanged.',
   values:clone(values),inherited:clone(inherited),explicit:Object.fromEntries(api.FIELDS[kind].map(field=>[field.name,api.fieldState(snapshot,kind,key,field.name).present])),minimums,sectionModel:snapshot.parameters['stringers.model']||'beam',
   materialChoices:api.materialList(snapshot.parameters),fields:api.FIELDS[kind].map(field=>({...field,current:values[field.name],inherited:inherited[field.name],minimum:api.minimum?.(snapshot,item,kind,field.name)??null}))};
 }
 function activeField(descriptor,value,field){
  const kind=descriptor.kind;
  if(kind==='ribstiffeners'&&value.enabled===false)return field==='enabled';
  if(['skins','sparwebs','ribwebs','leskins','leribs'].includes(kind))return field==='kind'||(value.kind==='sandwich'?['face_thickness','core_thickness','face_material','core_material'].includes(field):['thickness','material'].includes(field));
  if(kind==='stringers'&&value.flange_width===0&&field==='flange_thickness')return false;
  return true;
 }
 function parse(field,raw,inherited){
  const text=String(raw??'').trim();if(!text)return inherited;
  if(field.type==='number'||field.type==='material')return Number(text)/(field.scale||1);
  if(field.type==='boolean')return text==='true'?true:text==='false'?false:undefined;
  return text;
 }
 // The inherited 5 mm² runout square has an irrational side. Its clean label
 // is not a new, smaller physical dimension: typing that inherited label
 // restores the exact inherited SI value and removes a redundant override.
 function runoutInheritance(descriptor,field,raw){
  return descriptor.kind==='runouts'&&field.name==='side'&&String(raw??'').trim()!==''&&
   finite(descriptor.inherited.side)&&Number(raw)===Number(numberText(descriptor.inherited.side*(field.scale||1)));
 }
 function validate(descriptor,rawValues={}){
  const values={...descriptor.values},errors={},belowMinimumFields=[];
  if(!descriptor.editable)return{valid:false,errors:{_property:descriptor.reason||'Property editing unavailable.'},values,belowMinimumFields};
  const definitions=new Map(descriptor.fields.map(field=>[field.name,field]));
  for(const[name,raw]of Object.entries(rawValues)){
   const field=definitions.get(name);if(!field){errors[name]='Unknown property field.';continue;}
   values[name]=runoutInheritance(descriptor,field,raw)?descriptor.inherited[name]:parse(field,raw,descriptor.inherited[name]);
  }
  // Older inline rib/spar totals remain authoritative until a local core is
  // explicitly supplied, exactly as in the component property table adapter.
  const explicitCore=Object.hasOwn(rawValues,'core_thickness')?String(rawValues.core_thickness??'').trim()!=='':descriptor.explicit?.core_thickness;
  if(descriptor.parameter==='properties.components'&&values.kind==='sandwich'&&finite(values.legacy_total_thickness)&&!explicitCore)
   values.core_thickness=values.legacy_total_thickness-2*values.face_thickness;
  const add=(field,message)=>{if(!errors[field])errors[field]=message;};
  const stringer=descriptor.kind==='stringers',blade=stringer&&values.flange_width===0;
  for(const field of descriptor.fields){
   const name=field.name,value=values[name];if(!activeField(descriptor,values,name))continue;
   if(field.type==='number'){
    const zero=stringer&&(name==='flange_width'||blade&&name==='flange_thickness');
    if(!finite(value)||(zero?value<0:value<=0))add(name,field.label+' must be a finite '+(zero?'non-negative':'positive')+' value.');
   }else if(field.type==='material'&&(!Number.isInteger(value)||!descriptor.materialChoices.some(material=>material.id===value)))add(name,'Choose a material from the Study library.');
   else if(field.type==='kind'&&!['monolithic','sandwich'].includes(value))add(name,'Choose monolithic or sandwich construction.');
   else if(field.type==='boolean'&&typeof value!=='boolean')add(name,'Choose On or Off.');
  }
  if(['stringers','ribstiffeners'].includes(descriptor.kind)&&values.enabled!==false&&!blade){
   if(finite(values.flange_thickness)&&finite(values.height)&&values.flange_thickness>=values.height)add('flange_thickness','Flange thickness must be smaller than the total height.');
   if(finite(values.web_thickness)&&finite(values.flange_width)&&values.web_thickness>=values.flange_width)add('web_thickness','Web thickness must be smaller than flange width.');
  }
  for(const limit of descriptor.minimums||[]){
   const fields=limit.field==='total_thickness'?(values.kind==='sandwich'?['face_thickness','core_thickness']:['thickness']):[limit.field];
   if(!fields.every(field=>activeField(descriptor,values,field)))continue;
   const value=limit.field==='total_thickness'?(values.kind==='sandwich'?2*values.face_thickness+values.core_thickness:values.thickness):values[limit.field];
   if(!finite(value)||!finite(limit.minimum))continue;
   const tolerance=1e-10*Math.max(Math.abs(limit.minimum),Math.abs(value),1e-12);
   if(value<limit.minimum-tolerance){
    const message=limit.field.replaceAll('_',' ')+' cannot be below the minimum gauge '+numberText(limit.minimum*1000)+' mm.';
    for(const field of fields){add(field,message);if(!belowMinimumFields.includes(field))belowMinimumFields.push(field);}
   }
  }
  return{valid:Object.keys(errors).length===0,errors,values,belowMinimumFields};
 }
 function prepare(context,pid,rawValues={}){
  const found=locate(context,Number(pid)),descriptor=resolve(context,pid);if(!found.editable)throw Error(found.reason);
  const checked=validate(descriptor,rawValues);if(!checked.valid){const error=Error(Object.values(checked.errors).join(' '));error.fields=checked.errors;error.belowMinimumFields=checked.belowMinimumFields;throw error;}
  const{api,snapshot,item,kind,key}=found,changedFields=Object.keys(rawValues).filter(field=>activeField(descriptor,checked.values,field));
  if(!changedFields.length)throw Error('Change a property value before applying.');
  let rows=clone(api.rows(snapshot.parameters)),index=rows.findIndex(row=>row.key===key);
  const row=index<0?(api===panelData?{key,layout_token:snapshot.layout_token}:{key}):rows[index];
  if(api===panelData&&row.layout_token!==snapshot.layout_token)throw Error('This override belongs to an earlier rib/stringer layout. Reset panel overrides before regenerating.');
  const section=api===panelData?api.section(kind):null,target=section?(row[section]={...row[section]}):row;
  const preparedRaw=field=>runoutInheritance(descriptor,descriptor.fields.find(item=>item.name===field),rawValues[field])?'':rawValues[field];
  for(const field of changedFields){if(String(preparedRaw(field)??'').trim()==='')delete target[field];else target[field]=checked.values[field];}
  if(index<0)rows.push(row);
  // Validate the final section atomically through the existing table APIs.
  // Intermediate edits such as changing both T width and web thickness must
  // not be rejected because their individual intermediate sections differ.
  let working={...snapshot,parameters:{...snapshot.parameters,[api.PARAMETER]:rows}};
  for(const field of changedFields){rows=api.update(working,kind,item.key,field,preparedRaw(field));working={...working,parameters:{...working.parameters,[api.PARAMETER]:rows}};}
  return{parameter:api.PARAMETER,rows,pid:Number(pid),kind,key,layoutToken:snapshot.layout_token,changedFields};
 }
 function open({document:doc=root.document,descriptor,onApply,onPreview,onDraftChange,onClose,assessmentFocus}={}){
  if(!doc?.body)throw Error('The property editor needs an open document.');
  if(descriptor.kind==='runouts')numericInputs?.install?.(doc);
  const win=doc.defaultView,prior=doc.activeElement,dialog=doc.createElement('dialog');dialog.className='rf-property-editor';dialog.setAttribute('aria-label','Edit property');
  const header=doc.createElement('header'),title=doc.createElement('h2'),closeButton=doc.createElement('button');title.textContent='Edit '+(descriptor.label||'property');closeButton.type='button';closeButton.className='rf-property-close';closeButton.textContent='×';closeButton.setAttribute('aria-label','Close property editor');header.append(title,closeButton);dialog.append(header);
  const note=doc.createElement('p');note.className='rf-property-note';note.textContent=descriptor.editable?descriptor.note:descriptor.reason;dialog.append(note);
  const assessment=doc.createElement('section');assessment.className='rf-property-assessment';assessment.setAttribute('aria-label','Property reserve factors');dialog.append(assessment);
  const baselineAssessment=descriptor.assessment,previewStatus=doc.createElement('p');previewStatus.className='rf-property-preview-status';previewStatus.setAttribute('role','status');previewStatus.setAttribute('aria-live','polite');previewStatus.hidden=true;dialog.append(previewStatus);
  const previewActivity=root.WingActivity?.inline?.(previewStatus);
  function renderAssessment(){
   assessment.replaceChildren();const a=descriptor.assessment||{reason:'No current reserve factors are available. Run the analysis and open Stress Report.',failures:[]};
   const heading=doc.createElement('h3');heading.textContent=a.available?'Critical RF '+rfText(a.value)+' · '+a.mode:'Critical RF unavailable';assessment.append(heading);
   const context=doc.createElement('p');context.textContent=a.available?[a.caseLabel,a.scope].filter(Boolean).join(' · '):a.reason;assessment.append(context);
   if(a.stale||a.estimated||a.approximate){const status=doc.createElement('p');status.className='rf-property-note';status.textContent=[a.stale?'Previous analysis; model and results are not in sync.':'',a.estimated?'Fixed-load sizing estimate; rerun to include load redistribution.':'',a.approximate?'Contains a truncated plate-basis approximation; see assessment details.':''].filter(Boolean).join(' ');assessment.append(status);}
   renderAssessmentChecks(doc,assessment,a);
   if(a.incomplete?.length){const missing=doc.createElement('p');missing.className='rf-property-note';missing.textContent='Incomplete checks: '+a.incomplete.join(' ');assessment.append(missing);}
  }
  const instructions=doc.createElement('p');instructions.className='rf-property-note';instructions.textContent='Dimensions are in mm. Clear a value to inherit its current default. Apply updates the Study and estimates reserve factors using the previous element forces and moments with the edited sections. Estimated values and colors are sizing guidance; rerun the FE analysis to include load redistribution.';instructions.hidden=!descriptor.editable;dialog.append(instructions);
  const totalMinimum=descriptor.minimums?.find(row=>row.field==='total_thickness');if(totalMinimum){const minimum=doc.createElement('p');minimum.className='rf-property-minimum';minimum.textContent='Minimum total skin/web thickness: '+numberText(totalMinimum.minimum*1000)+' mm (including both faces and the core for a sandwich).';dialog.append(minimum);}
  const grid=doc.createElement('div');grid.className='rf-property-fields';dialog.append(grid);
  const status=doc.createElement('p');status.className='rf-property-error';status.setAttribute('role','alert');status.hidden=true;dialog.append(status);
  const footer=doc.createElement('footer'),cancel=doc.createElement('button'),apply=doc.createElement('button');cancel.type=apply.type='button';cancel.textContent='Cancel';apply.textContent='Apply property';apply.className='rf-property-apply';footer.append(cancel,apply);dialog.append(footer);doc.body.append(dialog);
  let closed=false,pending=false,rawValues={},controls=new Map(),checked=validate(descriptor,rawValues);
  const fieldText=(value,field)=>field.type==='number'?numberText(value*(field.scale||1)):String(value??'');
  const drafts=()=>Object.keys(rawValues).length>0;
  const notify=()=>onDraftChange?.({pid:descriptor.pid,hasDrafts:drafts()||pending,invalid:!checked.valid,belowMinimum:checked.belowMinimumFields.length>0,belowMinimumFields:[...checked.belowMinimumFields],errors:{...checked.errors}});
  function update(){
   checked=validate(descriptor,rawValues);
   for(const[name,{wrap,input,error,minimum,field}]of controls){
    const active=activeField(descriptor,checked.values,name);wrap.hidden=!active;input.disabled=!descriptor.editable||pending||!active;
    const message=checked.errors[name]||'';wrap.classList.toggle('invalid',!!message);wrap.classList.toggle('below-minimum',checked.belowMinimumFields.includes(name));input.setAttribute('aria-invalid',String(!!message));error.textContent=message;error.hidden=!message;
    const direct=descriptor.minimums?.find(row=>row.field===name||(name==='thickness'&&row.field==='total_thickness'));
    minimum.textContent=direct?'Minimum gauge: '+numberText(direct.minimum*1000)+' mm':'';minimum.hidden=!minimum.textContent;
    if(name==='core_thickness'&&descriptor.parameter==='properties.components'&&finite(checked.values.legacy_total_thickness)&&!descriptor.explicit?.core_thickness&&!Object.hasOwn(rawValues,name))input.value=fieldText(checked.values[name],field);
   }
   apply.disabled=!descriptor.editable||pending||!drafts()||!checked.valid;cancel.disabled=pending;closeButton.disabled=pending;notify();preview?.refresh();
  }
  function render(){
   renderAssessment();
   grid.replaceChildren();controls=new Map();
   for(const field of descriptor.fields||[]){
    const wrap=doc.createElement('label');wrap.className='rf-property-cell';wrap.dataset.field=field.name;
    const label=doc.createElement('span');label.className='rf-property-label';label.textContent=field.label+(field.unit?' ('+field.unit+')':'');wrap.append(label);
    const input=doc.createElement(field.type==='number'?'input':'select');input.dataset.field=field.name;input.setAttribute('aria-label',label.textContent);
    if(field.type==='number'){input.type='text';input.inputMode='decimal';input.placeholder=fieldText(descriptor.inherited[field.name],field);}
    else{
     const inherit=doc.createElement('option');inherit.value='';inherit.textContent='Inherit: '+fieldText(descriptor.inherited[field.name],field);input.append(inherit);
     const choices=field.type==='kind'?[['monolithic','Monolithic'],['sandwich','Sandwich · face/core/face']]:field.type==='boolean'?[['true','On'],['false','Off']]:(descriptor.materialChoices||[]).map(material=>[material.id,material.name+' (ID '+material.id+')']);
     for(const[value,text]of choices){const option=doc.createElement('option');option.value=String(value);option.textContent=text;input.append(option);}
    }
    input.value=Object.hasOwn(rawValues,field.name)?rawValues[field.name]:fieldText(descriptor.values[field.name],field);wrap.append(input);
    const minimum=doc.createElement('small');minimum.className='rf-property-minimum';wrap.append(minimum);
    const error=doc.createElement('small');error.className='rf-property-field-error';wrap.append(error);grid.append(wrap);controls.set(field.name,{wrap,input,error,minimum,field});
    input.addEventListener(field.type==='number'?'input':'change',()=>{const others={...rawValues};delete others[field.name];const current=fieldText(validate(descriptor,others).values[field.name],field);if(input.value===current)delete rawValues[field.name];else rawValues[field.name]=input.value;status.hidden=true;update();});
   }
   update();
  }
  function close(){if(closed||pending)return false;closed=true;preview?.close();previewActivity?.destroy();dialog.remove();onDraftChange?.({pid:descriptor.pid,hasDrafts:false,invalid:false,belowMinimum:false,belowMinimumFields:[],errors:{}});onClose?.();if(prior?.isConnected)prior.focus?.({preventScroll:true});return true;}
  function setError(error){status.textContent=error?.message||String(error);status.hidden=false;if(error?.fields){checked.errors={...checked.errors,...error.fields};checked.valid=false;checked.belowMinimumFields=[...new Set([...checked.belowMinimumFields,...error.belowMinimumFields||[]])];apply.disabled=true;for(const[name,message]of Object.entries(error.fields)){const control=controls.get(name);if(control){control.wrap.classList.add('invalid');control.wrap.classList.toggle('below-minimum',checked.belowMinimumFields.includes(name));control.input.setAttribute('aria-invalid','true');control.error.textContent=message;control.error.hidden=false;}}}notify();}
  async function commit(){
   update();if(apply.disabled)return;pending=true;status.hidden=true;update();
   try{if(typeof onApply!=='function')throw Error('The Study window is not connected to this property editor.');await onApply({pid:descriptor.pid,values:{...rawValues},layoutToken:descriptor.layoutToken,descriptor});pending=false;rawValues={};close();}
   catch(error){pending=false;update();setError(error);}
  }
  apply.addEventListener('click',commit);cancel.addEventListener('click',close);closeButton.addEventListener('click',close);dialog.addEventListener('cancel',event=>{event.preventDefault();close();});
  dialog.addEventListener('keydown',event=>{if(event.key==='Enter'&&event.target.tagName==='INPUT'){event.preventDefault();void commit();}});
  const preview=previewController({window:win||root,onPreview,read:()=>({valid:checked.valid,edits:drafts()?[{pid:descriptor.pid,values:{...rawValues}}]:[]}),
   onResult:result=>{descriptor.assessment=assessmentSummary(result.report||result,descriptor.pid,assessmentFocus);renderAssessment();},
   onReset:()=>{descriptor.assessment=baselineAssessment;renderAssessment();},
   onStatus:(message,pending,detail)=>{previewStatus.hidden=!message;previewStatus.textContent=message;previewStatus.dataset.pending=String(pending);previewStatus.dataset.phase=detail?.phase||'';previewStatus.setAttribute('aria-busy',String(pending));previewActivity?.setBusy(pending,{restart:detail?.restart===true});assessment.classList.toggle('preview-pending',pending);}});
  render();if(typeof dialog.showModal==='function')dialog.showModal();else dialog.setAttribute('open','');
  win?.setTimeout(()=>{if(!closed)([...controls.values()].find(control=>!control.wrap.hidden&&!control.input.disabled)?.input||closeButton).focus();},0);
  return{close,hasDrafts:()=>!closed&&drafts(),element:dialog,setError,getState:()=>({pid:descriptor.pid,rawValues:{...rawValues},...checked}),clearAssessment(reason){preview.close();descriptor={...descriptor,assessment:{available:false,reason,failures:[]}};renderAssessment();},setDescriptor(next){if(drafts()||pending)throw Error('Finish or cancel the current property edits before replacing the editor.');descriptor=next;title.textContent='Edit '+(descriptor.label||'property');render();}};
 }
 return{resolve,validate,prepare,open,activeField,assessmentSummary,renderAssessmentChecks,previewController};
});
