/* Integration with the canonical Boxer menu workflows. This module does not
 * rebuild/solve a model merely to answer a question about its current state.
 */
(function(root,factory){const api=factory(root);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingBoxerAppControl=api;})(globalThis,function(root){
  'use strict';
  const clone=value=>JSON.parse(JSON.stringify(value));
  const text=(value,max=1000)=>String(value??'').slice(0,max);
  const number=value=>typeof value==='number'&&Number.isFinite(value)?value:null;
  function resolveNavigation(target,tabs,menus={}){
    const value=String(target||'').trim(),normalize=value=>String(value).toLowerCase().replace(/\s*\/\s*/g,' / ').replace(/\s+/g,' ').trim();
    const ids=new Set([...tabs.map(row=>row[1]),...Object.keys(menus)]);
    if(ids.has(value))return value;
    const legacy={reference:'displayreference',vlm:'displayloads',planview:'planform'};
    if(legacy[value]&&ids.has(legacy[value]))return legacy[value];
    const wanted=normalize(value),matches=new Map();
    for(const [id,menu]of Object.entries(menus))if(normalize(menu.label)===wanted)matches.set(id,menu.label);
    for(const [group,id,label]of tabs){
      const parent=Object.values(menus).find(menu=>menu.tabs?.has?.(id)||Array.isArray(menu.tabs)&&menu.tabs.includes(id));
      const path=(parent?.label||group)+' / '+label;
      if(normalize(label)===wanted||normalize(path)===wanted)matches.set(id,path);
    }
    if(matches.size===1)return matches.keys().next().value;
    if(matches.size>1)throw Error('The view name "'+value+'" is ambiguous. Choose '+[...matches].map(([id,label])=>label+' ['+id+']').join(', ')+'.');
    throw Error('Unknown Boxer view "'+value+'". Search list_actions for an exact tab ID or a full menu / view label.');
  }
  function create(options){
    const doc=options.document||root.document,state=options.state;
    if(!doc||!state)throw Error('Boxer assistant requires the active app state.');
    const win=doc.defaultView,fetcher=options.fetch||win.fetch.bind(win);
    let destroyed=false,currentOperation=null,operationSequence=0,commands=null,chat=null;
    let cachedReport=null,cachedRows=null,rfSummary=null,rfRows=[];
    const revision=()=>[state.studyEpoch,state.studyRevision,state.studyViewRevision].map(value=>value||0).join('/');
    const ready=()=>state.autoMeshReady&&!state.loadingInput;
    const busy=()=>!!(state.workspaceBusy||state.busy||state.exportBusy||state.meshRequestInFlight||state.solverStarting||state.polling||state.sensitivityBusy||state.rfSensitivityBusy||state.autosaveBusy||state.assistantParameterBusy);
    const editable=()=>ready()&&!busy()&&!state.diskResults&&!state.importedDeck&&!state.newStudyPending&&!state.studyCommentOpen;
    const available=()=>ready()&&!busy()&&!state.newStudyPending&&!state.studyCommentOpen;
    const schema=()=>options.getSchema?.()||state.schema||[];
    const errorText=()=>{const host=doc.getElementById('model-error');return host&&!host.hidden?text(doc.getElementById('model-error-text')?.textContent):'';};
    function rfCache(){
      const report=state.stressReport?.report||null,rows=report?.rows||null;
      if(report===cachedReport&&rows===cachedRows)return;
      cachedReport=report;cachedRows=rows;rfRows=[];rfSummary=null;
      if(!report||!Array.isArray(rows))return;
      let assessed=0,below=0,minimum=null;
      for(const row of rows){
        const rf=number(row.reserveFactor);if(rf!==null){assessed++;if(rf<1)below++;if(minimum===null||rf<minimum)minimum=rf;}
        rfRows.push({property_id:row.pid,label:text(row.label,150),names:(Array.isArray(row.names)?row.names:[]).slice(0,5).map(name=>text(name,150)),
          reserve_factor:rf,complete:row.complete===true,status:row.status||'',
          critical_case:text(row.combined?.governingCase||row.envelopeCaseLabel,220),
          failure_mode:text(row.combined?.governingModeLabel||row.failureMode||report.failureMode,150),
          reason:text(row.reserveFactorReason,600)});
      }
      rfSummary={assessment:report.failureMode||'unknown',properties:rows.length,assessed,unassessed:rows.length-assessed,
        below_one:below,minimum,estimated:!!report.estimated,stale:!!report.stale,pending:!!state.stressReport?.pending};
    }
    function rfState(){
      rfCache();if(!rfSummary)return null;
      const retained=!!state.modelDirty&&!!state.resultCases?.size,estimated=!!cachedReport.estimated;
      const source=cachedReport.source;
      return{...rfSummary,estimated:estimated||retained,stale:!!cachedReport.stale||retained&&!estimated,
        assessed_at_edited_properties:estimated,analysis_out_of_sync:!!state.modelDirty,
        source_basis:estimated?'fixed_internal_load_estimate':retained?'retained_previous_analysis':'analysis_assessment',
        ...(source?{source:{study_epoch:source.studyEpoch??null,captured_at:source.capturedAt??null,mesh_identity:text(source.meshIdentity,160)}}:{}),
        pending:!!state.stressReport?.pending};
    }
    function parameterSnapshot(){
      const values={};
      if(state.importedDeck||state.diskResults)return values;
      for(const key of ['planform.area','planform.aspect_ratio','planform.taper','planform.sweep','planform.dihedral','planform.twist_tip','box.front_spar_xc','box.rear_spar_xc','box.rib_pitch','box.stringer_pitch','output.solution','output.n_modes','properties.t_skin_upper','properties.t_skin_lower','properties.t_spar_web','properties.t_rib_web']){
        const input=doc.getElementById('p-'+key);if(!input)continue;
        if(input.type==='checkbox')values[key]=input.checked;
        else if(input.type==='number'){const value=root.WingParameterUnits?.readModel(input,key)??Number(input.value);values[key]=Number.isFinite(value)?value:null;}
        else values[key]=text(input.value,150);
      }
      return values;
    }
    function snapshot(){
      rfCache();
      const cases=[];
      for(const [id,value]of state.resultCases||[]){
        if(cases.length>=100)break;
        cases.push({id,label:text(value.label||value.caseLabel||'Case '+id,180),available:value.available!==false,
          status:value.status||'',solution:value.solution||value.sol||null});
      }
      const progress=state.solverProgress||{};
      let importedAnalysis=null;
      if(state.importedDeck&&root.WingImportedAnalysis){try{importedAnalysis={solution:root.WingImportedAnalysis.solution(state.importedDeck),settings:root.WingImportedAnalysis.options(state.importedDeck.source?.analysis)};}catch(error){importedAnalysis={error:text(error.message,400)};}}
      const selectedNode=Number.isInteger(state.selectedNode)&&state.selectedNode>=0?state.nodeIds?.[state.selectedNode]:null;
      const operation=currentOperation?{...currentOperation,seconds:Math.round(((currentOperation.finished_at||Date.now())-currentOperation.started_at)/1000)}:null;
      return{application:'JFEM-Boxer',revision:revision(),mode:state.diskResults?'stored_results':state.importedDeck?'imported_deck':ready()?'generated_study':'starting',
        study:{title:text(state.importedDeck?.source?.name||state.importedDeck?.name||state.diskResults?.name||doc.getElementById('p-output.title')?.value||state.values?.['output.title']||'New Study',200),
          name:text(state.studyFile,240),path:text(state.studyFileHandle?.path,1600),epoch:state.studyEpoch||0,revision:state.studyRevision||0,unsaved:!!state.studyDirty,
          model_out_of_date:!!state.modelDirty,ready:ready()},
        workspace:options.getWorkspace?.()||{},parameters:parameterSnapshot(),
        busy:{file:!!state.workspaceBusy,mesh:!!state.meshRequestInFlight,solver:!!(state.solverStarting||state.polling),
          aerodynamic:!!state.aerodynamicStudy?.busy,sensitivity:!!(state.sensitivityBusy||state.rfSensitivityBusy),
          reserve_factors:!!state.stressReport?.pending,parameter_update:!!state.assistantParameterBusy},
        mesh:{available:!!state.data,nodes:state.data?.nodes?.count||0,elements:state.elements?.size||0,groups:state.data?.groups?.length||0,units:state.importedDeck||state.diskResults?'source_model_units':'m'},
        analysis:{job_id:state.jobId||null,epoch:state.analysisEpoch||0,starting:!!state.solverStarting,running:!!state.polling,
          stage:text(progress.stage||progress.stage_category,150),message:text(progress.message,700),...(importedAnalysis?{imported:importedAnalysis}:{})},
        results:{available:!!state.results||!!state.resultCases?.size,cases,total_cases:state.resultCases?.size||0,active_case:state.activeCase||1,active_mode:state.activeMode},
        aerodynamics:{available:!!state.aerodynamicStudy,result_cases:state.aerodynamicStudy?.result?.cases?.length||0,busy:!!state.aerodynamicStudy?.busy},
        selection:{element_id:state.selectedElement??null,node_id:selectedNode??null,coordinate_id:state.selectedCoordinate??null},
        reserve_factors:rfState(),
        rf_field:{active:!!state.rfField},current_command:operation,
        notice:text(doc.getElementById('mesh-status')?.textContent,700),error:errorText()};
    }
    async function request(path,body){
      const response=await fetcher(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),cache:'no-store'});
      const value=await response.json();if(!response.ok||value.ok===false)throw Error(value.error||value.message||'The Boxer request failed.');return value;
    }
    function track(name,run,{dispatchOnly=false,waiting=false}={}){
      const id='assistant_'+Date.now().toString(36)+'_'+(++operationSequence);
      const operation={id,name,state:waiting?'waiting_for_user':'running',started_at:Date.now(),message:'Requested through the existing Boxer workflow.'};
      currentOperation=operation;
      // Launching a menu action must not hold the broker heartbeat while a file
      // dialog, native compilation or a numerical job is pending.
      Promise.resolve().then(run).then(value=>{
        operation.state=value===false?'not_completed':dispatchOnly?'dispatched':'completed';
        operation.message=value===false?'The operation was cancelled or prevented. Review Boxer’s current notice and error.':dispatchOnly?'The action has been dispatched. Solver and aerodynamic job fields report numerical completion.':'The menu operation finished.';
      }).catch(error=>{operation.state='failed';operation.message=text(error.message,1200);options.log?.('Assistant '+name+': '+error.message,'err');})
        .finally(()=>{operation.finished_at=Date.now();commands?.refresh();chat?.refresh();});
      return{status:waiting?'waiting_for_user':'started',command_id:id,message:waiting?'Complete or cancel the existing Boxer dialog.':'The request has started. Read get_state.current_command and the native job status for progress.'};
    }
    async function confirmReplacement(){
      if(!state.autoMeshReady||!state.studyDirty&&!options.hasDrafts?.())return true;
      const choice=await options.confirmReplacement();
      if(choice===null)return false;
      if(choice==='save')return !!(await options.requestStudySave())&&!state.studyDirty&&!options.hasDrafts?.();
      return choice==='discard';
    }
    async function openStudy(args){
      if(!args.path){doc.getElementById('btn-load-model')?.click();return true;}
      if(typeof args.path!=='string'||!args.path.trim())throw Error('Provide the complete path to a saved Boxer Study.');
      const epoch=state.studyEpoch;
      const reply=await request('/api/chat/open_study',{path:args.path});
      const file=await options.nativeFile(reply.handle);
      if(state.studyEpoch!==epoch||!available())throw Error('The active Study or operation changed while the requested file was being prepared. Request opening it again.');
      state.newStudyPending=true;state.autosave?.changed();
      try{
        if(!await confirmReplacement())return false;
        return await options.loadModelDefinition(file,{handle:reply.handle});
      }finally{state.newStudyPending=false;state.autosave?.changed();}
    }
    async function readDeck(args,format){
      if(!args.path){doc.getElementById(format==='abaqus'?'btn-read-abaqus':'btn-read-reference')?.click();return true;}
      if(typeof args.path!=='string'||!args.path.trim())throw Error('Provide the path to the finite-element input file.');
      state.newStudyPending=true;state.autosave?.changed();
      try{
        if(!await confirmReplacement())return false;
        return await options.loadReferenceSource({path:args.path,format});
      }finally{state.newStudyPending=false;state.autosave?.changed();}
    }
    async function updateParameters(values){
      if(!editable())throw Error('Finish the active operation and open an editable generated Study before changing model parameters.');
      if(options.hasDrafts?.())throw Error('Apply or cancel the current property/minimum-gauge draft before requesting another parameter update.');
      const known=new Set(schema().map(spec=>spec.key));
      const requested=Object.keys(values);
      for(const key of requested){
        if(!known.has(key))throw Error('Unknown Study parameter '+key+'. Search list_inputs for its canonical key.');
        if(state.parameterLocks?.isLocked(key))throw Error('Parameter '+key+' is locked. Unlock its form before editing it.');
      }
      const before=clone(options.readParameters()),epoch=state.studyEpoch,studyRevision=state.studyRevision,signature=JSON.stringify(before);
      const candidate={...clone(before),...clone(values)},changes=[];
      const minima=root.WingMinimumGaugeInputs;
      function applyMinimum(update){if(!update)return;Object.assign(candidate,update.patches||{});changes.push(...update.changes||[]);}
      for(const key of requested)if(minima?.isMinimumKey(key))applyMinimum(minima.reconcileMinimumEdit(candidate,key));
      if(requested.includes('materials.shells')){
        const assignments=Array.isArray(candidate['materials.shells'])?candidate['materials.shells']:JSON.parse(candidate['materials.shells']||'[]');
        for(const component of new Set(assignments.map(row=>row.component).filter(Boolean)))applyMinimum(minima?.reconcileMaterialMinimumEdit(candidate,component));
      }
      const patch=Object.fromEntries(Object.keys(candidate).filter(key=>known.has(key)&&JSON.stringify(candidate[key])!==JSON.stringify(before[key])).map(key=>[key,candidate[key]]));
      if(!Object.keys(patch).length)return{atomic:true,changed:[],message:'The requested values already match the Study.'};
      state.assistantParameterBusy=true;
      commands?.refresh();
      try{
        const validated=await request('/api/chat/validate',{parameters:before,values:patch});
        if(destroyed||state.studyEpoch!==epoch||state.studyRevision!==studyRevision||JSON.stringify(options.readParameters())!==signature)
          throw Error('The Study changed during validation. No assistant update was applied. Read the current state and request the edit again.');
        if(state.busy||state.workspaceBusy||state.exportBusy||state.polling||state.meshRequestInFlight||state.solverStarting||state.sensitivityBusy||state.rfSensitivityBusy||state.autosaveBusy)
          throw Error('A model or analysis operation started during validation. No assistant update was applied.');
        const accepted=validated.values;
        if(!accepted||typeof accepted!=='object'||Array.isArray(accepted))throw Error('The server returned no validated Study values. Restart Boxer and retry.');
        const previousValues=state.values,previousCases=state.loadCases,previousEditing=state.editingCase;
        const previousAuto=state.autoMeshReady,previousRestoring=state.studyRestoring;
        const dirtyBefore=state.studyDirty,revisionBefore=state.studyRevision;
        state.autoMeshReady=false;state.studyRestoring=true;
        try{
          state.values={...clone(before),...clone(accepted)};options.buildForm(schema(),state.values);
          options.readParameters();
        }catch(error){
          state.values=previousValues;options.buildForm(schema(),before);state.loadCases=previousCases;state.editingCase=previousEditing;
          state.studyDirty=dirtyBefore;state.studyRevision=revisionBefore;
          throw Error('The edited form could not be accepted; the previous Study was restored. '+error.message);
        }finally{state.autoMeshReady=previousAuto;state.studyRestoring=previousRestoring;}
        const actual=options.readParameters();
        const changed=Object.keys(actual).filter(key=>known.has(key)&&JSON.stringify(actual[key])!==JSON.stringify(before[key]));
        for(const key of changed)options.parameterEdited(key);
        if(changes.length)options.log?.('Assistant update raised '+changes.length+' local dimensions to the new minimum gauges. Larger dimensions were retained.','good');
        options.log?.('Assistant updated '+changed.length+' Study parameter(s) in canonical units. Normal mesh, preview and fixed-load RF update rules apply.','good');
        commands?.refresh();chat?.refresh();
        return{atomic:true,changed,minimum_gauge_changes:changes.length,warnings:validated.warnings||[],analysis_started:false};
      }finally{state.assistantParameterBusy=false;commands?.refresh();}
    }
    function identify(args,kind){
      const id=Number(args.id);if(!Number.isInteger(id)||id<=0)throw Error('Provide a positive integer '+(kind==='node'?'GRID':'element')+' ID.');
      if(kind==='node'){
        const index=state.nodeIds?.indexOf(id)??-1;if(index<0)throw Error('GRID '+id+' is not present in the displayed FEM.');
        options.navigate('inspect');doc.getElementById('inspect-entity').value='nodes';options.inspectFilterChanged();options.showNode(index);
      }else{
        if(!state.elements?.has(id))throw Error('Element '+id+' is not present in the displayed FEM.');
        options.navigate('inspect');doc.getElementById('inspect-entity').value='all';options.inspectFilterChanged();options.showElement(id,{assess:false});
      }
      return{status:'completed',selected:{type:kind,id},rf_calculation_started:false};
    }
    function inspect(args){
      const kinds=['element_id','node_id','property_id'].filter(key=>args[key]!==undefined&&args[key]!==null);
      if(kinds.length!==1)throw Error('Choose exactly one element_id, node_id or property_id to inspect.');
      if(kinds[0]==='element_id')return identify({id:args.element_id},'element');
      if(kinds[0]==='node_id')return identify({id:args.node_id},'node');
      const pid=Number(args.property_id);
      if(!Number.isInteger(pid)||pid<=0)throw Error('Provide a positive integer property_id.');
      let first=null,count=0;const ids=[];
      for(const [id,element]of state.elements||[]){
        const actual=Number(element.group?.pid??element.properties?.pid??element.group?.properties?.pid);
        if(actual!==pid)continue;
        if(first===null)first=id;count++;if(ids.length<200)ids.push(id);
      }
      if(first===null)throw Error('Property P'+pid+' has no elements in the displayed FEM.');
      identify({id:first},'element');rfCache();
      return{status:'completed',selected:{type:'property',id:pid,element_id:first},member_count:count,member_element_ids:ids,
        member_ids_truncated:count>ids.length,cached_rf:rfRows.find(row=>Number(row.property_id)===pid)||null,
        rf_calculation_started:false,message:'Inspected the first member element; Boxer applies its normal property-region highlight. RF information is read only from the cached report.'};
    }
    function readRF(args={}){
      rfCache();const offset=Math.max(0,Math.trunc(Number(args.offset)||0)),limit=Math.min(200,Math.max(1,Math.trunc(Number(args.limit)||40)));
      const rows=args.only_below_one?rfRows.filter(row=>row.reserve_factor!==null&&row.reserve_factor<1):rfRows;
      return{status:'completed',available:!!cachedReport,assessment:cachedReport?.failureMode||null,summary:rfState(),
        offset,limit,total:rows.length,rows:rows.slice(offset,offset+limit),recalculated:false,
        message:cachedReport?'These are the currently cached report values. Their assessment, estimated and stale flags are included.':'No cached RF report is available. Open Stress Report and request an assessment to calculate one.'};
    }
    function readPanel(args={}){
      const workspace=options.getWorkspace?.()||{},active=workspace.active_tab;
      const offset=Math.max(0,Math.trunc(Number(args.offset)||0)),limit=Math.min(100,Math.max(1,Math.trunc(Number(args.limit)||40)));
      const textOffset=Math.min(1000000,Math.max(0,Math.trunc(Number(args.text_offset)||0))),maxChars=Math.min(20000,Math.max(200,Math.trunc(Number(args.max_chars)||12000)));
      const privateSelector='[data-boxer-private],.boxer-chat,#boxer-chat,#boxer-chat-toggle,input[type="password"],script,style,[hidden],[aria-hidden="true"]';
      const rendered=node=>!node.closest(privateSelector)&&node.getClientRects().length>0&&win.getComputedStyle(node).visibility!=='hidden';
      const panels=Array.from(doc.querySelectorAll('#workspace-content [data-workspace-panel]')).filter(node=>node.dataset.workspacePanel===active&&rendered(node));
      const sanitize=value=>String(value).replace(/(?:data|blob):[^\s]+/gi,'[embedded content]').replace(/[ \t]+/g,' ').trim();
      function visibleText(host,cap){
        // Walk only rendered text. Reading textContent (or a detached clone's
        // innerText) would expose hidden forms, credentials and closed details.
        const walker=doc.createTreeWalker(host,win.NodeFilter.SHOW_ELEMENT|win.NodeFilter.SHOW_TEXT,{acceptNode(node){
          if(node.nodeType===1)return rendered(node)?win.NodeFilter.FILTER_SKIP:win.NodeFilter.FILTER_REJECT;
          if(!node.parentElement||!rendered(node.parentElement))return win.NodeFilter.FILTER_REJECT;
          const details=node.parentElement.closest('details:not([open])');
          return details&&!details.querySelector(':scope > summary')?.contains(node)?win.NodeFilter.FILTER_REJECT:win.NodeFilter.FILTER_ACCEPT;
        }});
        let output='',node;
        while((node=walker.nextNode())&&output.length<cap){const value=sanitize(node.nodeValue);if(value)output+=(output?'\n':'')+value;}
        return output.slice(0,cap);
      }
      let content='',tableBudget=80000;const tables=[];
      for(const panel of panels){
        if(content.length<textOffset+maxChars+1)content+=(content?'\n\n':'')+visibleText(panel,textOffset+maxChars+1-content.length);
        for(const table of panel.querySelectorAll('table')){
          if(!rendered(table)||tables.length>=12||tableBudget<=0)continue;
          const allRows=Array.from(table.rows).filter(rendered),headRows=allRows.filter(row=>row.parentElement.tagName==='THEAD');
          const bodyRows=allRows.filter(row=>!headRows.includes(row)&&row.querySelector('td'));
          const headers=(headRows.length?Array.from(headRows.at(-1).cells):Array.from(allRows[0]?.cells||[]).filter(cell=>cell.tagName==='TH')).slice(0,30).map(cell=>visibleText(cell,250));
          const rows=[];
          for(const row of bodyRows.slice(offset,offset+limit)){
            if(tableBudget<=0)break;
            const values=[];
            for(const cell of Array.from(row.cells).slice(0,30)){if(tableBudget<=0)break;const value=visibleText(cell,Math.min(350,tableBudget));tableBudget-=value.length;values.push(value);}
            rows.push(values);
          }
          tables.push({caption:sanitize(table.caption?.innerText||table.getAttribute('aria-label')||'').slice(0,250),headers,offset,limit,total_rows:bodyRows.length,
            rows,truncated:bodyRows.length>offset+rows.length||tableBudget<=0||Array.from(allRows[0]?.cells||[]).length>30});
        }
      }
      return{status:'completed',available:panels.length>0,workspace,title:text(workspace.title||active||'Current view',240),
        text:content.slice(textOffset,textOffset+maxChars),text_offset:textOffset,max_chars:maxChars,text_truncated:content.length>textOffset+maxChars,
        tables,cached:true,model_out_of_date:!!state.modelDirty,results_out_of_sync:!!state.modelDirty&&!!state.resultCases?.size,
        recalculated:false,message:'Read the currently rendered view only. No navigation, FEM generation, analysis or RF assessment was started.'};
    }
    /* Airfoil tools, the same for the chat and for the MCP bridge (web/boxer_airfoil_tools.js). */
    let airfoilTools=null;
    const airfoils=()=>{
      if(!airfoilTools){
        if(!root.WingBoxerAirfoilTools||!root.WingAirfoils)throw Error('The airfoil tools are not available in this page.');
        airfoilTools=root.WingBoxerAirfoilTools.create({fetch:fetcher,airfoils:root.WingAirfoils,readParameters:()=>options.readParameters(),updateParameters,
          inputValue:id=>doc.getElementById(id)?.value,setInput:(id,value)=>commands.execute({command:'set_input',arguments:{input_id:id,value},source:'airfoil-tools'})});
      }
      return airfoilTools;
    };
    // A name that is not a NACA code never reaches the code box: the form would become invalid and block every later change.
    function guardInput(id,value){
      const naca=root.WingBoxerAirfoilTools?.nacaCode;
      if(naca&&/^p-airfoil\.(root|tip)$|^airfoil-station-\d+-code$/.test(id)&&!naca(value))
        throw Error('“'+text(value,60)+'” was not entered: this input takes only a NACA 4- or 5-digit code, and Boxer generates no other section. Look the profile up with the action find_airfoils and apply it with set_airfoil.');
    }
    /* The analysis is started with its solution. The Study's own setting is 103 until someone changes it, and a run
     * that was meant for load cases then returned normal modes (recorded on 2026-11-20). */
    const SOLUTIONS={101:'static analysis',103:'normal modes analysis',105:'buckling analysis',106:'nonlinear static analysis'};
    async function runAnalysis(args={}){
      if(state.importedDeck||state.data?.imported_deck)   // an imported model carries its own solution
        return{...track('run_analysis',options.runJfem,{dispatchOnly:true}),solution:'as defined by the imported model'};
      const wanted=String(args.solution??'').replace(/^sol\s*/i,'').trim();
      let before='';try{before=String(options.readParameters()['output.solution']??'');}catch{}
      if(!wanted)throw Error('State the solution to run: "101" static (load cases, load factors or g cases, stresses, deflections, reserve factors, and any run after load cases were generated or changed), "103" normal modes, "105" buckling, "106" nonlinear static. The Study is set to '+(before||'an unknown solution')+'. Call run_analysis again with “solution”.');
      if(!SOLUTIONS[wanted])throw Error('Unknown solution “'+text(wanted,20)+'”. Use 101, 103, 105 or 106.');
      const changed=before!==wanted;
      if(changed)await updateParameters({'output.solution':wanted});
      /* The launcher returns without a word while Boxer is busy, and a change of the solution makes it busy for a
       * moment (seen on 2026-11-21: the run after the change never started). Wait for it, then make sure it began. */
      const pause=ms=>new Promise(resolve=>win.setTimeout(resolve,ms)),until=Date.now()+120000;
      while(busy()&&Date.now()<until)await pause(250);
      if(busy())throw Error('Boxer is still busy with another operation, so the analysis was not started. Read get_state and call run_analysis again.');
      const launch=Promise.resolve().then(options.runJfem);
      const first=await Promise.race([launch.then(value=>value===true?'launched':'returned',()=>'returned'),pause(2000).then(()=>'working')]);
      // Boxer says why in its error panel or, for a solver that could not be launched, in the last line of its log.
      if(first==='returned'){await pause(500);throw Error('Boxer did not start the analysis. '+(errorText()||text(doc.getElementById('log')?.lastElementChild?.textContent,400)||text(doc.getElementById('mesh-status')?.textContent,300)||'Check the model and call run_analysis again.'));}
      return{...track('run_analysis',()=>launch,{dispatchOnly:true}),solution:wanted,...(changed&&before?{solution_was:before}:{}),study_changed:changed,
        message:'Started the '+SOLUTIONS[wanted]+' (SOL '+wanted+')'+(changed&&before?'; the Study’s Solution was '+before+' and is now '+wanted:'')+'. The run has only been started: Boxer shows its progress, and the Study status says when it has finished.'};
    }
    const objectSchema=properties=>({type:'object',properties,additionalProperties:false});
    const idSchema={...objectSchema({id:{type:'integer',minimum:1}}),required:['id']};
    const actions={
      new_study:{label:'New Study',description:'Open the existing unsaved-change and identification workflow. An optional identification string labels the new Study.',inputSchema:objectSchema({identification:{type:'string',maxLength:240}}),enabled:available,
        run:args=>track('new_study',()=>options.newStudy(args.identification===undefined?{}:{identification:typeof args.identification==='string'?{text:args.identification,visible:false}:args.identification}),{waiting:true})},
      open_study:{label:'Open Study',description:'Open a saved .wingfem.json/.json Study by absolute server path, or open the existing file chooser when no path is supplied. Unsaved changes are protected.',inputSchema:objectSchema({path:{type:'string'}}),enabled:available,
        run:args=>track('open_study',()=>openStudy(args),{waiting:!args.path||!!state.studyDirty})},
      save_study:{label:'Save Study',description:'Use the existing Study notes and file-save workflow. Save as selects a destination.',inputSchema:objectSchema({saveAs:{type:'boolean'}}),enabled:()=>available()&&!state.diskResults,
        run:args=>track('save_study',()=>options.requestStudySave({saveAs:args.saveAs===true}),{waiting:true})},
      read_nastran:{label:'Read Nastran',description:'Import an external Nastran deck with INCLUDE files by server path. Without a path, open the existing import form. Unsaved Study changes are protected.',inputSchema:objectSchema({path:{type:'string'}}),enabled:available,
        run:args=>track('read_nastran',()=>readDeck(args,'reference'),{waiting:!args.path||!!state.studyDirty})},
      read_abaqus:{label:'Read Abaqus',description:'Import an external Abaqus .inp file by server path. Without a path, open the existing import form.',inputSchema:objectSchema({path:{type:'string'}}),enabled:available,
        run:args=>track('read_abaqus',()=>readDeck(args,'abaqus'),{waiting:!args.path||!!state.studyDirty})},
      create_fem:{label:'Create FEM',description:'Generate the physical FEM using the current Study. Preserve the viewport and existing menu validation.',enabled:()=>editable()&&!state.importedDeck,
        run:()=>track('create_fem',()=>options.createFEM({preserveView:true}))},
      run_analysis:{label:'Run in JFEM',aliases:['run analysis','analyze FEM','solve model','run solver','run load cases','run statics','run modes','run buckling'],
        description:'Start the structural analysis of every enabled case with the stated solution; the Study’s Solution is set to it first. 101 static: load cases, load factors, stresses, deflections, reserve factors, and any run after load cases were generated or changed. 103 normal modes. 105 buckling. 106 nonlinear static. Read analysis.running and native progress for completion.',
        inputSchema:{...objectSchema({solution:{type:'string',enum:['101','103','105','106'],description:'101 static, 103 normal modes, 105 buckling, 106 nonlinear static'}}),required:['solution']},await_completion:true,
        enabled:()=>available()&&!state.diskResults,run:runAnalysis},
      find_airfoils:{label:'Find airfoils in the UIUC database',aliases:['find airfoil','search airfoils','uiuc airfoil'],
        description:'Search the UIUC airfoil coordinate database by file name and return the names that match or come nearest. For every section that is not a NACA 4- or 5-digit code. Changes nothing.',
        inputSchema:{...objectSchema({query:{type:'string',description:'Name or a part of it, for example 64a410, sc20714, rae2822, b737'},limit:{type:'integer',minimum:1,maximum:40}}),required:['query']},await_completion:true,
        run:args=>airfoils().find(args)},
      set_airfoil:{label:'Set airfoil',aliases:['set airfoil','change airfoil','airfoil section'],
        description:'Set the airfoil of the root, the tip, both, or an intermediate section. Give exactly one of naca, uiuc or coordinates. Answers with the measured thickness and camber of the section.',
        inputSchema:{...objectSchema({section:{type:'string',description:'root, tip, both, or the eta of an intermediate section between 0 and 1'},naca:{type:'string',description:'NACA 4- or 5-digit code, for example 2412'},
          uiuc:{type:'string',description:'file name from find_airfoils, for example sc20714.dat'},coordinates:{type:'string',description:'x z pairs as fractions of the chord, one pair on each line, from the trailing edge over the upper surface to the leading edge and back'},
          name:{type:'string',description:'name of a profile given by coordinates'},thickness:{type:'string',description:'optional thickness in percent of the chord; scales the section and keeps its camber'}}),required:['section']},await_completion:true,
        enabled:()=>editable()&&!state.importedDeck,run:args=>airfoils().set(args)},
      stop_analysis:{label:'Stop JFEM analysis',description:'Request cancellation of the currently running native JFEM job.',enabled:()=>!!state.jobId&&!!(state.polling||state.solverStarting),
        run:()=>track('stop_analysis',options.stopJfem,{dispatchOnly:true})},
      run_aerodynamics:{label:'Run aerodynamics',description:'Run the current independent aerodynamic conditions. The existing derivative-sweep warning remains active.',enabled:()=>editable()&&!state.aerodynamicStudy?.busy,
        run:()=>{options.installAerodynamicStudy();options.navigate('aerostudy');return track('run_aerodynamics',()=>state.aerodynamicStudy.run(false));}},
      preview_vlm_mesh:{label:'Preview VLM mesh',description:'Preview the current aerodynamic mesh without running the FE solver.',enabled:()=>editable()&&!state.aerodynamicStudy?.busy,
        run:()=>{options.installAerodynamicStudy();options.navigate('aerostudy');return track('preview_vlm_mesh',()=>state.aerodynamicStudy.run(true));}},
      stop_aerodynamics:{label:'Stop aerodynamics',description:'Cancel the current independent aerodynamic job.',enabled:()=>!!state.aerodynamicStudy?.busy,
        run:()=>track('stop_aerodynamics',()=>state.aerodynamicStudy.cancel(),{dispatchOnly:true})},
      export_solidcraft:{label:'Create in SolidCraft',description:'Export the current generated Study using the existing native CAD options. Read native export status in its form.',enabled:()=>ready()&&!state.diskResults&&!state.importedDeck&&!state.solidcraftExport?.busy&&!state.workspaceBusy,
        run:()=>track('export_solidcraft',()=>state.solidcraftExport.start())},
      fit_view:{label:'Fit 3D view',description:'Fit the displayed FEM/geometry in the existing 3D viewport.',enabled:()=>!!state.camera,
        run:()=>{options.fitView();return{status:'completed'};}},
      inspect_element:{label:'Inspect element',description:'Inspect an element by ID using cached results. This does not start an RF calculation.',inputSchema:idSchema,enabled:()=>!!state.data,
        run:args=>identify(args,'element')},
      inspect_node:{label:'Inspect GRID node',description:'Inspect a GRID by its model ID, not its internal array index.',inputSchema:idSchema,enabled:()=>!!state.data,
        run:args=>identify(args,'node')},
      read_reserve_factors:{label:'Read calculated reserve factors',description:'Read only the cached Stress Report, with its current assessment and stale/estimate flags. Never computes RFs.',inputSchema:objectSchema({offset:{type:'integer',minimum:0},limit:{type:'integer',minimum:1,maximum:200},only_below_one:{type:'boolean'}}),
        run:readRF},
      read_panel:{label:'Read current view',aliases:['read current report','read current panel'],description:'Read the currently visible report, summary, form or log as bounded text and paged tables. Navigate to a view first. Reads cached content and starts no calculations.',inputSchema:objectSchema({offset:{type:'integer',minimum:0},limit:{type:'integer',minimum:1,maximum:100},text_offset:{type:'integer',minimum:0},max_chars:{type:'integer',minimum:200,maximum:20000}}),
        run:readPanel},
    };
    const inputAliases={
      'p-planform.area':['wing area','planform area','lifting surface area'],
      'p-planform.aspect_ratio':['aspect ratio','wing aspect ratio'],
      'p-planform.taper_ratio':['taper ratio','taper','wing taper'],
      'p-planform.twist_tip':['tip twist','twist','washout'],
      'p-planform.sweep':['sweep','sweep angle','wing sweep'],
      'p-planform.dihedral':['dihedral','dihedral angle'],
      'p-box.rib_pitch':['rib pitch','rib spacing'],
      'p-box.stringer_pitch':['stringer pitch','stringer spacing'],
      'p-properties.t_skin_upper':['upper skin thickness','minimum upper skin thickness'],
      'p-properties.t_skin_lower':['lower skin thickness','minimum lower skin thickness'],
      'p-properties.t_spar_web':['spar web thickness','minimum spar web thickness'],
      'p-properties.t_rib_web':['rib web thickness','minimum rib web thickness'],
      'p-material.E':['young modulus','youngs modulus','elastic modulus'],
      'p-material.nu':['poisson ratio','poissons ratio'],
      'p-material.rho':['density','material density'],
      'p-output.title':['title','model title','study title'],
      'p-output.solution':['solution','solution type','analysis type'],
      'p-output.n_modes':['number of modes','requested modes'],
    };
    commands=root.WingBoxerCommands.create({document:doc,fetch:fetcher,pollMs:options.pollMs,connect:options.connect,inputAliases,
      getSchema:schema,getParameters:options.readParameters,getState:snapshot,actions,updateParameters,guardInput,navigate:target=>{
        const result=options.navigate(target);
        if(result===false)throw Error('Unknown or unavailable Boxer tab '+target+'. Search list_actions for its current name.');
        return typeof result==='string'?result:options.getWorkspace?.().active_tab||target;
      },inspect,log:options.log,onConnection:()=>chat?.refresh(),onState:snapshot=>chat?.refresh(snapshot)});
    /* What the assistant is told about how this application is built. It restates the Help
     * of the Planform and Spars forms and the parameter descriptions; keep it in step with them. */
    const guide=`How this application is organised:
The wing starts from a base trapezoid (area, aspect ratio, taper ratio, sweep). Its outline is then refined with two tables of perturbation points, planform.leading_edge_points and planform.trailing_edge_points. Each is a list of points {"eta": spanwise position from 0 at the root to 1 at the tip, "dxc": chordwise offset as a fraction of the local base chord, positive aft}. Straight segments join the points. An end that is not listed has zero offset. Each eta may appear only once, and the root and tip rows stay at eta 0 and 1; only their dxc can change. The forms number the rows from the root: point 1 is the root row at eta 0 and the last point is the tip row, so "point 1 eta" cannot be changed; say so instead of moving another point.
To add, move or remove a point, call update_parameters with the complete new list. Example, a trailing-edge kink (also called Yehudi, crank, or the triangle at the root): {"planform.trailing_edge_points":[{"eta":0,"dxc":0.3},{"eta":0.35,"dxc":0}]} extends the root chord aft by 30 % and returns to the base trailing edge at 35 % of the semispan, where the kink is. A leading-edge extension is the same with planform.leading_edge_points and a negative dxc at the root.
The front and rear spar paths use box.front_spar_points and box.rear_spar_points in the same form, measured from the nominal spar positions. Both spars must stay inside the refined outline, the front ahead of the rear; Boxer refuses a list that breaks this and says why.
Engines are one table, engines.items (form Engines): a list of {"name", "enabled", "x", "y", "z", "mass", "length", "front_rib", "aft_rib", "aft_xc", "E", "G", "A", "I1", "I2", "J"}. x, y and z are the engine's centre of gravity in metres in the model axes (x aft, y along the span, z up, so an engine hung under the wing lies below it), mass is in kg and length in m, front_rib and aft_rib are the numbers of the ribs that carry it and are best left out: Boxer then attaches the engine to the rib in line with it, the one nearest its y (0 means the same; give a number only when the user names a rib), aft_xc is the chordwise position of the aft attachment, and E, G, A, I1, I2, J describe the pylon beam in SI units. There are no other fields: no thrust, diameter, pylon or type. Fields that are left out keep their default values, so {"name":"Engine 1","x":...,"y":...,"z":...,"mass":...,"length":...} is a complete engine. Send the whole list, with the existing engines that are to stay.
Load cases: load case 1 is defined by the keys of the Loads form (loads.label is its name, loads.load_factor its limit load multiplier, loads.lift_total, loads.method and the others). Further cases are one table, loads.cases: a list of {"label", "enabled"} with any of "load_factor", "lift_total", "method", "distribution", "aircraft_mass", "maneuver_factor", "match_aircraft_lift", "torque_y", "speed", "density", "alpha", "altitude", "fuel_percent", "structure_inertia", "engine_thrust", "follower_forces", "fuel_accel_x", "fuel_accel_y", "fuel_accel_z". A field that is left out is taken from load case 1, and there are no other fields. A manoeuvre of n g is a case whose load_factor is n, negative for a push-over. Send the whole list. Load cases are run with run_analysis and solution 101.
Thrust is a separate table for load case 1, loads.engine_thrust: a list of {"engine": the name of a defined engine, "thrust_n": newtons, positive forward}.
Airfoils (form Airfoils) are defined at the root (eta 0), at the tip (eta 1) and optionally at intermediate sections, and are set with set_airfoil. A section has one of three sources. "naca": a NACA 4- or 5-digit code such as 2412 or 23012, which Boxer generates; the code input accepts nothing else. "uiuc": coordinates from the UIUC airfoil database, found by file name with find_airfoils. "coordinates": points typed into set_airfoil. A NACA 6-series, supercritical, laminar or aircraft section is therefore never typed as a code: look it up.
UIUC file names: NACA 6-series naca642415 (NACA 64(2)-415: design lift 0.4, 15 % thick), naca64a410, naca651412, naca63a210, and the shorter n63415, n64212; NASA supercritical sc20714 (SC(2)-0714: the first two digits are the design lift coefficient in tenths, the last two the thickness in percent, so sc20012 is symmetric and a transport wing takes 04 to 07), sc20612, sc20410, and whitcomb; rae2822, rae5212; NASA low- and medium-speed ls417, ms317; laminar nlf0115, nlf414f; transport wings from root to tip b737a to b737d, b707a to b707e, kc135a to kc135d, c5a to c5e, c141a to c141f. Search with the distinctive part of the name. When the exact profile is missing, take the nearest of the same family and camber and pass the thickness asked for to set_airfoil, which scales the section and keeps its camber: a NACA 64A415 is {"section":"root","uiuc":"naca64a410.dat","thickness":"15"}. The scaling is kept in the table loft.thickness_stations, a list of {"eta", "tc"} with tc the thickness over chord; one row alone applies to the whole span, so leave that table to set_airfoil unless the user asks for a thickness distribution. Type coordinates only when you know them reliably, such as values the user gave; do not invent them.
The planform drawing is part of the Planform form and follows a parameter change at once; there is nothing to refresh. If the user cannot see a change, read the list back with list_inputs and report its values, then offer to open the Planform form (find it with list_actions). Never suggest resizing, zooming, reloading or waiting. The mesh follows by itself when Live mesh is on; otherwise it is rebuilt with Create FEM, which you start only when the user asks.`;
    chat=root.WingBoxerChat?.create({document:doc,commands,fetch:fetcher,guide});
    const controller={commands,chat,execute:request=>commands.execute(request),snapshot,updateParameters,readReserveFactors:readRF,readPanel,
      refresh(){commands.refresh();chat?.refresh();},destroy(){if(destroyed)return;destroyed=true;chat?.destroy();commands.destroy();}};
    return controller;
  }
  return{create,resolveNavigation};
});
