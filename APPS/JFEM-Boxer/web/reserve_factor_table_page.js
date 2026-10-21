(function(){
 'use strict';const api=WingReserveFactorTableData,get=id=>document.getElementById(id),CHANNEL='JFEM-Boxer.reserve-factor-table.v1',token=location.hash.slice(1),parent=window.opener,origin=location.origin;
 let snapshot={report:null},model=null,connected=false,lastSeen=Date.now(),initialized=false,page=0;const PAGE_SIZE=200;
 const node=(tag,text,cls)=>{const el=document.createElement(tag);if(text!==undefined)el.textContent=text;if(cls)el.className=cls;return el;};
 const send=type=>{if(parent&&!parent.closed)parent.postMessage({channel:CHANNEL,token,type},origin);};
 const options=()=>({group:get('structural-group').value||'all',view:get('table-view').value,filter:get('property-filter').value});
 const shown=value=>api.format(value),finite=Number.isFinite;
 function controls(){
  const available=api.build({...snapshot,group:'all',view:'flat'}).groups||[],previous=get('structural-group').value;get('structural-group').replaceChildren();
  for(const item of available){const option=node('option',item.label);option.value=item.id;get('structural-group').append(option);}
  const local=available.find(item=>item.id!=='all');
  if(!initialized){get('structural-group').value=snapshot.generated&&local?local.id:'all';get('table-view').value=snapshot.generated&&local?'grid':'flat';initialized=true;}
  else get('structural-group').value=available.some(item=>item.id===previous)?previous:(snapshot.generated&&local?local.id:'all');
  const gridOption=get('table-view').querySelector('[value="grid"]');gridOption.disabled=!snapshot.generated||!local||get('structural-group').value==='all';if(gridOption.disabled)get('table-view').value='flat';
 }
 function reserve(item,host){
  const record=item.record||item,value=Object.hasOwn(item,'value')?item.value:record.reserveFactor,reason=item.reason||record.reserveFactorReason||'',shared=!!item.sharedReference;
  const span=node('span',shared?'Shared property':finite(value)?shown(value):'Unassessed','rf-value'+(!finite(value)||shared?' rf-unavailable':''));span.dataset.pid=String(item.pid??record.pid??'');span.dataset.value=finite(value)&&!shared?String(value):'';
  span.title=shared?'This property spans multiple locations. Its whole-region result is listed once below.':reason||('Reserve factor '+shown(value)+' · '+(record.envelopeCaseLabel||'Governing case unavailable'));
  if(finite(value)&&!shared){span.dataset.state=value<1?'below':value>1?'above':'threshold';const color=api.valueColor(value,model.scale);if(color){span.style.backgroundColor=color;const rgb=color.match(/[\d.]+/g)?.slice(0,3).map(Number)||[255,255,255];span.style.color=.2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2]>135?'#102235':'#fff';}}
  host.append(span);if(reason&&!shared&&!finite(value))host.append(node('small',reason,'rf-reason'));return record;
 }
 function itemCell(item,cell){const wrap=node('div',undefined,'rf-cell');wrap.dataset.pid=String(item.pid||item.record?.pid||'');wrap.append(node('strong',(item.cellLabel?item.cellLabel+' · ':'')+(item.label||'PID '+item.pid)));const record=reserve(item,wrap);if(record.envelopeCaseLabel&&!item.sharedReference)wrap.append(node('small',record.envelopeCaseLabel));if(record.coverage)wrap.title=record.coverage.recovered+' / '+record.coverage.total+' recovered element/case samples';cell.append(wrap);}
 function grid(head,body){
  const matrix=model.matrix,header=head.insertRow();header.append(node('th','Component ↓'));for(const column of matrix.columns){const th=node('th',column.label);th.scope='col';header.append(th);}if(!matrix.columns.length&&matrix.shared?.length)header.append(node('th','Whole property region'));
  for(const row of matrix.rows){const tr=body.insertRow(),th=node('th',row.label);th.scope='row';tr.append(th);for(const column of matrix.columns){const td=tr.insertCell(),items=matrix.cells.get(row.key+':'+column.index)||[];if(!items.length){td.textContent='—';td.className='no-panel';continue;}for(const item of items)itemCell(item,td);}}
  if(matrix.shared?.length){const tr=body.insertRow(),th=node('th','Shared property regions · one result across all their locations','shared-heading');th.colSpan=Math.max(2,matrix.columns.length+1);tr.append(th);for(const item of matrix.shared){const row=body.insertRow(),label=node('th',item.label||'PID '+item.pid);label.scope='row';row.append(label);const cell=row.insertCell();cell.colSpan=Math.max(1,matrix.columns.length);itemCell(item,cell);cell.append(node('small','Shared property; this reserve factor is not a separate result at each rib bay.','shared-note'));}}
 }
 function list(head,body){
  const report=snapshot.report,header=head.insertRow(),unit=report?.stressUnit||'stress units';for(const label of ['Property / location','Reserve factor','Allowable ('+unit+')','Envelope ('+unit+')','Governing case','Coverage / assessment']){const th=node('th',label);th.scope='col';header.append(th);}
  page=Math.max(0,Math.min(page,Math.ceil(model.rows.length/PAGE_SIZE)-1));
  for(const item of model.rows.slice(page*PAGE_SIZE,(page+1)*PAGE_SIZE)){
   const row=item.record||{},tr=body.insertRow(),th=node('th',item.label||'PID '+item.pid);th.scope='row';th.append(node('small',(row.names||[]).join(' · ')));
   if(item.locations?.length)th.append(node('small',item.locations.map(location=>[location.rowLabel,location.columnLabel,location.cellLabel].filter(Boolean).join(' / ')).join(' · ')));
   tr.append(th);reserve(item,tr.insertCell());for(const stress of[row.allowableStress,row.envelopeStress])tr.insertCell().textContent=finite(stress)?shown(stress*(report.stressFactor||1)):'Unavailable';tr.insertCell().textContent=row.envelopeCaseLabel||'—';tr.insertCell().textContent=(row.coverage?row.coverage.recovered+' / '+row.coverage.total+' · ':'')+(item.reason||row.status||'');
  }
  get('list-pagination').hidden=model.rows.length<=PAGE_SIZE;get('previous-page').disabled=page===0;get('next-page').disabled=(page+1)*PAGE_SIZE>=model.rows.length;get('page-count').textContent=(page*PAGE_SIZE+1)+'–'+Math.min((page+1)*PAGE_SIZE,model.rows.length)+' of '+model.rows.length;
 }
 function legend(){const scale=model.scale,stops=api.colorStops(scale)||[];get('rf-ramp').style.background=stops.length>1?'linear-gradient(to right,'+stops.map(s=>s.color+' '+100*s.position+'%').join(',')+')':stops[0]?.color||'#687986';const ticks=get('rf-ticks');ticks.replaceChildren();for(const stop of stops.filter((stop,index)=>!index||index===stops.length-1||stop.value===1&&stop.position>.12&&stop.position<.88)){const tick=node('span',shown(stop.value));tick.style.left=100*stop.position+'%';ticks.append(tick);}get('rf-limits').textContent=scale?.count?'Actual finite range '+shown(scale.min)+' to '+shown(scale.max)+' · '+scale.count+' assessed property regions':'No assessed reserve factors in this selection.';}
 function render(){
  model=api.build({...snapshot,...options()});const report=snapshot.report,head=get('reserve-factor-table').tHead,body=get('reserve-factor-table').tBodies[0];head.replaceChildren();body.replaceChildren();get('list-pagination').hidden=true;
  const isGrid=model.view==='grid'&&model.matrix;get('reserve-factor-table').classList.toggle('rf-list',!isGrid);if(isGrid)grid(head,body);else if(report)list(head,body);legend();
  const status=get('connection');status.classList.toggle('warning',!connected||report?.complete!==true);status.textContent=!connected?'Study window disconnected · last received report retained for inspection and export.':report?.complete?'Current Stress Report · read-only data from the Study window.':'Current Stress Report has incomplete or unavailable recovery · unassessed regions are not colored.';
  get('table-error').hidden=!snapshot.error;get('table-error').textContent=snapshot.error||'';get('case-scope').textContent=snapshot.caseScopeLabel||'All eligible load cases';get('envelope-method').textContent=report?'Envelope: '+WingStressReportData.methodLabel(report):'';get('coverage').textContent=report?.coverage?report.coverage.recovered+' / '+report.coverage.total+' recovered element/case samples':'';get('table-count').textContent=model.rows.length+' property regions · '+(model.scale?.count||0)+' assessed';get('selection-note').textContent=model.note||'';
  get('empty').hidden=!!body.rows.length;get('reserve-factor-table').hidden=!body.rows.length;for(const format of['csv','markdown','html'])get('export-'+format).disabled=!model.rows.length;
 }
 get('structural-group').onchange=()=>{page=0;if(get('structural-group').value!=='all'&&snapshot.generated)get('table-view').value='grid';controls();render();};get('table-view').onchange=()=>{page=0;render();};get('property-filter').oninput=()=>{page=0;render();};get('previous-page').onclick=()=>{page--;render();};get('next-page').onclick=()=>{page++;render();};get('help-button').onclick=()=>{get('help').hidden=!get('help').hidden;get('help-button').setAttribute('aria-expanded',String(!get('help').hidden));};
 for(const[format,mime,extension]of[['csv','text/csv','csv'],['markdown','text/markdown','md'],['html','text/html','html']])get('export-'+format).onclick=()=>{if(!model)return;const blob=new Blob([api[format](model)],{type:mime+';charset=utf-8'}),url=URL.createObjectURL(blob),link=node('a');link.href=url;link.download='reserve-factors-'+model.group+'.'+extension;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
 addEventListener('message',event=>{const message=event.data;if(event.origin!==origin||event.source!==parent||!message||message.channel!==CHANNEL||message.token!==token)return;lastSeen=Date.now();if(message.type==='snapshot'){snapshot=api.compact(message.snapshot);connected=true;page=0;controls();render();}else if(message.type==='disconnected'){connected=false;render();}});
 if(!parent||!token){get('connection').textContent='Open this table using “Open reserve factor table ↗” in Results → Stress Report.';return;}
 send('ready');const timer=setInterval(()=>{if(parent.closed){connected=false;render();clearInterval(timer);}else{if(connected&&Date.now()-lastSeen>8000){connected=false;render();}send(connected?'ping':'ready');}},2000);addEventListener('pagehide',()=>clearInterval(timer),{once:true});
})();
