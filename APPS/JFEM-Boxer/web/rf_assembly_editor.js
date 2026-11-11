/* Edit the actual skin and stringer properties of a shared RF criterion. */
(function(root,factory){
 const api=factory(typeof module==='object'&&module.exports?require('./rf_property_editor.js'):root.WingRFPropertyEditor);
 if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRFAssemblyEditor=api;
})(globalThis,function(core){
 'use strict';
 const finite=Number.isFinite,unique=values=>[...new Set(values.map(Number).filter(Number.isSafeInteger))],clone=value=>JSON.parse(JSON.stringify(value));
 function related(context,pid,report){
  pid=Number(pid);const data=context.data||{},panels=context.panels||data.stiffened_panels?.panels||[],ids=new Set([pid]),reasons=[];
  const panelIds=p=>[p.shell_pid,p.stringer_pid,p.stringer_web_pid,p.stringer_flange_pid].filter(v=>v!=null).map(Number);
  // Never infer membership by adjacent numeric PID: actual panel ownership and
  // the assessed column's recorded members are the sources of truth.
  for(const p of panels)if(panelIds(p).includes(pid))for(const id of panelIds(p))ids.add(id);
  const row=report?.rows?.find(r=>Number(r.pid)===pid),assessments=row?.combined?.assessments||[];
  const columns=assessments.filter(a=>a.failureMode==='euler_column'&&(!finite(a.reserveFactor)||a.reserveFactor<1||row?.combined?.governingMode==='euler_column'));
  if(report?.failureMode==='euler_column')for(const r of report.rows||[])if((r.propertyIds||[r.pid]).map(Number).includes(pid))columns.push(r);
  for(const a of columns){for(const id of a.propertyIds||[])ids.add(Number(id));reasons.push(a.scope||a.label||'Stringer and associated skin between ribs');}
  const bySection=new Map();
  for(const id of ids){const d=core.resolve(context,id);if(!d.editable)continue;const key=[d.parameter,d.kind,d.key].join('|');
   if(bySection.has(key))bySection.get(key).propertyIds.push(id);else bySection.set(key,{...d,propertyIds:[id]});}
  const descriptors=[...bySection.values()];
  descriptors.sort((a,b)=>(a.pid===pid?-1:b.pid===pid?1:0)||Number(a.kind!=='stringers')-Number(b.kind!=='stringers')||a.pid-b.pid);
  for(const d of descriptors)d.assessment=core.assessmentSummary(report,d.pid);
  return{pid,descriptors,scopes:[...new Set(reasons)],explanation:columns.length?
   'Euler column buckling is instability of the complete stringer plus its associated skin between ribs. Either the stringer section or the skin can be changed; all participating properties are shown below.':
   'This stiffened region contains both skin and stringer properties. Review the governing failure mode and edit either section below.'};
 }
 function prepare(context,edits){
  const working={...context,parameters:clone(context.parameters||{})},patches=new Map(),changed=[];
  // Stage and validate every edit before the caller writes any Study inputs.
  for(const edit of edits){const patch=core.prepare(working,edit.pid,edit.values);working.parameters[patch.parameter]=patch.rows;patches.set(patch.parameter,patch);changed.push(Number(edit.pid));}
  return{patches:[...patches.values()],propertyIds:unique(changed)};
 }
 const text=n=>finite(n)?String(Number(n.toPrecision(5))):String(n??''),rf=n=>text(Math.min(n,999));
 function open(options){
  const {document:doc=globalThis.document,bundle,onApply,onDraftChange,onClose}=options;
  if(bundle.descriptors.length<2)return core.open({...options,descriptor:bundle.descriptors[0],onApply:r=>onApply({...r,edits:[{pid:r.pid,values:r.values}]})});
  const node=(tag,label,cls)=>{const e=doc.createElement(tag);if(label!=null)e.textContent=label;if(cls)e.className=cls;return e;},prior=doc.activeElement;
  const dialog=node('dialog',null,'rf-property-editor rf-assembly-editor');dialog.setAttribute('aria-label','Edit stiffened region properties');
  const header=node('header'),heading=node('h2','Edit stiffened region · P'+bundle.pid),closeButton=node('button','×','rf-property-close');closeButton.type='button';closeButton.setAttribute('aria-label','Close property editor');header.append(heading,closeButton);dialog.append(header,node('p',bundle.explanation,'rf-property-note'));
  for(const scope of bundle.scopes)dialog.append(node('p',scope,'rf-property-note'));
  dialog.append(node('p','Dimensions are in mm. Clear a field to inherit its minimum/default. Apply updates all edited sections together and estimates RFs at fixed internal loads. Rerun the FE analysis to verify load redistribution.','rf-property-note'));
  const sectionGrid=node('div',null,'rf-assembly-sections');dialog.append(sectionGrid);
  const sections=bundle.descriptors.map(descriptor=>({descriptor,raw:{},controls:new Map(),checked:core.validate(descriptor,{})}));
  let pending=false,closed=false;
  for(const section of sections){
   const d=section.descriptor,block=node('section',null,'rf-assembly-section');block.dataset.pid=String(d.pid);block.append(node('h3',(d.kind==='stringers'?'Stringer section':d.kind==='skins'?'Skin section':'Section')+' · '+d.label));
   if(d.propertyIds.length>1)block.append(node('p','Shared section properties: '+d.propertyIds.map(id=>'P'+id).join(', '),'rf-property-note'));
   const assessment=node('div',null,'rf-property-assessment'),a=d.assessment;
   assessment.append(node('p',a?.available?['Critical RF '+rf(a.value),a.mode,a.caseLabel].filter(Boolean).join(' · '):(a?.reason||'RF unavailable')));
   if(a?.failures?.length){const table=node('table');table.append(node('caption','All assessed RFs below 1'));for(const failure of a.failures){const tr=node('tr');for(const value of[rf(failure.value),failure.mode,[failure.caseLabel,failure.scope].filter(Boolean).join(' · ')])tr.append(node('td',value));table.append(tr);}assessment.append(table);}
   if(a?.estimated||a?.stale)assessment.append(node('p',a.estimated?'Fixed-load sizing estimate; rerun to verify.':'Previous analysis; model and results are not in sync.','rf-property-note'));
   if(a?.incomplete?.length)assessment.append(node('p','Incomplete checks: '+a.incomplete.join(' '),'rf-property-note'));
   block.append(assessment);
   const grid=node('div',null,'rf-property-fields');block.append(grid);
   for(const field of d.fields){
    const wrap=node('label',null,'rf-property-cell');wrap.dataset.field=field.name;wrap.append(node('span',field.label+(field.unit?' ('+field.unit+')':''),'rf-property-label'));
    const input=node(field.type==='number'?'input':'select');input.dataset.field=field.name;input.setAttribute('aria-label','P'+d.pid+' '+field.label);
    const display=value=>field.type==='number'?text(value*(field.scale||1)):String(value??'');
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
   for(const s of sections){s.checked=core.validate(s.descriptor,s.raw);for(const[name,c]of s.controls){const active=core.activeField(s.descriptor,s.checked.values,name),message=s.checked.errors[name]||'';c.wrap.hidden=!active;c.input.disabled=pending||!active;c.input.setAttribute('aria-invalid',String(!!message));c.wrap.classList.toggle('invalid',!!message);c.wrap.classList.toggle('below-minimum',s.checked.belowMinimumFields.includes(name));c.error.textContent=message;c.error.hidden=!message;const floor=s.descriptor.minimums?.find(r=>r.field===name||(name==='thickness'&&r.field==='total_thickness'));c.minimum.textContent=floor?'Minimum gauge: '+text(floor.minimum*1000)+' mm':'';c.minimum.hidden=!floor;
    if(name==='core_thickness'&&s.descriptor.parameter==='properties.components'&&finite(s.checked.values.legacy_total_thickness)&&!s.descriptor.explicit?.core_thickness&&!Object.hasOwn(s.raw,name))c.input.value=c.display(s.checked.values[name]);}}
   apply.disabled=pending||!edits().length||sections.some(s=>!s.checked.valid);cancel.disabled=closeButton.disabled=pending;notify();
  }
  function close(){if(pending||closed)return false;closed=true;dialog.remove();onDraftChange?.({pid:bundle.pid,hasDrafts:false,properties:sections.flatMap(s=>s.descriptor.propertyIds.map(pid=>({pid,hasDrafts:false,belowMinimumFields:[]}))),belowMinimumFields:[]});onClose?.();if(prior?.isConnected)prior.focus?.({preventScroll:true});return true;}
  function setError(error){status.textContent=error?.message||String(error);status.hidden=false;}
  async function commit(){update();if(apply.disabled)return;const changes=edits();pending=true;update();try{await onApply({pid:bundle.pid,edits:changes,layoutToken:sections[0].descriptor.layoutToken});pending=false;close();}catch(error){pending=false;update();setError(error);}}
  apply.onclick=commit;cancel.onclick=closeButton.onclick=close;dialog.addEventListener('cancel',e=>{e.preventDefault();close();});dialog.addEventListener('keydown',e=>{if(e.key==='Enter'&&e.target.tagName==='INPUT'){e.preventDefault();void commit();}});update();if(dialog.showModal)dialog.showModal();else dialog.setAttribute('open','');
  return{element:dialog,close,hasDrafts:()=>!closed&&edits().length>0,setError,getState:()=>({edits:edits(),valid:sections.every(s=>s.checked.valid)})};
 }
 return{related,prepare,open};
});
