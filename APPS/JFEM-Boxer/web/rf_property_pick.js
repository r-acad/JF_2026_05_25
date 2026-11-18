/* Direct property sizing from a 3D Inspect double click. Reads existing RFs;
 * opening a local editor never starts a structural/RF calculation or tab. */
(function(root,factory){
 const api=factory(root);
 if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRFPropertyPick=api;
})(globalThis,function(root){
 'use strict';
 const positive=value=>Number.isSafeInteger(Number(value))&&Number(value)>0;
 const entries=value=>value instanceof Map?[...value.values()]:Array.isArray(value)?value:Object.values(value||{});
 const kinds=new Set(['quad','tria','shell','bar','solid']);
 function unassessedReport(context={}){
  const data=context.data||{},properties=new Map(),groups=entries(context.groups||data.groups||context.componentGroups);
  for(const group of groups){
   const pid=Number(group.pid??group.properties?.pid);
   if(!positive(pid)||!kinds.has(group.kind)||group.name==='aero')continue;
   if(!properties.has(pid))properties.set(pid,{pid,names:new Set(),propertyType:group.properties?.type||'Unknown'});
   properties.get(pid).names.add(group.name||'');
  }
  const reason='Reserve factors have not been assessed for this property in the current Study. The grey value is unavailable, not zero. Edit the property now, or run the analysis and Stress Report to assess it.';
  const rows=[...properties.values()].sort((a,b)=>a.pid-b.pid).map(p=>({pid:p.pid,label:'P'+p.pid,names:[...p.names],propertyType:p.propertyType,materialIds:[],
   reserveFactor:null,complete:false,coverage:{total:1,recovered:0},status:'unassessed',reserveFactorReason:reason,
   combined:{assessments:[],governingModeLabel:'Unavailable',governingScope:''}}));
  return{failureMode:'minimum_rf',rows,complete:false,coverage:{total:rows.length,recovered:0},includedCases:[],excludedCases:[],missingCases:[],
   method:'maximum',stressUnit:'MPa',stressFactor:1e-6,forceUnit:'N',lengthUnit:'m',note:reason};
 }
 function physicalPick(hit){
  if(!hit)return{};const result={};
  if(typeof hit.scopeKey==='string'&&hit.scopeKey.trim())result.scopeKey=hit.scopeKey;
  const point=hit.point?.asArray?.()||hit.point;
  if((Array.isArray(point)||ArrayBuffer.isView(point))&&point.length===3&&Array.from(point).every(Number.isFinite))result.point=Array.from(point);
  return result;
 }
 function target({event,canvas,state,pick}={}){
  if(event?.button!==0||!state?.hasModel||state.activeTab!=='inspect'||state.busy||state.exclusivePick||typeof pick!=='function')return null;
  const box=canvas.getBoundingClientRect(),hit=pick(event.clientX-box.left,event.clientY-box.top);
  if(!hit||!positive(hit.pid)||!positive(hit.eid)||!kinds.has(hit.kind)||hit.name==='aero'||hit.helper)return null;
  return{pid:Number(hit.pid),eid:Number(hit.eid),kind:hit.kind,...physicalPick(hit)};
 }
 function create(options={}){
  const tables=options.tables||root.WingReserveFactorTables,editor=options.editor||root.WingRFPropertyEditor;
  if(!tables||!editor)throw Error('Refresh JFEM-Boxer to load direct property editing.');
  let destroyed=false,lastTarget=null;
  const read=()=>{const raw=options.readReport?.();return raw?.report?raw:raw?.rows?{report:raw}:{};};
  const context=()=>options.readContext?.()||{};
  const table=tables.connect({
   readSnapshot:()=>{const current=context(),saved=read(),report=saved.report||unassessedReport(current),data=current.data||{};
    return{report,propertyPreview:true,requestedFailureMode:report.failureMode||'minimum_rf',onlyBelowOne:false,
     generated:!current.readOnly&&!current.importedDeck&&!data.imported_deck,panels:current.panels||data.stiffened_panels?.panels||[],
     componentGroups:current.groups||data.groups||[],caseScopeLabel:saved.report?'Previously calculated assessment; no calculation started by opening this view.':'RFs not calculated; property definitions remain editable.'};},
   onEditProperty:(pid,doc,hooks)=>{
    const current=context(),saved=read(),descriptor=editor.resolve(current,pid);
    if(!descriptor.editable)return editor.open({document:doc,descriptor:{...descriptor,label:'P'+pid,assessment:editor.assessmentSummary(saved.report,pid)}});
    const picked=Number(lastTarget?.pid)===Number(pid)?lastTarget:null;
    return options.onEditProperty(pid,doc,{...hooks,skipAssessment:true,assessmentReport:saved.report||null,sourceContext:saved.sourceContext,
     pickedElementId:picked?.eid,...physicalPick(picked)});
   },
   onError:message=>options.onError?.(message)
  });
  function open(hit){
   if(destroyed||!hit||!positive(hit.pid))return false;
   const{scopeKey,point,...entity}=hit;lastTarget={...entity,...physicalPick(hit)};
   const scopeApi=options.scope||root.WingRFPanelScope;
   if(scopeApi){
    try{
     const current=context(),scope=scopeApi.resolve(current,{...lastTarget,pid:Number(hit.pid),eid:Number(hit.eid)});
     if(['compression_panel','plain_skin'].includes(scope?.kind)){
      if(typeof options.onEditProperty!=='function')throw Error('The physical panel editor is unavailable. Refresh JFEM-Boxer.');
      const saved=read();options.onInspect?.(lastTarget);
      options.onEditProperty(Number(hit.pid),options.canvas?.ownerDocument||root.document,{
       skipAssessment:true,assessmentReport:saved.report||null,sourceContext:saved.sourceContext,
       pickedElementId:Number(hit.eid),...physicalPick(lastTarget),scopeKey:scope.key});
      return true;
     }
    }catch(error){options.onError?.(error?.message||String(error));return false;}
   }
   // Inspect edits stay in the Study. A scene rebuild can reinstall this
   // controller, so it must never create a detached browser tab implicitly.
   try{
    const current=context(),saved=read(),pid=Number(hit.pid),doc=options.canvas?.ownerDocument||root.document,descriptor=editor.resolve(current,pid);
    options.onInspect?.(lastTarget);
    if(!descriptor.editable)editor.open({document:doc,descriptor:{...descriptor,label:'P'+pid,assessment:editor.assessmentSummary(saved.report,pid)}});
    else{
     if(typeof options.onEditProperty!=='function')throw Error('Property editing is unavailable. Refresh JFEM-Boxer.');
     options.onEditProperty(pid,doc,{skipAssessment:true,assessmentReport:saved.report||null,sourceContext:saved.sourceContext,pickedElementId:Number(hit.eid),...physicalPick(lastTarget)});
    }
    return true;
   }catch(error){options.onError?.(error?.message||String(error));return false;}
  }
  function handleDoubleClick(event){
   if(destroyed)return false;
   const hit=target({event,canvas:options.canvas,state:options.readState?.(),pick:options.pick});
   if(!hit)return false;
   event.preventDefault();event.stopImmediatePropagation?.();open(hit);return true;
  }
  return{open,handleDoubleClick,refresh:force=>table.refresh(force),clearResults:options=>table.clearResults(options),get target(){return lastTarget;},destroy(){if(destroyed)return;destroyed=true;table.destroy();}};
 }
 return{unassessedReport,target,create};
});
