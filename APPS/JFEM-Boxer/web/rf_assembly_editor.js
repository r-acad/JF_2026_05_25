/* Edit one physical sizing panel and its local section properties. */
(function(root,factory){
 const api=factory(root,typeof module==='object'&&module.exports?require('./rf_property_editor.js'):root.WingRFPropertyEditor);
 if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRFAssemblyEditor=api;
})(globalThis,function(root,core){
 'use strict';
 const finite=Number.isFinite,unique=values=>[...new Set(values.map(Number).filter(Number.isSafeInteger))],clone=value=>JSON.parse(JSON.stringify(value));
 function panelScopeApi(){return root.WingRFPanelScope||(typeof module==='object'&&module.exports?require('./rf_panel_scope.js'):null);}
 function related(context,pid,report,focus={}){
  pid=Number(pid);const scopes=panelScopeApi();
  if(!scopes)throw Error('Refresh JFEM-Boxer to load the physical panel assessment.');
  const scope=scopes.resolve(context,{...focus,pid,eid:Number(focus.eid)});
  const ids=scope?.editablePropertyIds||scope?.propertyIds||[pid],bySection=new Map();
  for(const id of ids){
   const descriptor=core.resolve(context,Number(id));if(!descriptor.editable)continue;
   const key=[descriptor.parameter,descriptor.kind,descriptor.key].join('|');
   if(bySection.has(key))bySection.get(key).propertyIds.push(Number(id));
   else bySection.set(key,{...descriptor,propertyIds:[Number(id)]});
  }
  const descriptors=[...bySection.values()];
  descriptors.sort((a,b)=>Number(b.pid===pid)-Number(a.pid===pid)||Number(a.kind!=='skins')-Number(b.kind!=='skins')||a.pid-b.pid);
  const assess=(nextReport,input=context)=>scope?scopes.summary(input,nextReport,scope):core.assessmentSummary(nextReport,pid);
  const assessment=assess(report);
  // One physical sizing panel owns one assessment. Editable sections do not
  // acquire their own column RFs or recursively pull in adjacent stringers.
  for(const descriptor of descriptors){
   descriptor.assessment=assessment;
   descriptor.note=scope?.kind==='plain_skin'?'This section belongs to the inspected skin plate. The property definition can also be used by other elements.':
    scope?.kind==='compression_panel'?'This section belongs to the selected stringer segment or its associated skin. Edits use fixed internal loads until the next analysis.':
    'This section defines the inspected local component. Edits use fixed internal loads until the next analysis.';
  }
  const selectionKind=scope?.kind||'property',label=scope?.label||'';
  return{pid,scope,descriptors,assessment,assess,primaryDescriptors:descriptors,primaryPanelKey:scope?.panelKey,
   selectionKind,panelKey:scope?.key,panelLabel:label,assessmentFocus:{panelScope:scope},scopes:[],explanation:
    selectionKind==='plain_skin'?'This skin panel is assessed for skin strength and its own plate buckling. Its boundary stringer is not an internal member of this panel.':
    selectionKind==='compression_panel'?'This compression panel contains one stringer segment between ribs and its associated skin. The table combines the applicable strength, column, blade and skin checks for this panel.':
    'Edit this local component using its applicable strength and stability checks.'};
 }
 function prepare(context,edits){
  const working={...context,parameters:clone(context.parameters||{})},patches=new Map(),changed=[];
  // Stage and validate every edit before the caller writes any Study inputs.
  for(const edit of edits){const patch=core.prepare(working,edit.pid,edit.values);working.parameters[patch.parameter]=patch.rows;patches.set(patch.parameter,patch);changed.push(Number(edit.pid));}
  return{patches:[...patches.values()],propertyIds:unique(changed)};
 }
 const text=n=>finite(n)?String(Number(n.toPrecision(5))):String(n??''),rf=n=>text(Math.min(n,999));
 const dimensionText=value=>root.WingNumericInputs?.format?.(value)??text(value);
 function open(options){
  const {document:doc=globalThis.document,bundle,onApply,onPreview,onDraftChange,onClose}=options;
  if(!bundle.scope&&bundle.descriptors.length<2)return core.open({...options,descriptor:bundle.descriptors[0],assessmentFocus:bundle.assessmentFocus,onApply:r=>onApply({...r,edits:[{pid:r.pid,values:r.values}]})});
  root.WingNumericInputs?.install?.(doc);
  const node=(tag,label,cls)=>{const e=doc.createElement(tag);if(label!=null)e.textContent=label;if(cls)e.className=cls;return e;},prior=doc.activeElement;
  const dialog=node('dialog',null,'rf-property-editor rf-assembly-editor');dialog.setAttribute('aria-label',bundle.selectionKind==='property'?'Edit component properties':'Edit panel properties');
  const header=node('header'),heading=node('h2',bundle.panelLabel?(bundle.selectionKind==='property'?'Edit component - ':bundle.selectionKind==='plain_skin'?'Edit plain skin panel · ':'Edit compression panel · ')+bundle.panelLabel:'Edit property · P'+bundle.pid),closeButton=node('button','×','rf-property-close');closeButton.type='button';closeButton.setAttribute('aria-label','Close property editor');header.append(heading,closeButton);dialog.append(header,node('p',bundle.explanation,'rf-property-note'));
  for(const scope of bundle.scopes)dialog.append(node('p',scope,'rf-property-note'));
  dialog.append(node('p','Dimensions are in mm. Clear a field to inherit its minimum/default. Apply updates all edited sections together and estimates RFs at fixed internal loads. Rerun the FE analysis to verify load redistribution.','rf-property-note'));
  const previewStatus=node('p',null,'rf-property-preview-status');previewStatus.setAttribute('role','status');previewStatus.setAttribute('aria-live','polite');previewStatus.hidden=true;dialog.append(previewStatus);
  const previewActivity=root.WingActivity?.inline?.(previewStatus);
  const panelAssessment=node('div',null,'rf-property-assessment rf-panel-assessment');panelAssessment.dataset.panelKey=bundle.scope?.key||'';dialog.append(panelAssessment);
  const baselineAssessment=bundle.assessment;let displayedAssessment=baselineAssessment;
  function renderPanelAssessment(){
   panelAssessment.replaceChildren();const a=displayedAssessment;
   panelAssessment.append(node('h3',a?.available?[(bundle.selectionKind==='property'?'Minimum component RF ':'Minimum panel RF ')+rf(a.value),a.mode,a.caseLabel].filter(Boolean).join(' - '):(a?.reason||'Panel RF unavailable')));
   const checks=(a?.checks||[]).map(check=>({...check,mode:check.modeKey==='euler_column'&&!check.mode?.includes('associated skin')?'Stringer + associated skin - Euler buckling':check.mode}));
   core.renderAssessmentChecks(doc,panelAssessment,{...a,checks});
   if(a?.estimated||a?.stale)panelAssessment.append(node('p',a.estimated?'Fixed-load sizing estimate. Rerun analysis to verify load redistribution.':'Previous analysis. Model and results are not in sync.','rf-property-note'));
   if(a?.incomplete?.length)panelAssessment.append(node('p','Incomplete checks - '+a.incomplete.join(' '),'rf-property-note'));
  }
  renderPanelAssessment();dialog.append(node('h3',bundle.selectionKind==='property'?'Component properties':'Properties in this panel','rf-panel-properties-title'));
  const sectionGrid=node('div',null,'rf-assembly-sections');dialog.append(sectionGrid);
  const sections=bundle.descriptors.map(descriptor=>({descriptor,raw:{},controls:new Map(),checked:core.validate(descriptor,{})}));
  let pending=false,closed=false;
  for(const section of sections){
   const d=section.descriptor,block=node('section',null,'rf-assembly-section');block.dataset.pid=String(d.pid);block.dataset.sectionGroup='primary';
   const propertyTitle=node('h3',(d.kind==='stringers'?'Stringer':d.kind==='skins'?'Associated skin':d.kind==='sparcaps'?'Spar cap':d.kind==='runouts'?'Runout connector':'Section')+' - P'+d.pid);propertyTitle.title=d.label;block.append(propertyTitle);
   if(d.propertyIds.length>1)block.append(node('p','Section property IDs - '+d.propertyIds.map(id=>'P'+id).join(', '),'rf-property-note'));
   const grid=node('div',null,'rf-property-fields');block.append(grid);
   for(const field of d.fields){
    const wrap=node('label',null,'rf-property-cell');wrap.dataset.field=field.name;wrap.append(node('span',field.label+(field.unit?' ('+field.unit+')':''),'rf-property-label'));
    const input=node(field.type==='number'?'input':'select');input.dataset.field=field.name;input.setAttribute('aria-label','P'+d.pid+' '+field.label);
    const display=value=>field.type==='number'?dimensionText(value*(field.scale||1)):String(value??'');
    if(field.type==='number'){input.type='text';input.inputMode='decimal';input.placeholder=display(d.inherited[field.name]);}
    else{const inherit=node('option','Inherit: '+display(d.inherited[field.name]));inherit.value='';input.append(inherit);const choices=field.type==='kind'?[['monolithic','Monolithic'],['sandwich','Sandwich · face/core/face']]:field.type==='boolean'?[['true','On'],['false','Off']]:(d.materialChoices||[]).map(m=>[m.id,m.name+' (ID '+m.id+')']);for(const[value,label]of choices){const option=node('option',label);option.value=String(value);input.append(option);}}
    input.value=display(d.values[field.name]);input.title='P'+d.pid+' · '+field.label+'. '+(d.note||'');
    const minimum=node('small',null,'rf-property-minimum'),error=node('small',null,'rf-property-field-error');wrap.append(input,minimum,error);grid.append(wrap);section.controls.set(field.name,{wrap,input,minimum,error,field,display});
    input.addEventListener(field.type==='number'?'input':'change',()=>{const other={...section.raw};delete other[field.name];if(input.value===display(core.validate(d,other).values[field.name]))delete section.raw[field.name];else section.raw[field.name]=input.value;status.hidden=true;update();});
   }sectionGrid.append(block);
  }
  const status=node('p',null,'rf-property-error');status.setAttribute('role','alert');status.hidden=true;dialog.append(status);
  const footer=node('footer'),cancel=node('button','Cancel'),apply=node('button','Apply properties','rf-property-apply');cancel.type=apply.type='button';footer.append(cancel,apply);dialog.append(footer);doc.body.append(dialog);
  const edits=()=>sections.filter(s=>Object.keys(s.raw).length).map(s=>({pid:s.descriptor.pid,values:{...s.raw}}));
  function notify(){const details=sections.flatMap(s=>s.descriptor.propertyIds.map(pid=>({pid,hasDrafts:pending||Object.keys(s.raw).length>0,invalid:!s.checked.valid,belowMinimumFields:[...s.checked.belowMinimumFields]})));onDraftChange?.({pid:bundle.pid,propertyIds:details.map(d=>d.pid),properties:details,hasDrafts:details.some(d=>d.hasDrafts),invalid:details.some(d=>d.invalid),belowMinimum:details.some(d=>d.belowMinimumFields.length),belowMinimumFields:details.flatMap(d=>d.belowMinimumFields)});}
  function update(){
   for(const s of sections){s.checked=core.validate(s.descriptor,s.raw);for(const[name,c]of s.controls){const active=core.activeField(s.descriptor,s.checked.values,name),message=s.checked.errors[name]||'';c.wrap.hidden=!active;c.input.disabled=pending||!active;c.input.setAttribute('aria-invalid',String(!!message));c.wrap.classList.toggle('invalid',!!message);c.wrap.classList.toggle('below-minimum',s.checked.belowMinimumFields.includes(name));c.error.textContent=message;c.error.hidden=!message;const floor=s.descriptor.minimums?.find(r=>r.field===name||(name==='thickness'&&r.field==='total_thickness'));c.minimum.textContent=floor?'Minimum gauge: '+dimensionText(floor.minimum*1000)+' mm':'';c.minimum.hidden=!floor;
    if(name==='core_thickness'&&s.descriptor.parameter==='properties.components'&&finite(s.checked.values.legacy_total_thickness)&&!s.descriptor.explicit?.core_thickness&&!Object.hasOwn(s.raw,name))c.input.value=c.display(s.checked.values[name]);}}
   apply.disabled=pending||!edits().length||sections.some(s=>!s.checked.valid);cancel.disabled=closeButton.disabled=pending;notify();preview?.refresh();
  }
  function close(){if(pending||closed)return false;closed=true;preview?.close();previewActivity?.destroy();dialog.remove();onDraftChange?.({pid:bundle.pid,hasDrafts:false,properties:sections.flatMap(s=>s.descriptor.propertyIds.map(pid=>({pid,hasDrafts:false,belowMinimumFields:[]}))),belowMinimumFields:[]});onClose?.();if(prior?.isConnected)prior.focus?.({preventScroll:true});return true;}
  function setError(error){status.textContent=error?.message||String(error);status.hidden=false;}
  async function commit(){update();if(apply.disabled)return;const changes=edits();pending=true;update();try{await onApply({pid:bundle.pid,edits:changes,layoutToken:sections[0].descriptor.layoutToken});pending=false;close();}catch(error){pending=false;update();setError(error);}}
  const preview=core.previewController({window:doc.defaultView||globalThis,onPreview,read:()=>({edits:edits(),valid:sections.every(s=>s.checked.valid)}),
   onResult:result=>{const report=result.report||result;displayedAssessment=bundle.assess(report,result.assessmentInput);renderPanelAssessment();},
   onReset:()=>{displayedAssessment=baselineAssessment;renderPanelAssessment();},
   onStatus:(message,pending,detail)=>{previewStatus.hidden=!message;previewStatus.textContent=message;previewStatus.dataset.pending=String(pending);previewStatus.dataset.phase=detail?.phase||'';previewStatus.setAttribute('aria-busy',String(pending));previewActivity?.setBusy(pending,{restart:detail?.restart===true});panelAssessment.classList.toggle('preview-pending',pending);}});
  apply.onclick=commit;cancel.onclick=closeButton.onclick=close;dialog.addEventListener('cancel',e=>{e.preventDefault();close();});dialog.addEventListener('keydown',e=>{if(e.key==='Enter'&&e.target.tagName==='INPUT'){e.preventDefault();void commit();}});update();if(dialog.showModal)dialog.showModal();else dialog.setAttribute('open','');
  return{element:dialog,close,hasDrafts:()=>!closed&&edits().length>0,setError,getState:()=>({edits:edits(),valid:sections.every(s=>s.checked.valid)}),
   clearAssessment(reason){preview.close();displayedAssessment={available:false,reason,checks:[],failures:[]};renderPanelAssessment();previewStatus.hidden=true;}};
 }
 return{related,prepare,open};
});
