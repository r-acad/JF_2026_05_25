/* Server-authoritative panel studies. Geometry, loads, supports and numerical
   calculations belong to the shared Julia service; this file presents them. */
(function(root,factory){'use strict';const api=factory(root);if(typeof module==='object'&&module.exports)module.exports=api;root.PandeatorWorkflow=api;})(typeof window!=='undefined'?window:globalThis,function(root){
 'use strict';
 const finite=value=>typeof value==='number'&&Number.isFinite(value);
 const list=value=>Array.isArray(value)?value:[];
 const label=value=>value===null||value===undefined?'':String(value);
 const fmt=value=>finite(value)?(value===0?'0':Number(value.toPrecision(5)).toString()):'—';
 const variableId=value=>typeof value==='string'?value:label(value.id);
 function fdSteps(text){const values=String(text).split(/[\s,;]+/).filter(Boolean).map(Number);if(!values.length||values.length>5||values.some(v=>!finite(v)||v<=0||v>=.1))throw Error('Use one to five finite-difference relative steps greater than 0 and smaller than 0.1.');if(new Set(values).size!==values.length)throw Error('Finite-difference steps must be distinct.');return values;}
 function csvCell(value){const text=label(value);return /[",\r\n]/.test(text)?'"'+text.replace(/"/g,'""')+'"':text;}
 function rowsCSV(rows,columns){return columns.map(c=>csvCell(c[0])).join(',')+'\r\n'+rows.map(row=>columns.map(c=>csvCell(typeof c[1]==='function'?c[1](row):row[c[1]])).join(',')).join('\r\n')+'\r\n';}
 function resultRows(result){return list(result?.responses||result?.analytical?.responses);}
 function sensitivityRows(result){return list(result?.sensitivities||result?.derivatives);}
 function validationRows(result){return list(result?.validation||result?.finite_differences);}
 function install({document,host,view,getParams,getMode,serverBase,protocol,applyModel,applyAnalysis,onStatus,onBusy,onInvalidate,onResize,onReady}){
  const el=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;};
  const button=(text,title)=>{const b=el('button',text,'panel-secondary');b.type='button';if(title)b.title=title;return b;};
  const section=el('section',undefined,'panel-study-controls');section.id='panel-study-controls';
  section.innerHTML='<h2>Analytical buckling and adjoints</h2><p class="panel-help">Uses the solved preload and the same physical skin, flange and web as SOL 105. Dimensions are varied on a fixed mesh.</p><div class="panel-study-checks"><label><input type="checkbox" id="panel-include-sol105" checked> SOL 105 eigenvalues</label><label><input type="checkbox" id="panel-include-analytical" checked> Analytical reserve factors</label></div><label for="panel-derivative-modes">Buckling modes for derivatives</label><input type="number" id="panel-derivative-modes" min="1" step="1" value="3" title="Differentiate this many lowest SOL 105 branches, up to Modes to extract. Mode matching and clusters are reported with the validation."><fieldset class="panel-variable-fields"><legend>Sizing dimensions</legend><div id="panel-variable-list"></div></fieldset><label for="panel-fd-steps">Finite-difference relative steps</label><input type="text" id="panel-fd-steps" value="0.001, 0.0005" title="Each relative step runs positive and negative perturbed forward solves for each selected dimension. Two steps check stability as the step is reduced."><label for="panel-fd-tolerance">Validation tolerance (%)</label><input type="number" id="panel-fd-tolerance" value="0.5" min="0.000001" max="100" step="any" title="Both adjoint agreement and the finite-difference step-refinement check must satisfy this tolerance."><p id="panel-fd-estimate" class="panel-help"></p><div class="panel-action-grid"><button type="button" id="panel-analytical">Analytical buckling</button><button type="button" id="panel-sensitivities">Compute adjoints</button><button type="button" id="panel-validate">Validate with FD</button><button type="button" id="panel-cancel" disabled>Cancel calculation</button></div><div class="panel-workflow-error" id="panel-workflow-error" hidden role="alert"><button type="button" aria-label="Close calculation message">Close</button><span></span></div><details id="panel-model-details"><summary>Mesh, flange and supports</summary><div id="panel-model-report"></div></details><details id="panel-job-details"><summary>Calculation log</summary><pre id="panel-job-log" aria-live="polite"></pre></details>';
  const jobState=el('div','No calculation running.','panel-job-state');jobState.id='panel-job-state';jobState.setAttribute('role','status');section.insertBefore(jobState,section.querySelector('.panel-action-grid'));host.append(section);
  const $=id=>document.getElementById(id),variableList=$('panel-variable-list'),logBox=$('panel-job-log');
  $('panel-include-sol105').title='Include SOL 105 in Compute adjoints and Validate with FD. Run analysis always solves SOL 105 with all modes requested above.';
  $('panel-include-analytical').title='Include elementary analytical reserve factors in Compute adjoints and Validate with FD. Run analysis and Analytical buckling include these factors.';
  $('panel-analytical').title='Solve only the static preload and analytical buckling criteria. No FE buckling modes or derivatives are requested.';
  $('panel-sensitivities').title='Compute exact adjoint derivatives of the selected response methods with respect to the checked sizing dimensions. No perturbed forward solves.';
  $('panel-validate').title='Validate adjoint derivatives with independent positive and negative forward perturbations at each specified relative step.';
  const resultHost=el('section',undefined,'panel-study-results');resultHost.id='panel-study-results';resultHost.hidden=true;
  resultHost.innerHTML='<div class="panel-results-header"><strong>Panel calculation results</strong><span id="panel-result-validity"></span><button type="button" id="panel-results-minimize" title="Collapse the results drawer">Minimize</button><button type="button" id="panel-results-close" title="Hide the results drawer">Close</button></div><div class="panel-results-body"><div class="panel-results-toolbar"><div class="panel-results-tabs" role="tablist"><button type="button" data-result-tab="responses">Buckling factors</button><button type="button" data-result-tab="sensitivities">Adjoint sensitivities</button><button type="button" data-result-tab="validation">Finite-difference validation</button></div><button type="button" id="panel-export-csv">Export CSV</button><button type="button" id="panel-export-json">Export JSON</button></div><p id="panel-result-summary" class="panel-help"></p><div id="panel-result-table" class="panel-table-scroll"></div><details id="panel-result-details"><summary>Methods, assumptions and diagnostics</summary><div></div></details></div>';
  view.append(resultHost);
  let epoch=0,modelCache=null,result=null,resultStamp=null,busy=false,jobId=null,jobOrigin=null,timer=null,lastLogSequence=0,logKeys=new Set(),variables=[],selected=new Set(),activeTab='responses',modeKey=null,destroyed=false,cancelRequested=false,elapsedTimer=null,startedAt=0,progressLabel='Preparing panel calculation';
  const stamp=()=>JSON.stringify(getParams());
  const errorHost=$('panel-workflow-error');errorHost.querySelector('button').onclick=()=>{errorHost.hidden=true;};
  const fail=error=>{const message=error?.message||String(error);errorHost.querySelector('span').textContent=message;errorHost.hidden=false;onStatus?.(message,'err');};
  const status=(text,cls)=>onStatus?.(text,cls);
  function log(message){if(!message)return;const line=String(message);const lines=logBox.textContent?logBox.textContent.split('\n'):[];lines.push(line);logBox.textContent=lines.slice(-500).join('\n');logBox.scrollTop=logBox.scrollHeight;}
  function consumeLogs(data){
   for(const event of list(data.log_events)){
    const seq=Number(event?.sequence);if(Number.isFinite(seq)){if(seq<=lastLogSequence)continue;lastLogSequence=seq;}
    const message=typeof event==='string'?event:event?.message||event?.log_message||event?.detail;
    const key=Number.isFinite(seq)?String(seq):JSON.stringify(event);if(logKeys.has(key))continue;logKeys.add(key);log(message);
   }
   const p=data.progress||{};if(p.detail){const detail=(p.phase?label(p.phase).replace(/_/g,' ')+' · ':'')+p.detail+(finite(p.completed)&&finite(p.total)?' ('+p.completed+'/'+p.total+')':'');progressLabel=detail;status(detail);showElapsed();}
  }
  function showElapsed(){if(!startedAt)return;jobState.textContent=progressLabel+' · '+Math.round((root.performance.now()-startedAt)/1000)+' s elapsed';}
  function beginElapsed(){if(elapsedTimer)root.clearInterval(elapsedTimer);startedAt=root.performance.now();progressLabel='Preparing panel calculation';showElapsed();elapsedTimer=root.setInterval(showElapsed,500);}
  async function request(path,{body,origin,signal}={}){
   const base=(origin||serverBase()).replace(/\/+$/,'');const MP=protocol();
   let response;try{response=await root.fetch(base+path,{method:body===undefined?'GET':'POST',headers:body===undefined?{}:{'Content-Type':'application/msgpack'},body:body===undefined?undefined:MP.encode(body),signal,cache:'no-store'});}catch(error){throw Error('Cannot reach the local PANDEATOR server. Start its launcher, keep it running, and check Server URL. '+error.message);}
   let data;const bytes=new Uint8Array(await response.arrayBuffer());try{data=MP.decode(bytes);}catch(_){throw Error('The local server did not return a PANDEATOR response. Start the current PANDEATOR launcher and check Server URL.');}
   if(!response.ok||data?.ok===false)throw Error(data?.error||'PANDEATOR request failed (HTTP '+response.status+').');return data;
  }
  function setBusy(value){busy=!!value;section.dataset.busy=String(busy);onBusy?.(busy);updateControls();}
  function updateControls(){
   const panel=getMode()==='panel';section.hidden=!panel;
   for(const id of ['panel-analytical','panel-sensitivities','panel-validate'])$(id).disabled=busy||!panel;
   $('panel-cancel').disabled=!busy||!jobId;
   for(const control of section.querySelectorAll('input'))control.disabled=busy||control.dataset.unsupported==='true';
   $('panel-export-csv').disabled=busy||!result;$('panel-export-json').disabled=busy||!result;
  }
  function fallbackVariables(P){const comp=P.material_mode==='composite'||P.material_mode==='comp';return (comp?[
   ['scaleSkin','Skin laminate scale','1'],['scaleWeb','Web laminate scale','1'],['scaleFoot','Attached-flange laminate scale','1']]:[
   ['tSkin','Skin thickness','mm'],['tWeb','Stringer web thickness','mm'],['tFoot','Added attached-flange thickness','mm']]).filter(row=>(P.footW>0||!row[0].endsWith('Foot'))&&(P.bladeH>0||!row[0].endsWith('Web'))).map(([id,label,unit])=>({id,label,unit,value:P[id]}));}
  function updateCatalog(data){
   const P=getParams(),mode=label(P.material_mode||'iso')+(P.footW>0?':flange':':blade')+(P.bladeH>0?':web':':bare');const supplied=list(data?.catalog?.variables||data?.variables);variables=supplied.length?supplied:fallbackVariables(P);
   const nextIds=new Set(variables.filter(v=>v.available!==false&&v.supported!==false).map(variableId));if(mode!==modeKey)selected=new Set(nextIds);else selected=new Set([...selected].filter(id=>nextIds.has(id)));modeKey=mode;
   variableList.replaceChildren();
   for(const variable of variables){const row=el('label',undefined,'panel-variable');const box=el('input');box.type='checkbox';box.value=variableId(variable);box.checked=selected.has(box.value);box.disabled=variable.available===false||variable.supported===false;box.dataset.unsupported=String(box.disabled);
    const text=el('span',(variable.label||box.value)+(finite(variable.value)?' · '+fmt(variable.value)+' '+(variable.unit||''):''));row.append(box,text);if(variable.reason)row.title=variable.reason;
    box.onchange=()=>{if(box.checked)selected.add(box.value);else selected.delete(box.value);updateEstimate();};variableList.append(row);
   }
   updateEstimate();updateControls();
  }
  function updateEstimate(){let steps;try{steps=fdSteps($('panel-fd-steps').value);}catch(error){$('panel-fd-estimate').textContent=error.message;return;}
   $('panel-fd-estimate').textContent=(2*selected.size*steps.length)+' perturbed forward solves plus the baseline for '+selected.size+' selected dimension(s) and '+steps.length+' step size(s). Each method is checked against its own finite-difference solution.';
  }
  $('panel-fd-steps').oninput=updateEstimate;
  function showModelReport(data){
   const target=$('panel-model-report');target.replaceChildren();
   const report=data?.model_report||data?.report||{},boundary=report.boundary,loads=report.loads,notes=[];
   for(const key of ['summary','flange','boundary_conditions','boundary','load_definition','loads','offsets','scope','mesh_philosophy','height_reference']){const value=report[key];if(typeof value==='string')notes.push(value);else if(Array.isArray(value))notes.push(...value.filter(v=>typeof v==='string'));}
   for(const object of [boundary,loads])if(object&&typeof object==='object')for(const key of ['description','component_basis','membrane_note','definition','curvature_note'])if(typeof object[key]==='string')notes.push(object[key]);
   for(const value of list(report.notes))notes.push(typeof value==='string'?value:label(value.message||value.reason));
   const counts=data?.geometry?.counts;if(counts)notes.unshift((counts.nNodes??counts.nodes??list(data.geometry.nodes).length)+' nodes · '+(counts.nQuads??counts.elements??list(data.geometry.quads).length)+' shells');
   if(!notes.length)notes.push('No model notes were supplied by the server. Review the generated deck and support markers.');
   for(const note of [...new Set(notes)])target.append(el('p',note,'panel-help'));
   const warnings=list(data?.warnings).concat(list(report.warnings));for(const warning of [...new Set(warnings.map(value=>typeof value==='string'?value:label(value.message||value.reason)))])if(warning)target.append(el('p',warning,'panel-model-warning'));
   const diagnostics=[],addDiagnostic=(name,value)=>{if(value!==undefined&&value!==null)diagnostics.push({name,value:Array.isArray(value)?'['+value.map(fmt).join(', ')+']':value});};
   if(boundary&&typeof boundary==='object'){addDiagnostic('Rigid-motion rank · physical supports',boundary.physical_rigid_rank);addDiagnostic('Rigid-motion rank · with anchors',boundary.final_rigid_rank);if(Array.isArray(boundary.anchors))addDiagnostic('Minimal rigid-motion anchors',boundary.anchors.length);}
   if(loads&&typeof loads==='object'){addDiagnostic('Total axial end resultant (N)',loads.total_axial_resultant_N);addDiagnostic('Axial section A11 stiffness (N)',loads.axial_section_A11_N);addDiagnostic('Net applied force [x, y, z] (N)',loads.net_force_N);addDiagnostic('Net applied moment [x, y, z] (N·mm)',loads.net_moment_Nmm);}
   addDiagnostic('Maximum shell edge ratio',report.max_edge_ratio);if(diagnostics.length)target.append(columnTable(diagnostics,[['Model diagnostic','name'],['Value','value']]));
   const properties=list(report.properties||data?.geometry?.properties);if(properties.length)target.append(columnTable(properties,[['PID','pid'],['Region',r=>r.label||r.component||({1:'Skin',2:'Stringer web',3:'Combined skin + flange'}[r.pid])||''],['Property','type'],['Total thickness (mm)','thickness']]));
   const mass=report.mass_tonnes??data?.mass_tonnes;if(finite(mass))target.append(el('p','Model mass: '+fmt(mass*1000)+' kg. Each physical layer is counted once.','panel-help'));
   if(boundary||loads||report.supports||report.equilibrium||report.quality||data?.bc_report){const detail=el('details');detail.append(el('summary','Full support, load-balance and mesh diagnostics'));const pre=el('pre');pre.textContent=JSON.stringify({boundary:boundary||report.supports||data.bc_report,loads:loads||report.equilibrium,max_edge_ratio:report.max_edge_ratio,mesh_counts:report.mesh_counts,units:report.units,quality:report.quality},null,2);detail.append(pre);target.append(detail);}
  }
  async function model({apply=true,fit=true}={}){
   if(getMode()!=='panel')throw Error('Choose Build stiffened panel to generate a panel mesh.');const P=getParams(),key=JSON.stringify(P),own=epoch;
   let data=modelCache?.stamp===key?modelCache.data:await request('/panel/model',{body:{params:P}});
   if(destroyed||own!==epoch||stamp()!==key)return null;
   if(!data.geometry||!data.bdf)throw Error('The server returned no panel mesh/deck. Start the current PANDEATOR launcher.');
   modelCache={stamp:key,data};updateCatalog(data);showModelReport(data);if(apply)applyModel(data,{fit});return data;
  }
  async function preview(){if(busy)return null;errorHost.hidden=true;clearResult();onInvalidate?.();setBusy(true);const own=++epoch;try{const data=await model({apply:true,fit:true});if(!data||own!==epoch)return null;status('Panel mesh ready. Review the support markers and combined skin/flange region.','ok');return data;}catch(error){if(own===epoch)fail(error);return null;}finally{if(own===epoch)setBusy(false);}}
  function download(blob,name){const url=root.URL.createObjectURL(blob),link=el('a');link.href=url;link.download=name;link.click();root.setTimeout(()=>root.URL.revokeObjectURL(url),1000);}
  async function downloadBDF(){if(busy)return;errorHost.hidden=true;setBusy(true);const own=++epoch;try{const data=await model({apply:false});if(!data||own!==epoch)return;download(new root.Blob([data.bdf],{type:'text/plain'}),'stiffened_panel.bdf');status('Downloaded the panel analysis deck.','ok');}catch(error){if(own===epoch)fail(error);}finally{if(own===epoch)setBusy(false);}}
  function drawer(open){resultHost.hidden=!open;view.classList.toggle('panel-results-open',!!open);onResize?.();}
  function clearResult(){result=null;resultStamp=null;$('panel-result-table').replaceChildren();$('panel-result-summary').textContent='Current-run results will appear when available.';$('panel-result-details').querySelector('div').replaceChildren();$('panel-result-validity').textContent='';if(!busy)jobState.textContent='No current calculation results.';drawer(false);updateControls();}
  function columnTable(rows,columns){const table=el('table'),head=el('tr');for(const [title,key,help] of columns){const th=el('th',title);if(help)th.title=help;head.append(th);}const thead=el('thead');thead.append(head);table.append(thead);const body=el('tbody');for(const row of rows){const tr=el('tr');for(const [title,key] of columns){const value=typeof key==='function'?key(row):row[key],td=el('td',typeof value==='number'?fmt(value):label(value));if(title==='Status'){td.className='panel-result-status';td.dataset.status=label(row.status||'unavailable');}tr.append(td);}body.append(tr);}table.append(body);return table;}
  function responseName(id){return resultRows(result).find(row=>label(row.id||row.response_id)===label(id))?.label||label(id);}
  function variableName(id){return variables.find(v=>variableId(v)===label(id))?.label||label(id);}
  function matchedMode(value){if(value&&typeof value==='object'){const a=value.minus,b=value.plus;if(a===b)return a==null?'—':label(a);return '− '+(a??'—')+' / + '+(b??'—');}return value;}
  function basisSummary(row){const value=row.governing_mode??row.basis??row.diagnostics?.basis;if(Array.isArray(value))return value.join(' × ');if(value&&typeof value==='object')return JSON.stringify(value);if(value!==null&&value!==undefined)return value;const terms=row.diagnostics?.basis_terms;return finite(terms)&&terms>0?terms+' terms':row.diagnostics?.effective_length_coefficient?'Effective length K = '+fmt(row.diagnostics.effective_length_coefficient):'';}
  const responseColumns=[['Method',row=>row.kind==='sol105'?'SOL 105':row.kind==='analytical'?'Analytical':row.kind||row.method||''],['Response',row=>row.label||row.id],['RF at policy load',row=>row.display_value??row.value,'Reserve factor = raw LIMIT-load buckling factor / buckling policy factor. RF 999 can be a display cap or no-demand sentinel; read Status. Derivatives use the uncapped calculation.'],['Raw LIMIT factor λ',row=>row.raw_lambda??row.raw_load_factor],['Status','status'],['Basis / governing mode',basisSummary]];
  const validationColumns=[['Response',row=>responseName(row.response_id)],['Dimension',row=>variableName(row.variable_id)],['Relative step','step_relative'],['Adjoint',row=>row.adjoint??row.value],['Finite difference','finite_difference'],['Relative error (%)',row=>finite(row.relative_error)?100*row.relative_error:null],['Step change (%)',row=>{const value=row.step_refinement_relative_change??row.step_change??row.refinement_change;return finite(value)?100*value:null;},'Change of the finite-difference derivative as the step is reduced. Both agreement and refinement stability are checked.'],['Absolute error','absolute_error'],['Matched mode',row=>matchedMode(row.matched_mode),'Modes matched independently on the minus and plus perturbed meshes.'],['MAC','mac','Modal Assurance Criterion: sign-independent displacement-shape correlation used to identify the same physical SOL 105 branch.'],['Status','status']];
  function sensitivityTable(rows){
   const byResponse=new Map();for(const response of resultRows(result))byResponse.set(label(response.id||response.response_id),new Map());for(const row of rows){const id=label(row.response_id);if(!byResponse.has(id))byResponse.set(id,new Map());byResponse.get(id).set(label(row.variable_id),row);}
   const selectedIds=new Set(list(result.variables).map(variableId));const vs=variables.filter(v=>selectedIds.has(variableId(v))||rows.some(row=>label(row.variable_id)===variableId(v)));const normalized=$('panel-normalized-values')?.checked??true;
   const table=el('table'),head=el('tr');head.append(el('th','Response'));for(const v of vs){const th=el('th',v.label||v.id);th.title='Derivative with respect to '+(v.label||v.id)+' ('+(v.unit||'1')+'). '+(normalized?'Displayed value is (x / response) × derivative.':'Displayed value uses the derivative units supplied by the solver.');head.append(th);}const th=el('thead');th.append(head);table.append(th);
   let max=0;for(const row of rows){const value=normalized?row.normalized:row.value??row.adjoint;if(finite(value))max=Math.max(max,Math.abs(value));}
   const body=el('tbody');for(const [id,map] of byResponse){const tr=el('tr'),response=resultRows(result).find(r=>label(r.id||r.response_id)===id),name=el('th',responseName(id));if(response?.status&&response.status!=='ok'){name.append(el('span',' · '+response.status.replace(/_/g,' '),'panel-response-note'));name.title=response.note||response.reason||response.status;}tr.append(name);for(const v of vs){const row=map.get(variableId(v)),value=row?(normalized?row.normalized:row.value??row.adjoint):null,td=el('td',fmt(value));
     if(finite(value)){const intensity=.16+.58*(max?Math.min(1,Math.abs(value)/max):0);td.style.backgroundColor=value<0?'rgba(185,52,57,'+intensity+')':value>0?'rgba(36,111,186,'+intensity+')':'#27323d';}
     else td.className='panel-value-unavailable';td.title=row?[row.unit,row.status,row.method,row.reason].filter(Boolean).join(' · '): 'No derivative for this response and dimension.';tr.append(td);}body.append(tr);}table.append(body);return table;
  }
  function renderDetails(){const target=$('panel-result-details').querySelector('div');target.replaceChildren();for(const row of resultRows(result)){const d=el('details'),s=el('summary',row.label||row.id||'Response');d.append(s);if(row.method)d.append(el('p',row.method));for(const note of list(row.assumptions))d.append(el('p',typeof note==='string'?note:JSON.stringify(note)));if(typeof row.assumptions==='string')d.append(el('p',row.assumptions));if(row.note)d.append(el('p',row.note));if(row.reason)d.append(el('p',row.reason));if(row.diagnostics){const pre=el('pre');pre.textContent=JSON.stringify(row.diagnostics,null,2);d.append(pre);}target.append(d);}
   for(const row of validationRows(result)){if(!row.reason&&!row.diagnostics)continue;const detail=el('details');detail.append(el('summary','FD · '+responseName(row.response_id)+' · '+variableName(row.variable_id)+' · h='+fmt(row.step_relative)));if(row.reason)detail.append(el('p',row.reason));if(row.diagnostics){const pre=el('pre');pre.textContent=JSON.stringify(row.diagnostics,null,2);detail.append(pre);}target.append(detail);}
   const common=result?.assumptions||result?.diagnostics;if(common){const pre=el('pre');pre.textContent=JSON.stringify(common,null,2);target.append(pre);}
   if(result.coverage){const coverage=el('details');coverage.append(el('summary','Response and derivative coverage'));const pre=el('pre');pre.textContent=JSON.stringify(result.coverage,null,2);coverage.append(pre);target.append(coverage);}
   const directory=result.output_dir||result.out_dir||result.run_directory;if(typeof directory==='string'){const p=el('p','Saved output folder'),field=el('input');field.type='text';field.readOnly=true;field.value=directory;field.setAttribute('aria-label','Saved calculation folder');const copy=button('Copy path');copy.onclick=async()=>{try{await root.navigator.clipboard.writeText(directory);copy.textContent='Copied';}catch(_){field.focus();field.select();copy.textContent='Selected · Ctrl+C';}};target.append(p,field,copy);}
  }
  function render(){
   if(!result)return;for(const tab of resultHost.querySelectorAll('[data-result-tab]')){tab.classList.toggle('selected',tab.dataset.resultTab===activeTab);tab.setAttribute('aria-selected',String(tab.dataset.resultTab===activeTab));}
   const target=$('panel-result-table');target.replaceChildren();const rows=activeTab==='responses'?resultRows(result):activeTab==='validation'?validationRows(result):sensitivityRows(result);
   if(activeTab==='sensitivities'){const check=el('label',undefined,'panel-normalized-choice');const box=el('input');box.type='checkbox';box.id='panel-normalized-values';box.checked=resultHost.dataset.rawSensitivity!=='true';check.append(box,el('span','Normalized sensitivities · (dimension / response) × derivative'));target.append(check);box.onchange=()=>{resultHost.dataset.rawSensitivity=String(!box.checked);render();};target.append(rows.length?sensitivityTable(rows):el('p','No adjoint sensitivities in this result. Choose sizing dimensions, then Compute adjoints.','panel-help'));}
   else target.append(rows.length?columnTable(rows,activeTab==='responses'?responseColumns:validationColumns):el('p',activeTab==='validation'?'No finite-difference validation in this result. Choose Validate with FD to run independent perturbed solves.':'No buckling factors were returned. Read the calculation log.','panel-help'));
   const statusText=result.status||'complete';$('panel-result-summary').textContent=typeof result.summary==='string'?result.summary:('Calculation '+statusText+'. '+resultRows(result).length+' response(s), '+sensitivityRows(result).length+' derivative(s), '+validationRows(result).length+' finite-difference check(s). Each method retains its own assumptions and recovery diagnostics.');
   $('panel-result-validity').textContent=resultStamp===stamp()?'Current definition':'Inputs changed · recompute';renderDetails();updateControls();
  }
  for(const tab of resultHost.querySelectorAll('[data-result-tab]'))tab.onclick=()=>{activeTab=tab.dataset.resultTab;render();};
  $('panel-results-close').onclick=()=>drawer(false);$('panel-results-minimize').onclick=()=>{resultHost.classList.toggle('collapsed');$('panel-results-minimize').textContent=resultHost.classList.contains('collapsed')?'Expand':'Minimize';view.classList.toggle('panel-results-collapsed',resultHost.classList.contains('collapsed'));onResize?.();};
  $('panel-export-json').title='Export numerical results, inputs and diagnostics. Binary mode files remain separate artifacts.';
  $('panel-export-json').onclick=()=>{if(result)download(new root.Blob([JSON.stringify(result,(key,value)=>value instanceof Uint8Array?{binary_artifact_bytes:value.byteLength}:((key==='jfem_bytes'||key==='bytes')&&Array.isArray(value))?{binary_artifact_bytes:value.length}:value,2)],{type:'application/json'}),'panel-calculation.json');};
  $('panel-export-csv').onclick=()=>{if(!result)return;const columns=activeTab==='validation'?validationColumns:activeTab==='responses'?[...responseColumns,['Uncapped RF','value'],['Buckling policy factor',()=>result.parameters?.buckling_policy_factor??result.diagnostics?.buckling_policy_factor??result.buckling_policy_factor]]:[['Response',r=>responseName(r.response_id)],['Dimension',r=>variableName(r.variable_id)],['Derivative',r=>r.value??r.adjoint],['Normalized','normalized'],['Unit','unit'],['Status','status'],['Method','method']];const rows=activeTab==='validation'?validationRows(result):activeTab==='responses'?resultRows(result):sensitivityRows(result);download(new root.Blob([rowsCSV(rows,columns)],{type:'text/csv;charset=utf-8'}),'panel-'+activeTab+'.csv');};
  function options(operation){
   const derivatives=['sensitivities','validate'].includes(operation),sol105=operation==='analytical'?false:operation==='analyze'?true:$('panel-include-sol105').checked,analytical=['analyze','analytical'].includes(operation)?true:$('panel-include-analytical').checked;
   if(derivatives&&!sol105&&!analytical)throw Error('Select SOL 105 eigenvalues, analytical reserve factors, or both.');
   const extracted=Number(getParams().nModes)||1,count=derivatives&&sol105?Number($('panel-derivative-modes').value):extracted;
   if(derivatives&&sol105&&(!Number.isInteger(count)||count<1))throw Error('Buckling modes for derivatives must be a positive integer.');
   const validate_fd=operation==='validate',tolerance=validate_fd?Number($('panel-fd-tolerance').value)/100:.005;
   if(validate_fd&&(!finite(tolerance)||tolerance<=0||tolerance>1))throw Error('Validation tolerance must be greater than 0 and no larger than 100%.');
   return {sol105,analytical,derivatives,validate_fd,fd_steps:validate_fd?fdSteps($('panel-fd-steps').value):[.001,.0005],fd_tolerance:tolerance,mode_count:Math.min(count,extracted),buckling_policy_factor:Number(getParams().buckling_policy_factor)||1,include_binary:operation==='analyze'};
  }
  async function run(operation='analyze'){
   if(busy)return;errorHost.hidden=true;const own=++epoch;let inputStamp;
   try{
    if(getMode()!=='panel')throw Error('Generated-panel calculations require Build stiffened panel. Existing decks use Run analysis.');const opOptions=options(operation);
    if(['sensitivities','validate'].includes(operation)&&!selected.size)throw Error('Select at least one sizing dimension.');
    inputStamp=stamp();cancelRequested=false;clearResult();logBox.textContent='';lastLogSequence=0;logKeys.clear();setBusy(true);beginElapsed();onInvalidate?.();
    const sourceModel=await model({apply:true,fit:false});if(!sourceModel||own!==epoch)return;
    const P=getParams();if(JSON.stringify(P)!==inputStamp)throw Error('The panel definition changed during preparation. Start the calculation again.');
    const payload={operation,params:P,variables:[...selected],options:opOptions};jobOrigin=serverBase();
    log('Starting '+operation+' for the generated panel. '+selected.size+' selected dimension(s).');if(operation==='validate')log($('panel-fd-estimate').textContent);
    const start=await request('/panel/jobs',{body:payload,origin:jobOrigin});if(own!==epoch||destroyed){if(start.id)request('/panel/jobs/'+encodeURIComponent(start.id)+'/cancel',{body:{},origin:jobOrigin}).catch(()=>{});return;}
    jobId=start.id;if(!jobId)throw Error('The calculation did not return a job ID.');updateControls();consumeLogs(start);
    const poll=async()=>{
     if(own!==epoch||destroyed)return;
     try{const data=await request('/panel/jobs/'+encodeURIComponent(jobId),{origin:jobOrigin});if(own!==epoch||destroyed)return;consumeLogs(data);
      if(data.status==='complete'){
       if(cancelRequested){log('The server finished after cancellation was requested. This result was not applied.');status('Calculation cancelled.');progressLabel='Calculation cancelled';finish();return;}
       const completed=data.result;if(!completed||completed.ok===false)throw Error(completed?.error||'The calculation completed without a result.');result=completed;resultStamp=inputStamp;updateCatalog(completed);showModelReport(completed.model||sourceModel);
       if(inputStamp===stamp()&&getMode()==='panel'){applyAnalysis?.(completed,sourceModel);onReady?.();}else log('The definition changed while this calculation ran; the result retains its starting definition.');
       activeTab=operation==='validate'?'validation':operation==='sensitivities'?'sensitivities':'responses';drawer(true);render();status('Calculation complete. Review the factors, sensitivities and validation diagnostics.','ok');log('Calculation completed.');progressLabel='Calculation complete';finish();return;
      }
      if(data.status==='cancelled'){log('Calculation cancelled. No cancelled result was applied.');status('Calculation cancelled.');progressLabel='Calculation cancelled';finish();return;}
      if(data.status==='error')throw Error(data.error||data.result?.error||'Panel calculation failed.');
      timer=root.setTimeout(poll,500);
     }catch(error){if(own===epoch){fail(error);log(error.message);progressLabel='Calculation stopped';finish();}}
    };
    timer=root.setTimeout(poll,20);
   }catch(error){if(own===epoch){fail(error);log(error.message);progressLabel='Calculation stopped';finish();}}
  }
  function finish(){jobId=null;timer=null;if(elapsedTimer)root.clearInterval(elapsedTimer);elapsedTimer=null;showElapsed();setBusy(false);}
  async function cancel(){if(!busy||!jobId)return;cancelRequested=true;$('panel-cancel').disabled=true;status('Cancellation requested. Finishing the current safe step…');try{await request('/panel/jobs/'+encodeURIComponent(jobId)+'/cancel',{body:{},origin:jobOrigin});log('Cancellation requested.');}catch(error){fail(error);$('panel-cancel').disabled=false;}}
  $('panel-analytical').onclick=()=>run('analytical');$('panel-sensitivities').onclick=()=>run('sensitivities');$('panel-validate').onclick=()=>run('validate');$('panel-cancel').onclick=cancel;
  function invalidate(){if(busy)return;try{updateCatalog();if(result)render();}catch(_){/* Incomplete edits are validated by the canonical model request. */}}
  updateCatalog();updateControls();
  return {preview,downloadBDF,run,cancel,invalidate,clearResults:clearResult,setSourceMode(){updateControls();if(getMode()!=='panel')drawer(false);},get busy(){return busy;},get model(){return modelCache?.data;},get result(){return result;},destroy(){destroyed=true;epoch++;if(timer)root.clearTimeout(timer);if(elapsedTimer)root.clearInterval(elapsedTimer);if(jobId)request('/panel/jobs/'+encodeURIComponent(jobId)+'/cancel',{body:{},origin:jobOrigin}).catch(()=>{});section.remove();resultHost.remove();view.classList.remove('panel-results-open','panel-results-collapsed');}};
 }
 return {install,fdSteps,rowsCSV,resultRows,sensitivityRows,validationRows,format:fmt};
});
