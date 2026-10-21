/* Results / Stress Report: property statistics across physical load cases. */
(function(root){
 'use strict';
 function install({document,host,readContext,onEditAllowables}){
  const data=root.WingStressReportData,finite=Number.isFinite;
  let report=null,cache=null,table='stress',page=0,lastContext=null;const palettes={stress:'viridis',reserve:'signed'};
  const pageSize=100;
  function el(tag,text,cls){const node=document.createElement(tag);if(text!==undefined)node.textContent=text;if(cls)node.className=cls;return node;}
  function select(id,items){const node=el('select');node.id=id;for(const[value,text]of items){const option=el('option',text);option.value=value;node.append(option);}return node;}
  function field(text,input){const label=el('label',undefined,'stress-report-field');label.append(el('span',text),input);return label;}
  const introduction=el('p','Compare property regions across current SOL101 and converged, full-load SOL106 cases. Use Maximize for wider tables.','pick-note');
  const controls=el('div',undefined,'stress-report-controls');
  const scope=select('stress-report-case',[['all','All eligible load cases']]);
  const failureMode=select('stress-report-failure-mode',[['von_mises','Von Mises stress'],['euler_column','Euler column buckling'],['stringer_blade','Stringer blade instability']]);
  const palette=select('stress-report-palette',root.WingReserveFactorTableData.PALETTES);palette.value=palettes.stress;
  failureMode.title='Von Mises compares recovered isotropic stress with material allowables. Euler compares a physical stringer column\u2019s critical axial load with recovered compression at each section cut. Blade instability compares the elastic free-web buckling stress with the signed average axial bar stress between ribs. These checks require generated rib-bay/stringer metadata; an imported property ID alone cannot define a stringer region.';
  palette.title='Choose the table colors. Reserve-factor scales use fixed limits 0 and 2; larger values retain the color at 2 and use dark-orange numbers.';
  const method=select('stress-report-method',[['maximum','Maximum'],['mean','Average'],['trimmed_mean','Average below percentile']]);
  const percentile=el('input');percentile.id='stress-report-percentile';percentile.type='number';percentile.min='0.1';percentile.max='100';percentile.step='0.1';percentile.value='95';
  const percentileField=field('Keep at or below percentile (%)',percentile);percentileField.hidden=true;
  method.title='Calculate this statistic within each property and load case, then take the largest case value. Averages weight elements equally.';
  percentile.title='Compute the percentile of element peak stresses separately for each property and case. Average values at or below the cutoff; retain ties and discard only values strictly above it.';
  const search=el('input');search.id='stress-report-search';search.type='search';search.placeholder='Property ID, name or material';
  controls.append(field('Failure mode',failureMode),field('Load cases',scope),field('Property envelope',method),percentileField,field('Color scale',palette),field('Filter properties',search));
  const switcher=el('div',undefined,'stress-report-tabs');switcher.setAttribute('role','group');switcher.setAttribute('aria-label','Stress report tables');
  const stressButton=el('button','Von Mises stress'),reserveButton=el('button','Reserve Factor');stressButton.id='stress-report-stress';reserveButton.id='stress-report-reserve';
  for(const button of[stressButton,reserveButton])button.type='button';switcher.append(stressButton,reserveButton);
  const actions=el('div',undefined,'stress-report-actions');
  for(const[format,title,mime]of[['csv','CSV','text/csv'],['markdown','Markdown','text/markdown'],['html','HTML','text/html']]){
   const button=el('button','Export '+title,'mini');button.type='button';button.id='stress-report-export-'+format;
   button.onclick=()=>{refresh();if(!report||failureMode.value==='von_mises'&&method.value==='trimmed_mean'&&!percentile.checkValidity())return;const shown=filteredReport(),blob=new Blob([data[format](shown,table)],{type:mime+';charset=utf-8'}),url=URL.createObjectURL(blob),link=el('a');link.href=url;link.download='property-'+(table==='reserve'?'reserve-factors':'stress-report')+'.'+(format==='markdown'?'md':format);link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};actions.append(button);
  }
  const edit=el('button','Edit material allowables','mini');edit.type='button';edit.onclick=onEditAllowables;actions.append(edit);
  const status=el('p',undefined,'stress-report-status');status.id='stress-report-status';status.setAttribute('role','status');status.setAttribute('aria-live','polite');
  const detached=root.WingReserveFactorTables?.connect({readSnapshot:()=>({report,panels:lastContext?.panels||[],componentGroups:lastContext?.componentGroups||[],generated:!!lastContext?.generated,caseScopeLabel:scope.selectedOptions[0]?.textContent||'All eligible load cases'}),onFailureMode:value=>{failureMode.value=value;if(value!=='von_mises')table='reserve';refresh(true);if(report?.failureMode!==value)throw new Error('Set a percentile from 0.1 to 100 in the Study window to use the Von Mises trimmed-mean assessment.');},onError:message=>{status.textContent=message;status.dataset.complete='false';}});
  detached?.installButton(actions);
  const legend=el('div',undefined,'stress-report-legend');
  const viewport=el('div',undefined,'stress-report-table-scroll');viewport.tabIndex=0;viewport.setAttribute('role','region');viewport.setAttribute('aria-label','Property results table');
  const grid=el('table');grid.id='stress-report-table';viewport.append(grid);
  const paging=el('div',undefined,'stress-report-actions'),previous=el('button','Previous','mini'),next=el('button','Next','mini'),pageNote=el('span');previous.type=next.type='button';paging.append(previous,pageNote,next);
  const details=el('details'),detailsTitle=el('summary','Load cases and recovery coverage');details.append(detailsTitle);const coverage=el('div');details.append(coverage);
  const help=el('details'),helpTitle=el('summary','How the envelope and reserve factor are calculated'),helpText=el('p');help.append(helpTitle,helpText);
  host.replaceChildren(introduction,controls,switcher,actions,status,legend,viewport,paging,details,help);
  function filteredReport(){const term=search.value.trim().toLowerCase();return{...report,palette:palettes[table],rows:report.rows.filter(row=>!term||[row.label,...(row.names||[]),...(row.materialIds||[]).map(mid=>'MID '+mid)].join(' ').toLowerCase().includes(term))};}
  function showCoverage(){
   coverage.replaceChildren();
   for(const item of report.includedCases)coverage.append(el('p','Included: '+item.label));
   for(const item of report.excludedCases)coverage.append(el('p','Excluded: '+item.label+' — '+item.reason));
   for(const item of report.missingCases)coverage.append(el('p','Missing: '+item.label+' — '+item.reason));
   const shown=filteredReport().rows;
   coverage.append(el('p',(report.failureMode==='euler_column'?'Section-cut':report.failureMode==='stringer_blade'?'Bar-element':'Element')+' recovery details below follow the filtered page. Exports include all filtered regions.'));
   for(const row of shown.slice(page*pageSize,(page+1)*pageSize)){
    if(!row.reasons.length&&method.value!=='trimmed_mean')continue;
    const section=el('details');section.append(el('summary',row.label+' · '+row.coverage.recovered+' / '+row.coverage.total+(report.failureMode==='euler_column'?' section-cut/case samples':report.failureMode==='stringer_blade'?' bar-element/case samples':' element/case samples')));
    for(const c of row.caseResults){const retained=report.failureMode==='von_mises'&&method.value==='trimmed_mean'?' · '+c.retained+' retained, '+c.discarded+' above cutoff '+stress(c.cutoff):'';section.append(el('p',c.label+': '+c.recovered+' / '+c.total+' recovered'+retained));}
    for(const item of row.reasons)section.append(el('p',item.caseLabel+': '+item.count+(report.failureMode==='euler_column'?' section cut(s)':report.failureMode==='stringer_blade'?' bar element(s)':' element(s)')+' — '+item.reason));coverage.append(section);
   }
  }
  const millimeters=value=>finite(value)?data.format(value*1000):'Unavailable';
  function stress(value){return finite(value)?data.format(value*report.stressFactor):'Unavailable';}
  function render(){
   if(!report)return;
   const shown=filteredReport(),rows=shown.rows,unit=report.stressUnit,euler=report.failureMode==='euler_column',blade=report.failureMode==='stringer_blade',instability=euler||blade,isReserve=table==='reserve';
   palette.value=palettes[table];palette.options[0].textContent=isReserve?'Red below 1 / blue above 1':'Signed red (-) / blue (+)';stressButton.disabled=instability;
   edit.hidden=instability;method.closest('label').hidden=instability;introduction.textContent=blade?'Assess local free-web instability of beam stringers between ribs. Each case uses the signed arithmetic average axial bar stress; the lowest critical-stress / average-compression ratio governs.':euler?'Assess each physical stringer column across current SOL101 and converged, full-load SOL106 cases. The lowest section/case reserve factor governs. Set the end-fixity coefficient c under Structure → Stringers.':'Compare property regions across current SOL101 and converged, full-load SOL106 cases. Use Maximize for wider tables.';
   stressButton.setAttribute('aria-pressed',String(!isReserve));reserveButton.setAttribute('aria-pressed',String(isReserve));
   const pending=report.missingCases.length+report.excludedCases.filter(c=>c.relevant).length;
   status.dataset.complete=String(report.complete);
   status.textContent=rows.length+' / '+report.rows.length+(euler?' stringer columns · ':blade?' stringer blades · ':' properties · ')+report.includedCases.length+' physical solutions · '+report.coverage.recovered+' / '+report.coverage.total+(euler?' recovered section-cut/case samples':blade?' recovered bar-element/case samples':' recovered element/case samples')+(report.complete?'':pending?' · Missing or incomplete cases: '+pending+'. Reserve factors withheld.':' · Incomplete recovery; affected regions are not assessed.');
   if(!report.includedCases.length)status.textContent='No eligible current SOL101 or full-load SOL106 results. Run an analysis with '+(euler?'axial force-resultant recovery.':blade?'signed axial bar-stress recovery.':'element stress recovery.')+' See coverage below for exclusions.';
   const rf=root.WingReserveFactorTableData,scale=isReserve?rf.scale(rows.map(row=>({pid:row.pid,rowKey:row.rowKey,value:row.reserveFactor}))):data.colorScales(shown,table);legend.replaceChildren();
   if(isReserve){const bar=el('span',undefined,'stress-report-colorbar'),stops=rf.colorStops(scale,palettes.reserve);bar.style.background='linear-gradient(90deg,'+stops.map(s=>s.color+' '+s.position*100+'%').join(',')+')';legend.append(bar,el('span','RF: 0 — 1 — 2 · fixed color limits; > 2 saturates and has dark-orange numbers. '+(['signed','coolwarm'].includes(palettes.reserve)?'Red below 1; blue above 1; neutral at 1. ':'')+'Gray: unassessed.'));}
   else if(finite(scale.min)){const bar=el('span',undefined,'stress-report-colorbar');bar.style.background=root.WingColorScales.gradient(palettes.stress,scale.min,scale.max);legend.append(bar,el('span',data.format(scale.min*scale.factor)+' – '+data.format(scale.max*scale.factor)+' '+unit+' · displayed envelope range'));}
   const headers=blade?['Stringer / free web','Critical buckling stress ('+unit+')','Average compression ('+unit+')','Reserve Factor','Governing load case','Clear height / thickness / coverage']:euler?['Stringer / section','Critical load ('+(report.forceUnit||'source force units')+')','Governing compression ('+(report.forceUnit||'source force units')+')','Reserve Factor','Governing load case','Length / c / coverage']:isReserve?['Property / material','Allowable','Envelope','Reserve Factor','Governing load case','Coverage / assessment']:['Property / type','Absolute maximum','Peak element / case','Envelope','Governing load case','Recovery'];
   const caption=el('caption',blade?'Stringer blade instability reserve factors · stress in '+unit:euler?'Euler column reserve factors · '+(report.forceUnit||'source force units'):(isReserve?'Reserve factors':'Von Mises stress')+' · '+data.methodLabel(report)+' · '+(isReserve?'stress in ':'')+unit);
   const head=el('thead'),header=el('tr');for(const text of headers){const cell=el('th',text);cell.scope='col';header.append(cell);}head.append(header);const body=el('tbody');
   page=Math.max(0,Math.min(page,Math.ceil(rows.length/pageSize)-1));
   for(const row of rows.slice(page*pageSize,(page+1)*pageSize)){
    const tr=el('tr');tr.dataset.pid=String(row.pid);tr.dataset.rowKey=row.rowKey||String(row.pid);tr.dataset.status=row.status;
    const id=el('th');id.scope='row';id.append(el('strong',row.label));if(instability)id.append(el('small','PID '+row.pid));id.append(el('small',isReserve?row.materialIds.map(mid=>'MID '+mid).join(', '):row.propertyType),el('small',row.names.join(' · ')));tr.append(id);
    function cell(text){const c=el('td',text);tr.append(c);return c;}
    function colored(value,display){const c=cell(display);if(finite(value)){const badge=el('span',display,'stress-report-value');if(isReserve){badge.dataset.reserve=value<1?'below':value>1?'within':'threshold';badge.style.background=rf.valueColor(value,scale,palettes.reserve);const ink=rf.valueInk(value,scale,palettes.reserve);badge.style.color=ink.color;if(ink.backing){const number=el('span',display,'rf-high-number');number.style.background=ink.backing;badge.replaceChildren(number);}}else{const rgb=scale.color(value,palettes.stress);if(rgb){badge.style.background=root.WingColorScales.css(rgb);badge.style.color=rgb[0]*.299+rgb[1]*.587+rgb[2]*.114>.54?'#102436':'#fff';}}c.replaceChildren(badge);}return c;}
    if(blade){const critical=cell(stress(row.blade?.criticalStress));critical.title='Minimum local free-web critical stress'+(row.blade?.criticalEid?' at EID '+row.blade.criticalEid:'')+(row.blade?.criticalPid?' / PID '+row.blade.criticalPid:'')+'. The displayed clear height and thickness belong to this section. k = '+data.format(row.blade?.coefficient)+'.';const demand=cell(stress(row.blade?.compressionDemand));demand.title='Arithmetic mean of signed axial bar stresses in this rib-bay stringer; tension offsets compression. Governing signed mean: '+stress(row.blade?.averageStress)+' '+unit+'.';const rfCell=colored(row.reserveFactor,finite(row.reserveFactor)?data.format(row.reserveFactor):'Unavailable');rfCell.title=row.reserveFactorReason||(row.blade?.noCompression?'No average compression in the complete case set; RF 99 is a display sentinel.':'Elastic free-web buckling stress / average compressive axial bar stress.');cell(row.envelopeCaseLabel||'—');cell('h = '+millimeters(row.blade?.clearHeight)+' mm · t = '+millimeters(row.blade?.thickness)+' mm · '+(row.blade?.sourceCount??0)+' bars · '+row.coverage.recovered+' / '+row.coverage.total+(row.reserveFactorReason?' · '+row.reserveFactorReason:''));}
    else if(euler){cell(data.format(row.euler?.criticalLoad));cell(data.format(row.euler?.compressionDemand));const rfCell=colored(row.reserveFactor,finite(row.reserveFactor)?data.format(row.reserveFactor):'Unavailable');rfCell.title=row.reserveFactorReason||(row.euler?.governingStation?'Governing section cut '+row.euler.governingStation+'. ':'')+(row.euler?.noCompression?'No compression; RF 99 is a display sentinel.':'Euler critical load / compression at the governing section and load case.');cell(row.envelopeCaseLabel||'—');cell('L = '+data.format(row.euler?.length)+' '+(report.lengthUnit||'source length units')+' · c = '+data.format(row.euler?.endFactor)+' · '+row.coverage.recovered+' / '+row.coverage.total+(row.reserveFactorReason?' · '+row.reserveFactorReason:''));}
    else if(isReserve){cell(stress(row.allowableStress));cell(stress(row.envelopeStress));colored(row.reserveFactor,finite(row.reserveFactor)?data.format(row.reserveFactor):'Unavailable');cell(row.envelopeCaseLabel||'—');cell(row.coverage.recovered+' / '+row.coverage.total+' · '+(row.reserveFactorReason||(row.reserveFactor<1?'Allowable exceeded':'Within specified allowable')));}
    else{cell(stress(row.maxStress));cell(row.maxEid?'EID '+row.maxEid+' · '+row.maxFace+' · '+row.maxCaseLabel:'Unavailable');colored(row.envelopeStress,stress(row.envelopeStress));cell(row.envelopeCaseLabel||'—');cell(row.coverage.recovered+' / '+row.coverage.total+' · '+row.status);}
    body.append(tr);
   }
   if(!rows.length){const tr=el('tr'),td=el('td',report.rows.length?'No regions match this filter.':blade?'No generated stringer-blade metadata is available. Regenerate the mesh if this generated study was saved before blade assessments were added. This assessment needs isotropic T beam stringers with a defined free web and recorded rib-bay membership. Shell stringers and imported properties alone are not assessed.':euler?'No generated stringer-column geometry is available. This assessment needs generated rib-bay/stringer sections; imported property IDs alone do not define columns. For a generated lifting surface, create FEM with stringers to prepare the sections.':'No supported structural property regions are available.');td.colSpan=headers.length;tr.append(td);body.append(tr);}
   grid.replaceChildren(caption,head,body);previous.disabled=page===0;next.disabled=(page+1)*pageSize>=rows.length;paging.hidden=rows.length<=pageSize;pageNote.textContent=(page*pageSize+1)+'–'+Math.min((page+1)*pageSize,rows.length)+' of '+rows.length;
   for(const button of actions.querySelectorAll('[id^="stress-report-export-"]'))button.disabled=!report.includedCases.length||!rows.length;
   helpText.textContent=report.note+(instability?'':' Reserve Factor is available only for isotropic properties with a positive stress allowable. Laminate principal-strain checks remain in FE Results → Material allowable utilization.')+' Exports contain every filtered row, not just this page.';
   if(details.open)showCoverage();else coverage.replaceChildren();
   detached?.refresh();
  }
  details.ontoggle=()=>{if(details.open&&report)showCoverage();};
  function refresh(force=false){
   const context=readContext();lastContext=context;
   // Results normally replace the whole map. Also detect individual case updates
   // without serializing the potentially very large element stress dictionaries.
   const records=[];
   for(const[id,parent]of context.cases||[]){
    records.push(id,parent,parent.analysis,parent.modeKind);
    for(const[key,r]of parent.variants?.size?parent.variants:[['default',parent]])records.push(key,r,r.elementResults,r.static,r.signature,r.meshIdentity,r.matches,r.available,r.historical,r.status,r.analysis,r.loadScale,r.convergence?.converged,r.convergence?.full_load,r.convergence?.partial,JSON.stringify(r.validationIssues));
   }
   const deps=[context.elements,context.cases,context.allowables,context.sourceUnits,context.signature,context.meshIdentity,context.modelDirty,context.pendingDrafts,context.running,context.panels,context.componentGroups,context.generated,context.eulerColumns,context.eulerFixityCoefficient,context.stringerBlades,JSON.stringify(context.expectedCases),JSON.stringify([...(context.caseLabels||[])]),failureMode.value,scope.value,method.value,percentile.value,...records];
   if(!force&&cache&&deps.length===cache.length&&deps.every((v,i)=>v===cache[i]))return report;
   const selected=scope.value;scope.replaceChildren();const all=el('option','All eligible load cases');all.value='all';scope.append(all);
   for(const c of context.expectedCases||[]){const option=el('option',c.label||'Load case '+c.id);option.value=String(c.id);scope.append(option);}
   // Imported result sets can carry cases not present in older Study metadata.
   for(const[id]of context.cases||[]){if([...scope.options].some(o=>o.value===String(id)))continue;const option=el('option',context.caseLabels?.get(id)||'Load case '+id);option.value=String(id);scope.append(option);}
   scope.value=[...scope.options].some(o=>o.value===selected)?selected:'all';
   const instability=failureMode.value!=='von_mises';method.disabled=instability;percentile.disabled=instability;percentileField.hidden=instability||method.value!=='trimmed_mean';
   if(!instability&&method.value==='trimmed_mean'&&!percentile.checkValidity()){percentile.reportValidity();return report;}
   report=data.build({...context,failureMode:failureMode.value,caseId:scope.value==='all'?'all':Number(scope.value),method:method.value,percentile:Number(percentile.value)});cache=deps;page=0;render();return report;
  }
  scope.onchange=method.onchange=percentile.onchange=()=>refresh(true);search.oninput=()=>{page=0;render();};
  failureMode.onchange=()=>{if(failureMode.value!=='von_mises')table='reserve';refresh(true);};palette.onchange=()=>{palettes[table]=palette.value;render();};
  stressButton.onclick=()=>{table='stress';render();};reserveButton.onclick=()=>{table='reserve';render();};previous.onclick=()=>{page--;render();};next.onclick=()=>{page++;render();};
  return{refresh,invalidate(){cache=null;},destroy(){detached?.destroy();},get report(){return report;}};
 }
 root.WingStressReport={install};
})(globalThis);
