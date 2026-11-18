/* RF derivative service UI. Numerical derivatives are supplied by the native
 * solver; fixed-force sizing estimates are never substituted for them. */
(function(root,factory){const api=factory(root);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRFSensitivity=api;})(globalThis,function(root){
 'use strict';
 const CHANNEL='JFEM.rf-sensitivity.v1',finite=Number.isFinite;
 const list=value=>Array.isArray(value)?value:Object.entries(value||{}).map(([id,row])=>({...row,id:row?.id??id}));
 const idOf=row=>String(row?.id??row?.response_id??row?.variable_id??'');
 const labelOf=row=>String(row?.label??row?.name??row?.physical_scope??idOf(row));
 const format=value=>finite(value)?Number(value.toPrecision(6)).toString():'Unavailable';
 const numeric=value=>typeof value==='number'&&finite(value)?value:null;
 function parseNumber(value,label,{positive=false,integer=false}={}){const text=String(value??'').trim(),number=Number(text);if(!text||!finite(number)||positive&&number<=0||integer&&!Number.isInteger(number))throw Error(label+' must be '+(positive?'positive and ':'')+(integer?'an integer.':'a finite number.'));return number;}
 function parseVector(text,descriptors,label){
  const raw=String(text||'').trim();if(!raw)throw Error('Enter '+label+' for the selected '+descriptors.length+' entries.');
  let values;try{values=raw.startsWith('[')||raw.startsWith('{')?JSON.parse(raw):raw.split(/[\s,;]+/).filter(Boolean).map(Number);}catch(_){throw Error(label+' must be a numeric list or a JSON object keyed by the displayed IDs.');}
  if(Array.isArray(values)){if(values.length!==descriptors.length)throw Error(label+' needs '+descriptors.length+' entries, in the selected catalog order.');}
  else if(values&&typeof values==='object'){const known=new Set(descriptors.map(idOf));for(const key of Object.keys(values))if(!known.has(key))throw Error('Unknown '+label+' ID: '+key);values=descriptors.map(row=>Object.hasOwn(values,idOf(row))?values[idOf(row)]:0);}
  else throw Error(label+' must be a numeric list or a JSON object.');
  if(values.some(value=>typeof value!=='number'||!finite(value)))throw Error(label+' entries must all be finite numbers.');return values;
 }
 function derivativeColor(value,extent){
  if(!finite(value))return null;if(value===0||!finite(extent)||extent<=0)return '#f2f3ef';
  const t=Math.min(1,Math.abs(value)/extent),a=[242,243,239],b=value<0?[190,48,64]:[43,108,191];
  return 'rgb('+a.map((c,i)=>Math.round(c+(b[i]-c)*t)).join(', ')+')';
 }
 function cellValue(cell){if(typeof cell==='number')return numeric(cell);return cell&&typeof cell==='object'?numeric(cell.derivative??cell.value):null;}
 function normalizeResult(result={}){
  result=result||{};
  const operation=result.operation||'jacobian',variables=list(result.variables??result.design_variables),responses=list(result.responses??result.response_catalog);
  const rows=[],columns=[];let matrix=result.jacobian??result.matrix??result.derivatives;
  const preview=!Array.isArray(matrix)&&Array.isArray(result.matrix_preview);if(preview)matrix=result.matrix_preview;
  if(operation==='jvp'||operation==='directional'){
   columns.push({id:'directional',label:'Directional derivative',unit:result.quantity==='rf'?'RF':'utilization'});
   const product=result.product??result.jvp??result.values??[];
   responses.forEach((response,i)=>rows.push({...response,cells:[product[i]??null]}));
  }else if(operation==='vjp'){
   columns.push({id:'weighted',label:'Weighted response derivative',unit:'per variable unit'});
   const product=result.product??result.vjp??result.values??[];
   variables.forEach((variable,i)=>rows.push({...variable,cells:[product[i]??null]}));
  }else{
   columns.push(...(preview?variables.slice(0,matrix[0]?.length??0):variables));
   if(!Array.isArray(matrix)&&matrix&&typeof matrix==='object')matrix=responses.map(response=>{const values=matrix[idOf(response)];return Array.isArray(values)?values:variables.map(variable=>values?.[idOf(variable)]??null);});
   (preview?responses.slice(0,matrix.length):responses).forEach((response,i)=>rows.push({...response,cells:Array.isArray(matrix?.[i])?matrix[i]:variables.map(()=>null)}));
  }
  const masks=result.derivative_status??result.status_mask??result.mask;
  rows.forEach((row,i)=>{row.cellStatus=Array.isArray(masks?.[i])?masks[i]:[];row.cells=row.cells.map((cell,j)=>{const status=row.cellStatus[j]??cell?.status,reason=result.reasons?.[(i+1)+':'+(j+1)]??result.reasons?.[String(i+1)],blocked=status===false||['unsupported','unavailable','unassessed','invalid','failed','error','missing','nondifferentiable'].includes(String(status).toLowerCase());return blocked||cellValue(cell)===null?{value:null,status:status||'unavailable',reason:cell?.reason||reason||(blocked?'No valid derivative: '+String(status):row.reason)}:cell;});});
  return{operation,quantity:result.quantity||'utilization',variables,responses,rows,columns,preview,metadata:result.metadata||{},source:result};
 }
 function csv(result){
  const view=normalizeResult(result),quote=value=>'"'+String(value??'').replaceAll('"','""')+'"',lines=[];
  lines.push(['Response / variable','ID','Row unit','Case','Solution','Failure mode','Assessment status',...view.columns.map(column=>labelOf(column)+(column.unit?' ['+column.unit+']':''))]);
  for(const row of view.rows)lines.push([labelOf(row),idOf(row),row.unit??(view.operation==='vjp'?'':'dimensionless'),row.case_label??row.case_id??'',row.solution?'SOL'+row.solution:'',row.failure_mode??row.mode??'',row.status??row.derivative_status??'',...view.columns.map((_,i)=>{const value=cellValue(row.cells[i]);return value===null?'':String(value);})]);
  return lines.map(line=>line.map(quote).join(',')).join('\r\n');
 }
 function parameterKeys(result,catalog){
  const descriptors=new Map(list(catalog?.variables).map(row=>[idOf(row),row])),keys=new Set(),visited=new Set();
  function collect(raw){const row=typeof raw==='string'?descriptors.get(raw):raw;if(!row)throw Error('An optimized dimension has no physical parameter map. Refresh the design-variable catalog before staging.');const id=idOf(row);if(visited.has(id))return;visited.add(id);const path=row.path??descriptors.get(id)?.path;if(Array.isArray(path)&&typeof path[0]==='string')keys.add(path[0]);else if(Array.isArray(row.members)&&row.members.length)row.members.forEach(member=>collect(typeof member==='string'?member:String(member.id??member.variable_id??'')));else throw Error('Optimized dimension '+id+' has no physical parameter map. Refresh the design-variable catalog before staging.');}
  list(result?.variables??result?.design_variables).forEach(collect);if(!keys.size)throw Error('The sizing result has no staged physical dimensions.');return[...keys];
 }
 function table(document,host,{download}={}){
  const make=(tag,text,cls)=>{const node=document.createElement(tag);if(text!==undefined)node.textContent=text;if(cls)node.className=cls;return node;};
  let result=null,view=normalizeResult(),page=0,columnPage=0;const rowSize=60,columnSize=12;
  const tools=make('div',undefined,'rf-sensitivity-tools'),search=make('input');search.type='search';search.placeholder='Filter RF, case, mode or property';search.setAttribute('aria-label','Filter RF sensitivity rows');
  const values=make('select');values.title='Dimensional derivative or dimensionless elasticity. Elasticities are unavailable for zero or missing baseline responses.';
  for(const[value,label]of[['derivative','Derivative'],['elasticity','Relative elasticity']]){const option=make('option',label);option.value=value;values.append(option);}
  function fileLink(file){if(!result?.download_job_id)return;const link=make('a');link.href='/api/rf_sensitivity/download?id='+encodeURIComponent(result.download_job_id)+'&file='+encodeURIComponent(file);link.download=file;link.click();}
  const exportButton=make('button','Export full CSV','mini');exportButton.type='button';exportButton.disabled=true;exportButton.onclick=()=>{if(result?.matrix_file&&result.download_job_id)fileLink('jacobian.csv');else if(result)download?.(csv(result),'rf-sensitivity.csv','text/csv;charset=utf-8');};
  const binary=make('button','Download numeric matrix','mini'),metadata=make('button','Download matrix metadata','mini');binary.type=metadata.type='button';binary.hidden=metadata.hidden=true;binary.onclick=()=>fileLink('jacobian.f64');metadata.onclick=()=>fileLink('jacobian_metadata.json');
  tools.append(search,values,exportButton,binary,metadata);
  const note=make('p',undefined,'pick-note'),legend=make('p','Negative = red · zero = neutral · positive = blue. Each column has its own symmetric color range. Grey cells are unavailable, never zero.','rf-sensitivity-legend');
  const scroll=make('div',undefined,'rf-sensitivity-table-scroll'),grid=make('table');scroll.tabIndex=0;scroll.setAttribute('aria-label','RF derivatives');scroll.append(grid);
  const paging=make('div',undefined,'rf-sensitivity-tools'),previous=make('button','Previous rows','mini'),next=make('button','Next rows','mini'),left=make('button','Previous variables','mini'),right=make('button','Next variables','mini'),pageNote=make('span');for(const button of[previous,next,left,right])button.type='button';paging.append(previous,next,left,right,pageNote);
  host.replaceChildren(tools,note,legend,scroll,paging);
  function shownValue(row,index){
   const raw=cellValue(row.cells[index]);if(raw===null)return null;if(values.value!=='elasticity')return raw;
   const column=view.columns[index],baseline=numeric(view.quantity==='rf'?(row.raw_RF??row.rf??row.reserve_factor??row.reserveFactor):(row.utilization??row.value));
   return view.operation==='jacobian'&&baseline!==null&&baseline!==0&&finite(column.value)?raw*column.value/baseline:null;
  }
  function render(){
   const term=search.value.trim().toLowerCase(),rows=view.rows.filter(row=>[idOf(row),labelOf(row),row.case_label,row.case_id,row.solution?'SOL'+row.solution:'',row.failure_mode,row.mode,...(row.membership_pids||row.pids||[])].join(' ').toLowerCase().includes(term));
   page=Math.max(0,Math.min(page,Math.max(0,Math.ceil(rows.length/rowSize)-1)));columnPage=Math.max(0,Math.min(columnPage,Math.max(0,Math.ceil(view.columns.length/columnSize)-1)));
   const firstColumn=columnPage*columnSize,columns=view.columns.slice(firstColumn,firstColumn+columnSize),extents=columns.map((_,j)=>rows.reduce((extent,row)=>Math.max(extent,Math.abs(shownValue(row,firstColumn+j)??0)),0));
   grid.replaceChildren();const caption=make('caption',(view.quantity==='rf'?'Reserve-factor':'Utilization')+' '+(values.value==='elasticity'?'relative elasticities':'derivatives')+' · '+view.operation);grid.append(caption);
   const head=make('thead'),heading=make('tr');heading.append(make('th',view.operation==='vjp'?'Design variable':'Physical RF / load case'));
   columns.forEach(column=>{const th=make('th',labelOf(column));th.append(make('small',idOf(column)+(column.unit?' · '+column.unit:'')));heading.append(th);});head.append(heading);grid.append(head);
   const body=make('tbody');
   for(const row of rows.slice(page*rowSize,(page+1)*rowSize)){
    const tr=make('tr'),label=make('th',labelOf(row));label.scope='row';label.append(make('small',[idOf(row),view.operation==='vjp'&&row.unit?'Variable unit '+row.unit:null,row.case_label||row.case_id,row.solution?'SOL'+row.solution:'',row.failure_mode||row.mode,row.status,row.derivative_status,row.approximation?'Fixed-basis approximation':null,row.nonlinear_demand_estimate?'Proportional full-load assessment':null].filter(value=>value!==undefined&&value!==null&&value!=='').join(' · ')));tr.append(label);
    columns.forEach((_,j)=>{const index=firstColumn+j,cell=row.cells[index],value=shownValue(row,index),status=row.cellStatus?.[index]??cell?.status,td=make('td',value===null?'Unavailable':format(value));
     td.dataset.available=String(value!==null);td.title=value===null?String(cell?.reason??status??row.reason??'No valid derivative was returned for this entry.'):String(status||'Dimensional derivative per the column unit.');
     if(value!==null){td.style.backgroundColor=derivativeColor(value,extents[j]);td.style.color=extents[j]&&Math.abs(value)/extents[j]>.6?'#fff':'#102235';td.dataset.value=String(value);}tr.append(td);
    });body.append(tr);
   }
   if(!rows.length){const tr=make('tr'),td=make('td',result?'No matching derivative rows.':'No RF derivatives computed yet.');td.colSpan=columns.length+1;tr.append(td);body.append(tr);}grid.append(body);
   note.textContent=(view.preview?'Preview: ':'')+view.rows.length+' response rows · '+view.columns.length+' columns. '+(view.operation==='jacobian'?'Full equilibrium derivatives include stiffness/load redistribution.':view.operation==='directional'?'Directional derivatives resolve supported plate-mode clusters for the supplied direction and need not be linear in that direction.':'Products apply the recorded Jacobian/subgradient without materializing the complete matrix.')+(view.source.metadata?.gradient_class?' Gradient class: '+view.source.metadata.gradient_class+'.':'')+(view.preview?' The complete '+view.responses.length+' × '+view.variables.length+' matrix is stored in native files. Use Export full CSV for every computed entry.':'');
   previous.disabled=page===0;next.disabled=(page+1)*rowSize>=rows.length;left.disabled=columnPage===0;right.disabled=(columnPage+1)*columnSize>=view.columns.length;
   pageNote.textContent='Rows '+(rows.length?page*rowSize+1:0)+'–'+Math.min((page+1)*rowSize,rows.length)+' of '+rows.length+' · columns '+(view.columns.length?firstColumn+1:0)+'–'+Math.min(firstColumn+columnSize,view.columns.length)+' of '+view.columns.length;
   values.disabled=view.operation!=='jacobian';exportButton.disabled=!result||!view.rows.length;binary.hidden=metadata.hidden=!result?.matrix_file||!result?.download_job_id;
  }
  search.oninput=()=>{page=0;render();};values.onchange=render;previous.onclick=()=>{page--;render();};next.onclick=()=>{page++;render();};left.onclick=()=>{columnPage--;render();};right.onclick=()=>{columnPage++;render();};
  render();return{
   update(nextResult){result=nextResult;view=normalizeResult(nextResult);page=columnPage=0;render();},
   clear(){result=null;view=normalizeResult();page=columnPage=0;render();},
   get result(){return result;}
  };
 }
 function install({document,host,readParams,readContext,post,download,onBusy,onApplyDesign,onAnalysisStart,onLog}){
  const make=(tag,text,cls)=>{const node=document.createElement(tag);if(text!==undefined)node.textContent=text;if(cls)node.className=cls;return node;};
  const details=make('details',undefined,'rf-sensitivity');details.id='rf-sensitivity';details.append(make('summary','RF sensitivities and structural sizing'));
  const intro=make('p','Compute derivatives of physical RF checks with respect to independent structural dimensions, including equilibrium and structural inertia. The manual fixed-force sizing preview is a separate estimate.','pick-note');details.append(intro);
  const tools=make('div',undefined,'rf-sensitivity-tools'),catalogButton=make('button','Read RFs and design variables','mini'),allResponses=make('button','Select matching RFs','mini'),allVariables=make('button','Select matching variables','mini'),clear=make('button','Clear selections','mini');
  for(const button of[catalogButton,allResponses,allVariables,clear])button.type='button';catalogButton.title='Read the current physical response and independent design-variable catalog. No derivative or optimization run starts until you press Run.';tools.append(catalogButton,allResponses,allVariables,clear);details.append(tools);
  const selection=make('div',undefined,'rf-sensitivity-selection'),responseBox=make('fieldset'),variableBox=make('fieldset');responseBox.append(make('legend','Physical RF checks'));variableBox.append(make('legend','Independent dimensions and bounds'));
  const responseFilter=make('input'),variableFilter=make('input');for(const input of[responseFilter,variableFilter]){input.type='search';input.placeholder='Filter by name, ID, case or component';}
  responseFilter.setAttribute('aria-label','Filter RF responses');variableFilter.setAttribute('aria-label','Filter RF design variables');
  const responseList=make('div',undefined,'rf-sensitivity-selector'),variableList=make('div',undefined,'rf-sensitivity-selector');responseBox.append(responseFilter,responseList);variableBox.append(variableFilter,variableList);selection.append(responseBox,variableBox);details.append(selection);
  const count=make('p','Read the current model catalog to select RF checks and dimensions.','pick-note');count.setAttribute('role','status');details.append(count);
  const settings=make('div',undefined,'rf-sensitivity-settings');
  function field(label,node,help){const wrapper=make('label');wrapper.append(make('span',label),node);if(help)wrapper.title=node.title=help;settings.append(wrapper);return wrapper;}
  function select(items){const node=make('select');for(const[value,label]of items){const option=make('option',label);option.value=value;node.append(option);}return node;}
  const operation=select([['jacobian','RF-by-dimension matrix'],['jvp','Jacobian product · Jv'],['directional','Directional derivative · mode-cluster aware'],['vjp','Weighted response gradient · Jᵀw'],['optimize','Minimum-mass sizing']]),quantity=select([['utilization','Utilization · U = 1 / RF'],['rf','Reserve factor · RF']]);
  field('Operation',operation,'A complete matrix needs multiple right-hand sides. Jv and Jᵀw apply the recorded Jacobian/subgradient. The separate directional derivative resolves supported plate-mode clusters for the specified direction, where the true directional result may not be linear in that direction. Sizing minimizes mass subject to all selected utilization constraints and valid dimension bounds.');field('Response quantity',quantity,'Utilization ≤ 1 is equivalent to RF ≥ 1. No-demand sentinels and display caps are not differentiated as constants.');
  const envelope=select([['maximum','Maximum element stress'],['mean','Average element stress'],['trimmed_mean','Average below percentile']]);field('Strength envelope',envelope,'This explicit statistic is used by the native strength RFs and is retained in the recorded run. Elements have equal weights; it is independent of the Stress Report table display settings.');
  const percentile=numericField('Retained stress percentile (%)',95,'Average only element stresses at or below this percentile. Changes in membership are piecewise differentiable; no sorting derivative is assumed.');percentile.wrapper.hidden=true;
  const vector=make('textarea');vector.rows=3;vector.placeholder='[1, 0, …] or {"catalog-id": 1}';const vectorField=field('Direction / response weights',vector,'Jv: one entry per selected dimension. Jᵀw: one entry per selected RF. Catalog order is used for lists; keyed JSON objects can omit zero entries.');vectorField.hidden=true;
  function numericField(label,value,help){const node=make('input');node.type='text';node.inputMode='decimal';node.value=String(value);const wrapper=field(label,node,help);return{node,wrapper};}
  const iterations=numericField('Maximum sizing iterations',30,'Maximum accepted/trial iteration budget for this sizing request.'),move=numericField('Relative move limit',.15,'Bound each trial dimension change relative to the current dimension. A smaller value can improve robustness near changing active failure modes.'),tolerance=numericField('Sizing tolerance',.001,'Positive convergence tolerance interpreted by the native sizing service.');
  for(const item of[iterations,move,tolerance])item.wrapper.hidden=true;details.append(settings);
  const action=make('div',undefined,'rf-sensitivity-tools'),run=make('button','Run RF sensitivities','primary'),cancel=make('button','Cancel run','danger'),exportButton=make('button','Export result JSON','mini'),openTable=make('button','Open RF sensitivity table ↗','mini panel-table-open'),apply=make('button','Apply optimized dimensions','mini');
  for(const button of[run,cancel,exportButton,openTable,apply])button.type='button';run.disabled=true;cancel.hidden=true;exportButton.disabled=openTable.disabled=true;apply.hidden=true;apply.title='Apply the independently assessed final dimensions and regenerate the model. Completed sizing applies them automatically; use this button to retry an interrupted model update.';action.append(run,cancel,openTable,exportButton,apply);details.append(action);
  const status=make('p','No RF sensitivity run started.','rf-sensitivity-status');status.setAttribute('role','status');status.setAttribute('aria-live','polite');const progress=make('progress');progress.hidden=true;progress.max=1;progress.value=0;
  const stale=make('p','The Study or assessment definition changed after this run. These derivatives describe the recorded design; compute a new run before using them for the current design.','rf-sensitivity-stale');stale.hidden=true;
  const error=make('p',undefined,'rf-sensitivity-error');error.setAttribute('role','alert');error.hidden=true;
  const history=make('div',undefined,'rf-sensitivity-history'),dimensionResults=make('div',undefined,'rf-sizing-dimensions'),resultHost=make('div');details.append(status,progress,stale,error,history,dimensionResults,resultHost);host.append(details);
  const statusActivity=root.WingActivity?.inline?.(status);
  const matrix=table(document,resultHost,{download});
  let catalog=null,result=null,busy=false,loading=false,destroyed=false,jobId=null,cancelPending=false,timer=null,requestStamp=null,resultStamp=null,requestAssessmentStamp=null,resultAssessmentStamp=null,catalogStamp=null,epoch=0,resultsWindow=null,windowToken=null,publishedResult=null,publishedStale=null;
  let applyingDesign=false,appliedResult=null,lastLogSequence=0,activityEpoch=0;
  const liveIterations=new Map();
  const selectedResponses=new Set(),selectedVariables=new Set(),bounds=new Map();
  let responsePage=0,variablePage=0;const selectionPage=80;
  const descriptors=()=>({responses:list(catalog?.responses??catalog?.response_catalog),variables:list(catalog?.variables??catalog?.design_variables),cases:list(catalog?.cases)});
  const context=()=>readContext?.()||{};
  function stamp(){const c=context();return JSON.stringify([c.studyEpoch,c.signature,c.meshIdentity,c.definitionSignature,c.assessmentSignature,c.assessmentPolicy,c.allowables]);}
  const assessmentStamp=()=>JSON.stringify([envelope.value,percentile.node.value]);
  const resultCurrent=()=>resultStamp===stamp()&&resultAssessmentStamp===assessmentStamp();
  function showError(message){error.textContent=message||'';error.hidden=!message;}
  function blocker(){const c=context();return c.blocked?c.blockedReason||'Another model operation is active.':!c.ready?'Create the current FEM before computing RF sensitivities.':c.dirty||c.modelDirty||c.pendingDrafts?c.dirtyReason||'The model has unapplied or unsolved changes. Create the current FEM first.':'';}
  async function request(url,payload){
   const response=post?await post(url,payload):await root.fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
   if(response?.json){if(!response.ok){let message;try{const body=await response.json();message=body.error||body.message;}catch(_){message=await response.text();}throw Error(message||'Request failed ('+response.status+').');}return response.json();}
   if(response?.ok===false)throw Error(response.error||response.message||'Request failed.');return response;
  }
  async function get(url){const response=await root.fetch(url,{cache:'no-store'});if(!response.ok){let body;try{body=await response.json();}catch(_){}throw Error(body?.error||body?.message||'Request failed ('+response.status+').');}return response.json();}
  function enabled(row){return row.available!==false&&row.supported!==false&&!['unsupported','unavailable','unassessed','invalid'].includes(String(row.status??row.derivative_status??'').toLowerCase());}
  const matches=(row,filter)=>[idOf(row),labelOf(row),row.case_id,row.case_label,row.solution?'SOL'+row.solution:'',row.mode,row.failure_mode,row.unit,...(row.pids||row.membership_pids||[])].join(' ').toLowerCase().includes(filter.value.trim().toLowerCase());
  function selectedRows(kind){const{responses,variables}=descriptors(),rows=kind==='response'?responses:variables,set=kind==='response'?selectedResponses:selectedVariables;return rows.filter(row=>set.has(idOf(row)));}
  function sync(){
   const{responses,variables}=descriptors(),r=selectedResponses.size,v=selectedVariables.size;const why=blocker(),catalogCurrent=catalogStamp===stamp();
   const locked=busy||applyingDesign;
   details.setAttribute('aria-busy',String(locked||loading));
   statusActivity?.setBusy((locked||loading)&&activityEpoch===epoch);
   count.textContent=r+' / '+responses.length+' RFs · '+v+' / '+variables.length+' dimensions selected. '+(operation.value==='jacobian'?(r*v).toLocaleString()+' entries; total derivatives can be nonzero outside the edited property.':['jvp','directional'].includes(operation.value)?'One design direction per participating case.'+(operation.value==='directional'?' Supported eigenmode clusters are resolved in that direction.':' A recorded Jacobian/subgradient is used.'):operation.value==='vjp'?'Weighted adjoints per participating case.':'All selected physical constraints are checked at the final design.');
   run.disabled=busy||loading||applyingDesign||!catalog||!catalogCurrent||!r||!v||!!why;
   run.title=why||(!catalogCurrent?'The catalog is stale. Read the current RFs and design variables again.':'Run the selected native RF calculation.');catalogButton.disabled=locked||loading;
   for(const button of[allResponses,allVariables,clear])button.disabled=locked||loading||!catalog;
   operation.disabled=locked;quantity.disabled=locked||operation.value==='optimize';
   for(const input of[envelope,percentile.node,vector,iterations.node,move.node,tolerance.node])input.disabled=locked;
   responseFilter.disabled=variableFilter.disabled=locked||loading;
   cancel.hidden=!busy;cancel.disabled=!busy;progress.hidden=!busy;
   stale.hidden=!result||resultCurrent();
   apply.disabled=busy||applyingDesign||appliedResult===result||!stale.hidden||result?.final_verification?.complete!==true;
   apply.hidden=typeof onApplyDesign!=='function'||!(result?.optimized_params||result?.parameters||result?.design?.parameters);
   apply.textContent=applyingDesign?'Updating optimized model…':appliedResult===result?'Optimized dimensions applied':'Apply optimized dimensions';
  }
  function selector(kind){
   const{responses,variables}=descriptors(),isResponse=kind==='response',all=isResponse?responses:variables,filter=isResponse?responseFilter:variableFilter,selected=isResponse?selectedResponses:selectedVariables,target=isResponse?responseList:variableList;
   const rows=all.filter(row=>matches(row,filter));let page=isResponse?responsePage:variablePage;page=Math.min(page,Math.max(0,Math.ceil(rows.length/selectionPage)-1));if(isResponse)responsePage=page;else variablePage=page;
   target.replaceChildren();
   for(const row of rows.slice(page*selectionPage,(page+1)*selectionPage)){
    const item=make('div',undefined,'rf-sensitivity-choice'),label=make('label'),check=make('input');item.dataset.id=idOf(row);item.dataset.kind=kind;check.type='checkbox';check.checked=selected.has(idOf(row));check.disabled=busy||applyingDesign||!enabled(row);check.onchange=()=>{if(check.checked)selected.add(idOf(row));else selected.delete(idOf(row));sync();};
    label.append(check,make('span',labelOf(row)));label.title=[idOf(row),row.case_label||row.case_id,row.failure_mode||row.mode,row.reason||row.message].filter(Boolean).join(' · ');item.append(label);
    if(isResponse){const value=numeric(row.raw_RF??row.rf??row.reserve_factor);item.append(make('small',[idOf(row),row.case_label||row.case_id,row.solution?'SOL'+row.solution:'',row.failure_mode||row.mode,value!==null?'RF '+format(value):row.status||'RF evaluated by native service'].filter(Boolean).join(' · ')));}
    else{
     const limits=bounds.get(idOf(row))||{min:row.lower_bound??row.min??row.minimum??'',max:row.upper_bound??row.max??''};bounds.set(idOf(row),limits);
     const dimensions=make('div',undefined,'rf-sensitivity-bounds');dimensions.append(make('small',idOf(row)+' · current '+format(row.value)+(row.unit?' '+row.unit:'')));
     for(const[key,text]of[['min','Minimum'],['max','Maximum']]){const wrapper=make('label'),input=make('input');input.type='text';input.inputMode='decimal';input.value=limits[key]===null?'':String(limits[key]);input.placeholder='Native bound';input.setAttribute('aria-label',text+' for '+labelOf(row));input.title='Optimizer '+text.toLowerCase()+' in '+(row.unit||'the physical dimension unit')+'. A blank field keeps the native bound. Scientific notation is accepted.';input.disabled=busy||applyingDesign;input.oninput=()=>{limits[key]=input.value;};wrapper.append(make('span',text),input);dimensions.append(wrapper);}item.append(dimensions);
    }
    if(!enabled(row))item.append(make('small',row.reason||row.message||'No supported derivative is available.','rf-sensitivity-unavailable'));target.append(item);
   }
   if(!rows.length)target.append(make('p',catalog?'No matches.':'Read the current catalog to list entries.','pick-note'));
   if(rows.length>selectionPage){const paging=make('div',undefined,'rf-sensitivity-tools'),previous=make('button','Previous','mini'),next=make('button','Next','mini');previous.type=next.type='button';previous.disabled=busy||applyingDesign||page===0;next.disabled=busy||applyingDesign||(page+1)*selectionPage>=rows.length;previous.onclick=()=>{if(isResponse)responsePage--;else variablePage--;selector(kind);};next.onclick=()=>{if(isResponse)responsePage++;else variablePage++;selector(kind);};paging.append(previous,make('span',(page*selectionPage+1)+'–'+Math.min((page+1)*selectionPage,rows.length)+' / '+rows.length),next);target.append(paging);}
  }
  function renderSelection(){selector('response');selector('variable');sync();}
  async function readCatalog(){
   showError('');const why=blocker();if(why){showError(why);return;}const current=++epoch;activityEpoch=current;loading=true;status.textContent='Reading physical RF checks, supported design dimensions and analysis capabilities…';sync();
   try{const source=stamp(),params=readParams(),data=await request('/api/rf_sensitivity/catalog',{params,parameters:params});if(destroyed||current!==epoch)return;if(source!==stamp())throw Error('The Study changed while reading the RF catalog. Read it again.');catalog=data.catalog||data;catalogStamp=source;const{responses,variables}=descriptors(),validResponses=new Set(responses.filter(enabled).map(idOf)),validVariables=new Set(variables.filter(enabled).map(idOf));for(const id of selectedResponses)if(!validResponses.has(id))selectedResponses.delete(id);for(const id of selectedVariables)if(!validVariables.has(id))selectedVariables.delete(id);status.textContent=catalog.message||'Catalog ready. Select the physical RFs and independent dimensions, then run.';renderSelection();}
   catch(failure){if(current===epoch&&!destroyed)showError(failure.message||String(failure));}finally{if(current===epoch){loading=false;sync();}}
  }
  function buildRequest(){
   const responses=selectedRows('response'),variables=selectedRows('variable'),params=readParams();
   if(!responses.length||!variables.length)throw Error('Select at least one supported physical RF and one design dimension.');
   const options={bounds:{},method:envelope.value,percentile:parseNumber(percentile.node.value,'Stress percentile',{positive:true})};if(options.percentile>100)throw Error('Stress percentile must not exceed 100.');
   for(const variable of variables){const limit=bounds.get(idOf(variable))||{},entry={};for(const key of['min','max'])if(String(limit[key]??'').trim()!=='')entry[key]=parseNumber(limit[key],key+' bound for '+labelOf(variable));if(entry.min!==undefined&&entry.max!==undefined&&entry.min>entry.max)throw Error('Minimum exceeds maximum for '+labelOf(variable));const nativeMin=variable.lower_bound??variable.min??variable.minimum;if(finite(nativeMin)&&entry.min!==undefined&&entry.min<nativeMin)throw Error('The lower bound for '+labelOf(variable)+' cannot be below the model minimum gauge '+format(nativeMin)+'.');if(Object.keys(entry).length)options.bounds[idOf(variable)]=entry;}
   const payload={params,parameters:params,case_ids:[...new Set(responses.map(row=>row.case_id).filter(value=>value!==undefined&&value!==null))],response_ids:responses.map(idOf),variables:variables.map(idOf),quantity:quantity.value,operation:operation.value,options};
   if(['jvp','directional'].includes(operation.value))payload.direction=parseVector(vector.value,variables,'Direction');
   if(operation.value==='vjp')payload.weights=parseVector(vector.value,responses,'Response weights');
   if(operation.value==='optimize'){options.max_iterations=parseNumber(iterations.node.value,'Maximum iterations',{positive:true,integer:true});options.move_limit=parseNumber(move.node.value,'Relative move limit',{positive:true});if(options.move_limit>1)throw Error('Relative move limit must be at most 1.');options.tolerance=parseNumber(tolerance.node.value,'Sizing tolerance',{positive:true});payload.quantity='utilization';}
   return payload;
  }
  function busyState(value){busy=value;if(value)activityEpoch=epoch;onBusy?.(value);renderSelection();}
  function showDimensionUpdates(data){
   dimensionResults.replaceChildren();
   const updates=list(data.dimension_updates);
   if(!updates.length)return;
   const filter=make('input');
   filter.type='search';
   filter.placeholder='Filter optimized dimensions or properties';
   filter.setAttribute('aria-label','Filter optimized dimensions');
   const scroll=make('div',undefined,'rf-sensitivity-table-scroll');
   const grid=make('table');
   scroll.append(grid);
   const tools=make('div',undefined,'rf-sensitivity-tools');
   const previous=make('button','Previous dimensions','mini');
   const next=make('button','Next dimensions','mini');
   const note=make('span');
   previous.type=next.type='button';
   tools.append(previous,note,next);
   dimensionResults.append(filter,scroll,tools);
   let page=0;
   const pageSize=60;
   function render(){
    const term=filter.value.trim().toLowerCase();
    const rows=updates.filter(row=>[idOf(row),labelOf(row),...(row.membership_pids||row.pids||[])].join(' ').toLowerCase().includes(term));
    page=Math.max(0,Math.min(page,Math.max(0,Math.ceil(rows.length/pageSize)-1)));
    grid.replaceChildren(make('caption','Optimized structural dimensions'));
    const head=make('thead');
    const headings=make('tr');
    for(const text of['Dimension / property','Unit','Before','Optimized','Change (%)','Minimum','Maximum'])headings.append(make('th',text));
    head.append(headings);
    grid.append(head);
    const body=make('tbody');
    for(const item of rows.slice(page*pageSize,(page+1)*pageSize)){
     const row=make('tr');
     row.dataset.variableId=idOf(item);
     const label=make('th',labelOf(item));
     label.append(make('small',idOf(item)));
     label.scope='row';
     const initial=numeric(item.initial_value),optimized=numeric(item.optimized_value);
     const change=initial!==null&&initial!==0&&optimized!==null?100*(optimized-initial)/initial:null;
     row.append(label,make('td',item.unit||''),make('td',format(initial)));
     const updated=make('td',format(optimized));
     if(initial!==null&&optimized!==null&&initial!==optimized)updated.className='rf-sizing-dimension-changed';
     row.append(updated,make('td',format(change)),make('td',format(item.lower_bound)),make('td',format(item.upper_bound)));
     body.append(row);
    }
    if(!rows.length){
     const row=make('tr'),cell=make('td','No matching optimized dimensions.');
     cell.colSpan=7;row.append(cell);body.append(row);
    }
    grid.append(body);
    previous.disabled=page===0;
    next.disabled=(page+1)*pageSize>=rows.length;
    note.textContent=(rows.length?page*pageSize+1:0)+'–'+Math.min((page+1)*pageSize,rows.length)+' / '+rows.length;
   }
   filter.oninput=()=>{page=0;render();};
   previous.onclick=()=>{page--;render();};
   next.onclick=()=>{page++;render();};
   render();
  }
  function writeLog(message,event={}){
   if(message)onLog?.(String(message),event);
  }
  function consumeProgress(data){
   const events=Array.isArray(data.log_events)?data.log_events:[];
   for(const event of events){
    const sequence=Number(event.sequence);
    if(!finite(sequence)||sequence<=lastLogSequence)continue;
    lastLogSequence=sequence;
    writeLog(event.message||event.log_message,event);
    if(event.phase==='optimization'&&finite(event.iteration)&&finite(event.mass)){
     liveIterations.set(event.iteration,event);
    }
   }
   if(liveIterations.size)showHistory({history:[...liveIterations.values()]},{running:true});
  }
  function clearResults({reason='A new analysis is starting.',cancelActive=true}={}){
   const previousJob=jobId;
   epoch++;
   if(timer)root.clearTimeout(timer);
   timer=null;
   jobId=null;
   loading=false;
   cancelPending=false;
   lastLogSequence=0;
   liveIterations.clear();
   result=null;
   resultStamp=resultAssessmentStamp=null;
   appliedResult=null;
   history.replaceChildren();
   dimensionResults.replaceChildren();
   matrix.clear();
   resultHost.hidden=true;
   exportButton.disabled=openTable.disabled=true;
   apply.hidden=true;
   stale.hidden=true;
   showError('');
   status.textContent=reason;
   if(cancelActive&&previousJob)request('/api/rf_sensitivity/cancel',{id:previousJob}).catch(()=>{});
   if(busy)busyState(false);else sync();
   publish(true);
  }
  function showHistory(data,{running=false}={}){
   history.replaceChildren();const items=data.history||data.optimization?.history;if(!Array.isArray(items)||!items.length)return;
   const mass=data.objective_mass??data.mass,verified=data.final_verified??(data.final_verification?.complete===true?data.final_verification.feasible:undefined);
   const reason=data.termination_reason??data.reason;
   const summary=make('p',running?'Sizing in progress.':'','pick-note');
   if(!running)summary.textContent=(data.converged?'Sizing converged. ':reason?'Sizing stopped: '+reason+'. ':'Sizing iteration history. ')+(finite(mass)?'Structural mass '+format(mass)+' kg. ':'')+'Final RF verification: '+(verified===true?'passed':verified===false?'not passed':'see native status')+'.';
   const certified=data.final_verification?.certified_bound_response_ids;
   if(!running&&Array.isArray(certified)&&certified.length)summary.textContent+=' '+certified.length+' plate check(s) use certified conservative sizing bounds. Physical plate RFs and sizing bounds are recorded separately in exported results.';
   history.append(summary);
   const grid=make('table'),head=make('tr');
   for(const label of['Iteration','Mass (kg)','Minimum RF','Maximum utilization','Governing case','Failure mode','Feasible','Step / status']){const cell=make('th',label);if(label==='Minimum RF')cell.title='Minimum sizing RF: the inverse of the largest selected constraint utilization. A plate check may use a certified conservative sizing bound, recorded separately from its physical plate RF.';head.append(cell);}
   grid.append(head);
   for(const item of items){
    const row=make('tr');
    const utilization=item.max_utilization??item.maximum_utilization;
    const minimumRF=finite(item.minimum_rf)?Math.min(999,item.minimum_rf):finite(utilization)?(utilization>0?Math.min(999,1/utilization):999):null;
    const values=[item.iteration??item.iter,item.mass??item.objective_mass,minimumRF,utilization,
     item.critical_case_label??item.critical_case_id,item.critical_failure_mode,
     item.feasible??(finite(item.constraint_violation)?item.constraint_violation<=Number(tolerance.node.value):undefined),
     item.status??item.step];
    for(const value of values)row.append(make('td',typeof value==='number'?format(value):String(value??'')));
    grid.append(row);
   }
   history.append(grid);
  }
  function publish(force=false){
   if(!resultsWindow||resultsWindow.closed)return;
   if(!result){
    if(force||publishedResult!==null)resultsWindow.postMessage({channel:CHANNEL,token:windowToken,type:'clear',message:status.textContent},root.location.origin);
    publishedResult=null;publishedStale=null;return;
   }
   if(result.operation==='optimize'&&!result.jacobian&&!result.matrix&&!result.derivatives){
    resultsWindow.postMessage({channel:CHANNEL,token:windowToken,type:'clear',message:'Sizing results and optimized dimensions are available in Boxer.'},root.location.origin);
    publishedResult=result;publishedStale=!resultCurrent();return;
   }
   const stale=!resultCurrent();
   if(!force&&result===publishedResult&&stale===publishedStale)return;
   const changed=force||result!==publishedResult;
   resultsWindow.postMessage({channel:CHANNEL,token:windowToken,type:changed?'snapshot':'validity',...(changed?{result}:{}),stale},root.location.origin);
   publishedResult=result;publishedStale=stale;
  }
  function acceptResult(data){result={...(data.result||data),download_job_id:data.id??jobId??data.result?.download_job_id??data.download_job_id};resultStamp=requestStamp;resultAssessmentStamp=requestAssessmentStamp;const sizingWithoutMatrix=result.operation==='optimize'&&!result.jacobian&&!result.matrix&&!result.derivatives;resultHost.hidden=sizingWithoutMatrix;if(!sizingWithoutMatrix)matrix.update(result);showHistory(result);showDimensionUpdates(result);exportButton.disabled=false;openTable.disabled=sizingWithoutMatrix;publish();sync();}
  function sizingCompletionMessage(data){
   if(data.converged)return 'Sizing converged and the final selected RF constraints passed independent verification.';
   const reason=data.termination_reason||data.reason||'see iteration history';
   const verification=data.final_verification;
   if(verification?.complete!==true)return 'Sizing stopped. '+reason+'. Final RF verification is incomplete.';
   return 'Sizing stopped. '+reason+'. '+(verification.feasible?'The final selected RF constraints passed independent verification.':'Some final selected RF constraints exceed their limits.');
  }
  async function applyOptimizedResult(current){
   const accepted=result;
   if(!accepted||accepted.operation!=='optimize'||accepted.final_verification?.complete!==true||typeof onApplyDesign!=='function')return false;
   if(!resultCurrent()){
    writeLog('Optimized dimensions require a new run because the Study or assessment changed.');
    return false;
   }
   const params=accepted.optimized_params||accepted.parameters||accepted.design?.parameters;
   if(!params)return false;
   const initialAssessment=assessmentStamp();
   const initialContext=context();
   applyingDesign=true;
   activityEpoch=epoch;
   renderSelection();
   status.textContent=sizingCompletionMessage(accepted)+' Updating properties and the model view…';
   writeLog('Applying final optimized dimensions and regenerating the property display.');
   try{
    const application=await onApplyDesign(params,accepted);
    if(destroyed||current!==epoch||result!==accepted)return false;
    const updatedContext=context();
    if(assessmentStamp()!==initialAssessment||updatedContext.assessmentSignature!==initialContext.assessmentSignature||
       updatedContext.studyEpoch!==initialContext.studyEpoch)throw Error('The Study or assessment changed while updating the optimized model. Run sizing again.');
    if(application?.definitionSignature!==undefined&&application.definitionSignature!==updatedContext.definitionSignature)throw Error('The Study changed while updating the optimized model. Run sizing again.');
    appliedResult=accepted;
    accepted.application={applied_to_current_study:true,applied_at:new Date().toISOString()};
    resultStamp=stamp();
    resultAssessmentStamp=initialAssessment;
    const changed=new Map(list(accepted.dimension_updates).map(row=>[idOf(row),row.optimized_value]));
    for(const variable of descriptors().variables){
     if(changed.has(idOf(variable)))variable.value=changed.get(idOf(variable));
    }
    catalogStamp=null;
    status.textContent=sizingCompletionMessage(accepted)+' Optimized properties and their color fields are displayed. The Study has unsaved changes.';
    writeLog('Optimized properties applied. The updated mesh and property color fields are displayed.');
    renderSelection();
    publish(true);
    return true;
   }catch(failure){
    if(!destroyed&&current===epoch){
     const updatedContext=context();
     if(failure.optimizedDimensionsApplied===true&&failure.definitionSignature===updatedContext.definitionSignature&&
        updatedContext.studyEpoch===initialContext.studyEpoch&&updatedContext.assessmentSignature===initialContext.assessmentSignature&&
        assessmentStamp()===initialAssessment){
      resultStamp=stamp();
      resultAssessmentStamp=initialAssessment;
      catalogStamp=null;
     }
     showError('Updating the optimized model failed. '+(failure.message||String(failure)));
     status.textContent=sizingCompletionMessage(accepted)+(resultCurrent()?' Review the model-update error and retry Apply optimized dimensions.':' Run sizing again for the current Study and assessment.');
     writeLog('Updating the optimized model failed. '+(failure.message||String(failure)),{level:'error'});
    }
    return false;
   }finally{
    applyingDesign=false;
    if(!destroyed&&current===epoch)renderSelection();
   }
  }
  async function finishResult(data,current){
   acceptResult(data);
   jobId=null;
   busyState(false);
   if(result.operation==='optimize'){
    status.textContent=sizingCompletionMessage(result);
    writeLog(status.textContent);
    if(!cancelPending)await applyOptimizedResult(current);
    return;
   }
   status.textContent=result.complete===false?'RF calculation returned partial coverage. Review unavailable checks before using these derivatives.':'RF calculation completed.';
   writeLog(status.textContent);
  }
  async function poll(current){
   if(destroyed||current!==epoch||!jobId)return;
   try{
    const data=await get('/api/rf_sensitivity/status?id='+encodeURIComponent(jobId));if(destroyed||current!==epoch)return;
    const state=String(data.status??data.state??'running').toLowerCase(),p=data.progress||data;
    consumeProgress(p);
    status.textContent=p.detail||p.message||data.message||state;const completed=Number(p.completed??p.current),total=Number(p.total);if(finite(completed)&&finite(total)&&total>0){progress.max=total;progress.value=Math.max(0,Math.min(total,completed));}else progress.removeAttribute('value');
    if(data.partial_result)acceptResult(data.partial_result);
    if(['completed','complete','done','success','succeeded','partial'].includes(state)||data.done===true&&data.ok!==false){
     const response=data.result?data:await get('/api/rf_sensitivity/result?id='+encodeURIComponent(jobId));
     if(destroyed||current!==epoch)return;
     await finishResult(response,current);
     return;
    }
    if(['failed','error','cancelled','canceled','stopped'].includes(state)){if(data.result)acceptResult(data.result);jobId=null;busyState(false);if(state==='failed'||state==='error')showError(data.error||data.message||'The RF calculation failed.');status.textContent=data.message||'RF calculation '+state+'. Completed records remain available.';return;}
    timer=root.setTimeout(()=>poll(current),1000);
   }catch(failure){if(destroyed||current!==epoch)return;status.textContent='Progress connection interrupted; the native job may still be running.';showError(failure.message||String(failure));timer=root.setTimeout(()=>poll(current),2500);}
  }
  async function start(){
   showError('');const why=blocker();if(why){showError(why);return;}if(catalogStamp!==stamp()){showError('The catalog is stale. Read the current RFs and dimensions first.');return;}
   let payload;try{payload=buildRequest();}catch(failure){showError(failure.message);return;}
   clearResults({reason:'Preparing the new native RF analysis…'});
   const current=epoch;
   try{
    await onAnalysisStart?.({operation:payload.operation,request:payload});
    if(destroyed||current!==epoch)return;
    requestStamp=stamp();requestAssessmentStamp=assessmentStamp();busyState(true);
    status.textContent='Preparing the native RF analysis and derivative contexts…';progress.removeAttribute('value');
    writeLog(payload.operation==='optimize'?'Starting weight minimization for '+payload.case_ids.length+' load case(s), '+payload.response_ids.length+' RF constraints and '+payload.variables.length+' design dimensions.':'Starting a new RF sensitivity analysis.');
    const data=await request('/api/rf_sensitivity/start',payload),startedId=String(data.id??data.job_id??data.job??'');
    if(destroyed||current!==epoch){if(startedId)request('/api/rf_sensitivity/cancel',{id:startedId}).catch(()=>{});return;}
    if(data.ok===false)throw Error(data.error||data.message||'RF calculation could not start.');
    jobId=startedId;
    if(!jobId){
     if(data.result||data.jacobian||data.product||data.history)await finishResult(data,current);
     else throw Error('The service did not return a job ID or completed result.');
    }else{
     if(cancelPending){
      try{await request('/api/rf_sensitivity/cancel',{id:jobId});status.textContent='Cancellation requested. Waiting for the native job to stop…';}
      catch(failure){showError(failure.message||String(failure));status.textContent='The native job started, but cancellation could not be confirmed. Retry Cancel run.';cancel.disabled=false;}
     }else status.textContent=data.message||'Native RF job started.';
     poll(current);
    }
   }
   catch(failure){if(current===epoch&&!destroyed){busyState(false);showError(failure.message||String(failure));}}
  }
  catalogButton.onclick=readCatalog;run.onclick=start;
  cancel.onclick=async()=>{if(!busy)return;cancelPending=true;cancel.disabled=true;showError('');if(!jobId){status.textContent='Cancellation requested during preparation. The native job will be cancelled as soon as its ID is returned.';return;}try{await request('/api/rf_sensitivity/cancel',{id:jobId});status.textContent='Cancellation requested. Waiting for the current numerical block to stop…';}catch(failure){showError(failure.message||String(failure));cancel.disabled=false;}};
  allResponses.onclick=()=>{for(const row of descriptors().responses)if(enabled(row)&&matches(row,responseFilter))selectedResponses.add(idOf(row));renderSelection();};allVariables.onclick=()=>{for(const row of descriptors().variables)if(enabled(row)&&matches(row,variableFilter))selectedVariables.add(idOf(row));renderSelection();};clear.onclick=()=>{selectedResponses.clear();selectedVariables.clear();renderSelection();};
  responseFilter.oninput=()=>{responsePage=0;selector('response');};variableFilter.oninput=()=>{variablePage=0;selector('variable');};
  function operationChanged(){const op=operation.value;vectorField.hidden=!['jvp','directional','vjp'].includes(op);vectorField.firstChild.textContent=['jvp','directional'].includes(op)?'Design direction v':'Response weights w';for(const item of[iterations,move,tolerance])item.wrapper.hidden=op!=='optimize';quantity.disabled=op==='optimize';if(op==='optimize')quantity.value='utilization';run.textContent=op==='optimize'?'Run minimum-mass sizing':'Run RF sensitivities';sync();}
  operation.onchange=operationChanged;
  envelope.onchange=()=>{percentile.wrapper.hidden=envelope.value!=='trimmed_mean';sync();publish();};percentile.node.oninput=()=>{sync();publish();};
  exportButton.onclick=()=>{if(result)download?.(JSON.stringify(result,null,2),'rf-sensitivity-result.json','application/json');};
  openTable.onclick=()=>{if(!result)return;windowToken=Date.now().toString(36)+'-'+Math.random().toString(36).slice(2);resultsWindow=root.open('rf_sensitivity_table.html#'+windowToken,'jfem-rf-sensitivity-table','width=1400,height=850');if(!resultsWindow)showError('The table window was blocked. Allow pop-ups for this local app, or use the table below.');else resultsWindow.focus();};
  function receive(event){if(event.origin!==root.location?.origin||event.source!==resultsWindow||event.data?.channel!==CHANNEL||event.data.token!==windowToken)return;if(event.data.type==='ready')publish(true);}
  root.addEventListener?.('message',receive);
  apply.onclick=async()=>{showError('');if(!result||!resultCurrent()){showError('The result belongs to a different design or assessment. Run sizing again before applying its dimensions.');return;}await applyOptimizedResult(epoch);};
  renderSelection();operationChanged();
  return{refresh(){if(!destroyed){sync();publish();}},clearResults,get busy(){return busy||applyingDesign;},get result(){return result;},get catalog(){return catalog;},readCatalog,destroy(){destroyed=true;epoch++;statusActivity?.destroy();if(timer)root.clearTimeout(timer);root.removeEventListener?.('message',receive);if(resultsWindow&&!resultsWindow.closed)resultsWindow.postMessage({channel:CHANNEL,token:windowToken,type:'clear',message:'The originating Study was closed or replaced.'},root.location.origin);if(jobId)request('/api/rf_sensitivity/cancel',{id:jobId}).catch(()=>{});if(busy)onBusy?.(false);details.remove();}};
 }
 return{install,table,parseNumber,parseVector,derivativeColor,normalizeResult,csv,parameterKeys,CHANNEL};
});
