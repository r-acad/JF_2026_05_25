/* Property reserve factors arranged by verified physical rib/bay ownership.
 * The stress report remains the numerical authority: this adapter never
 * divides a shared property result into invented local values. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingReserveFactorTableData=api;})(globalThis,function(){
 'use strict';
 const GROUPS={upper:'Upper skin / stringers',lower:'Lower skin / stringers',sparwebs:'Spar webs',sparcaps:'Spar caps',ribwebs:'Rib webs',ribstiffeners:'Rib stiffeners',leskins:'Leading-edge skins',leribs:'Leading-edge ribs'};
 // Same component names, row order and rib-versus-bay columns as the property
 // and sensitivity tables. Numeric families are used only for generated models
 // and only when the corresponding actual element-group name agrees.
 const PARTS={front_web:['sparwebs','Front spar',['FRONT_SPAR_WEB']],rear_web:['sparwebs','Rear spar',['REAR_SPAR_WEB']],front_upper_cap:['sparcaps','Front upper',['SPAR_CAPS']],front_lower_cap:['sparcaps','Front lower',['SPAR_CAPS']],rear_upper_cap:['sparcaps','Rear upper',['SPAR_CAPS']],rear_lower_cap:['sparcaps','Rear lower',['SPAR_CAPS']],rib_web:['ribwebs','Main-box web',['RIB_WEBS']],rib_stiffener:['ribstiffeners','Vertical T stiffeners',['RIB_STIFFENERS']],leading_upper_skin:['leskins','Upper skin',['LE_UPPER_SKIN']],leading_lower_skin:['leskins','Lower skin',['LE_LOWER_SKIN']],leading_rib:['leribs','Leading-edge web',['LE_RIB_WEBS','LE_RIB_NOSE']]};
 const FAMILIES={1:'rib_web',2:'rib_stiffener',3:'front_web',4:'rear_web',8:'front_upper_cap',9:'front_lower_cap',10:'rear_upper_cap',11:'rear_lower_cap',12:'leading_upper_skin',13:'leading_lower_skin',14:'leading_rib',15:'rib_web',16:'rib_stiffener',17:'front_web',18:'rear_web'};
 const BASE_GROUPS={...Object.fromEntries(Object.values(PARTS).flatMap(([group,,names])=>names.map(name=>[name,group]))),UPPER_SKIN:'upper',LOWER_SKIN:'lower',UPPER_SKIN_RUNOUTS:'upper',LOWER_SKIN_RUNOUTS:'lower'};
 const finite=n=>typeof n==='number'&&Number.isFinite(n),positiveID=n=>Number.isSafeInteger(Number(n))&&Number(n)>0;
 const format=n=>finite(n)?Number(n.toPrecision(5)).toString():'Unavailable';
 const entries=value=>value instanceof Map?[...value.values()]:Array.isArray(value)?value:Object.values(value||{});
 const clone=value=>value==null?value:JSON.parse(JSON.stringify(value));
 const baseName=name=>String(name||'').replace(/_KINKS$/,'').replace(/_P\d+$/,'');
 const sharedLocation=group=>({group,rowKey:'shared:'+group,rowLabel:GROUPS[group],index:null,columnLabel:'Whole property region',ribs:['ribwebs','ribstiffeners','leribs'].includes(group),key:'shared:'+group,cellLabel:'Shared '+GROUPS[group],unlocated:true});
 function location(part,index){const meta=PARTS[part];if(!meta||!positiveID(index))return null;const ribs=meta[0]==='ribwebs'||meta[0]==='ribstiffeners'||meta[0]==='leribs';return{group:meta[0],rowKey:part,rowLabel:meta[1],index:Number(index),columnLabel:ribs?'R'+index:'R'+index+'–R'+(Number(index)+1),part,ribs,key:part+':'+index,cellLabel:meta[1]};}
 function panelLocations(panel){
  if(!['upper','lower'].includes(panel?.skin)||![panel.rib_bay,panel.stringer,panel.segment??1].every(positiveID))return[];
  const group=panel.skin,bay=Number(panel.rib_bay),stringer=Number(panel.stringer),segment=Number(panel.segment??1),prefix=positiveID(panel.id)?'P'+panel.id+' · ':'';
  const common={group,rowKey:'stringer:'+stringer,rowLabel:(group==='upper'?'U':'L')+stringer,index:bay,columnLabel:'R'+bay+'–R'+(bay+1),ribs:false,panelKey:panel.key||group+':bay'+bay+':stringer'+stringer+':segment'+segment,panelId:panel.id??null,segment,stringer};
  const roles=[['skin',panel.shell_pid,'Skin']];
  if(positiveID(panel.stringer_web_pid))roles.push(['stringer_web',panel.stringer_web_pid,'Stringer blade']);
  else if(positiveID(panel.stringer_pid))roles.push(['stringer',panel.stringer_pid,'Stringer']);
  if(positiveID(panel.stringer_flange_pid))roles.push(['stringer_flange',panel.stringer_flange_pid,'Attached flange']);
  return roles.filter(([,pid])=>positiveID(pid)).map(([part,pid,label])=>({pid:Number(pid),...common,part,key:common.panelKey+':'+part,cellLabel:prefix+label+(segment>1?' · segment '+segment:'')}));
 }
 function compact(raw={}){
  return{report:raw.report?clone(raw.report):null,generated:raw.generated===true,caseScopeLabel:String(raw.caseScopeLabel||''),error:String(raw.error||''),
   panels:(raw.panels||[]).map(p=>Object.fromEntries(['id','key','skin','rib_bay','stringer','segment','shell_pid','stringer_pid','stringer_web_pid','stringer_flange_pid'].filter(k=>p[k]!==undefined).map(k=>[k,p[k]]))),
   componentGroups:entries(raw.componentGroups||raw.properties).map(p=>Object.fromEntries(['pid','name','part','index','component_key'].filter(k=>p[k]!==undefined).map(k=>[k,p[k]])))};
 }
 function reserveValue(record){
  if(!record)return{value:null,status:'unavailable',reason:'No stress-report result is available for this property.'};
  if(record.complete!==true||record.coverage?.recovered!==record.coverage?.total||!(record.coverage?.total>0))return{value:null,status:record.status||'partial',reason:record.reserveFactorReason||'Incomplete case or element coverage; reserve factor is not assessed.'};
  if(record.reserveFactorReason)return{value:null,status:'unassessed',reason:record.reserveFactorReason};
  if(!finite(record.reserveFactor)||record.reserveFactor<0)return{value:null,status:'unassessed',reason:'No finite nonnegative reserve factor is available.'};
  return{value:record.reserveFactor,status:record.reserveFactor<1?'below':record.reserveFactor>1?'above':'limit',reason:record.reserveFactor<1?'Allowable exceeded.':record.reserveFactor>1?'Within specified allowable.':'At the specified allowable.'};
 }
 function scale(items){let min=null,max=null,count=0;const seen=new Set();for(const item of items){if(seen.has(item.pid)||!finite(item.value))continue;seen.add(item.pid);min=min===null?item.value:Math.min(min,item.value);max=max===null?item.value:Math.max(max,item.value);count++;}return{min,max,count,threshold:1,unit:'dimensionless'};}
 function valueColor(value,bounds){
  if(!finite(value)||value<0||!finite(bounds?.min)||!finite(bounds?.max)||bounds.min>bounds.max)return null;
  const neutral=[245,246,248],end=value<1?[205,57,74]:[42,105,181];
  const distance=value<1?(1-value)/(1-Math.min(bounds.min,value)):value>1?(value-1)/(Math.max(bounds.max,value)-1):0;
  const t=Math.max(0,Math.min(1,distance));return 'rgb('+neutral.map((v,i)=>Math.round(v+(end[i]-v)*t)).join(', ')+')';
 }
 function colorStops(bounds){
  if(!finite(bounds?.min)||!finite(bounds?.max))return[];if(bounds.min===bounds.max)return[{value:bounds.min,position:0,color:valueColor(bounds.min,bounds)}];
  const values=[bounds.min,...(bounds.min<1&&bounds.max>1?[1]:[]),bounds.max];return values.map(value=>({value,position:(value-bounds.min)/(bounds.max-bounds.min),color:valueColor(value,bounds)}));
 }
 function valueStyle(value,bounds){
  const color=valueColor(value,bounds);if(!color)return '';
  const rgb=color.match(/[\d.]+/g).slice(0,3).map(Number),ink=.2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2]>135?'#102235':'#fff';
  return ' style="background:'+color+';color:'+ink+'"';
 }
 function build(input={}){
  const report=input.report||{},byPid=new Map(),ownership=new Map();
  for(const row of report.rows||[])if(positiveID(row.pid)&&!byPid.has(Number(row.pid)))byPid.set(Number(row.pid),row);
  function own(pid,where){if(!positiveID(pid)||!where)return;pid=Number(pid);if(!ownership.has(pid))ownership.set(pid,new Map());ownership.get(pid).set(where.key,where);}
  // Imported PIDs can coincidentally match generated numbering; require an
  // explicit generated-model context before using physical table metadata.
  if(input.generated===true){
   for(const p of input.panels||[])for(const item of panelLocations(p)){const{pid,...where}=item;own(pid,where);}
   for(const item of entries(input.componentGroups||input.properties)){
    const pid=Number(item.pid);if(!positiveID(pid))continue;let part=item.part,index=item.index;
    if(item.component_key){const match=/^([a-z_]+):([1-9]\d*)$/.exec(item.component_key);if(match){part=match[1];index=Number(match[2]);}}
    if(!PARTS[part]||!positiveID(index)){
     part=FAMILIES[Math.floor(pid/1000000)];index=pid%1000000;
     if(!PARTS[part]?.[2].includes(baseName(item.name))||!positiveID(index)){
      const group=BASE_GROUPS[baseName(item.name)];if(group&&!ownership.has(pid))own(pid,sharedLocation(group));continue;
     }
    }
    own(pid,location(part,index));
   }
  }
  const all=[];for(const pid of [...new Set([...byPid.keys(),...ownership.keys()])].sort((a,b)=>a-b)){
   const record=byPid.get(pid)||null,locations=[...(ownership.get(pid)?.values()||[])],assessment=reserveValue(record);
   all.push({pid,label:record?.label||'P'+pid,propertyType:record?.propertyType||'Unknown',record,locations,shared:locations.length>1||locations.some(p=>p.unlocated),...assessment});
  }
  const groups=[{id:'all',label:'All properties'},...Object.entries(GROUPS).filter(([id])=>all.some(item=>item.locations.some(p=>p.group===id))).map(([id,label])=>({id,label}))];
  const group=groups.some(g=>g.id===input.group)?input.group:'all',query=String(input.filter||'').trim().toLowerCase();
  const rows=all.filter(item=>(group==='all'||item.locations.some(p=>p.group===group))&&(!query||[item.label,item.pid,item.propertyType,...(item.record?.names||[]),...(item.record?.materialIds||[]).map(mid=>'MID '+mid),...item.locations.map(p=>p.cellLabel)].join(' ').toLowerCase().includes(query)));
  const view=input.view==='flat'||group==='all'||input.generated!==true?'flat':'grid',rowMap=new Map(),columnMap=new Map(),cells=new Map(),shared=[];
  for(const item of rows){
   if(item.shared)shared.push(item);
   for(const p of item.locations.filter(p=>p.group===group)){
    if(p.unlocated)continue;
    rowMap.set(p.rowKey,{key:p.rowKey,label:p.rowLabel,part:p.part,stringer:p.stringer});columnMap.set(p.index,{key:String(p.index),index:p.index,label:p.columnLabel});
    const key=p.rowKey+':'+p.index;if(!cells.has(key))cells.set(key,[]);
    cells.get(key).push({...item,cellLabel:p.cellLabel,location:p,sharedReference:item.shared,...(item.shared?{value:null,status:'shared',reason:'This property spans multiple physical locations. Its full-region reserve factor is shown once under Shared properties.'}:{})});
   }
  }
  const partOrder=Object.keys(PARTS),matrixRows=[...rowMap.values()].sort((a,b)=>(a.stringer??partOrder.indexOf(a.part))-(b.stringer??partOrder.indexOf(b.part)));
  for(const items of cells.values())items.sort((a,b)=>(a.location.segment||0)-(b.location.segment||0)||a.pid-b.pid);
  const matrix={rows:matrixRows,columns:[...columnMap.values()].sort((a,b)=>a.index-b.index),cells,shared,ribs:['ribwebs','ribstiffeners','leribs'].includes(group)};
  const note='Reserve factor = material allowable / selected property stress envelope. Red is below 1, blue is above 1, and neutral is exactly 1. Colors use the actual displayed finite range, anchored at 1. A shared property retains one full-region result; it is never divided into rib-bay values. Unavailable or incomplete results have no reserve-factor color. SOL106 ratios are elastic demand checks, not predicted failure load multipliers.';
  return{report,groups,group,view,rows,matrix,scale:scale(rows),note,generated:input.generated===true,filter:String(input.filter||''),caseScopeLabel:String(input.caseScopeLabel||''),error:String(input.error||'')};
 }
 const escapeHTML=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const escapeMD=v=>String(v??'').replace(/\\/g,'\\\\').replace(/[|*_`\[\]<>]/g,'\\$&').replace(/\r?\n/g,'<br>');
 function notes(model){const report=model.report||{},method={maximum:'Maximum',mean:'Average',trimmed_mean:'Average below percentile'}[report.method]||report.method||'Unspecified';return['Group: '+(GROUPS[model.group]||'All properties'),'Selected view: '+(model.view==='grid'?'Structural group grid':'Property list')+'. Export layout: one row per property.',model.filter?'Property filter: '+model.filter:'',model.caseScopeLabel?'Load-case scope: '+model.caseScopeLabel:'','Envelope: '+method+(report.method==='trimmed_mean'?' · '+format(report.percentile)+'th percentile':''),'Stress values: '+(report.stressUnit||'unspecified units')+'; reserve factors: dimensionless.',model.note,model.error||'',report.note||'',...(report.excludedCases||[]).map(c=>'Excluded '+c.label+': '+c.reason),...(report.missingCases||[]).map(c=>'Missing '+c.label+': '+c.reason)].filter(Boolean);}
 function table(model){
  const report=model.report||{},factor=finite(report.stressFactor)?report.stressFactor:1,stress=v=>finite(v)?format(v*factor):'Unavailable';
  const headers=['Property','Type','Material IDs','Physical locations','Scope','Reserve factor','Allowable ('+(report.stressUnit||'unspecified units')+')','Envelope ('+(report.stressUnit||'unspecified units')+')','Governing load case','Recovery','Assessment'];
  const rows=model.rows.map(item=>{const r=item.record;return[item.label,item.propertyType,(r?.materialIds||[]).join('; '),item.locations.map(p=>(GROUPS[p.group]||p.group)+' / '+p.rowLabel+' / '+p.columnLabel+(p.segment>1?' / segment '+p.segment:'')).join('; '),item.shared?'Shared property region':item.locations.length?'Local property region':'Property region',format(item.value),stress(r?.allowableStress),stress(r?.envelopeStress),r?.envelopeCaseLabel||'Unavailable',r?.coverage?r.coverage.recovered+' / '+r.coverage.total:'Unavailable',item.reason];});
  return{title:'Reserve factor table',headers,rows};
 }
 function csvCell(value){let s=String(value??'');if(/^\s*[=+@-]/.test(s))s="'"+s;return '"'+s.replaceAll('"','""')+'"';}
 function csv(model){const t=table(model);return '\uFEFF'+[[t.title],...notes(model).map(n=>[n]),[],t.headers,...t.rows].map(row=>row.map(csvCell).join(',')).join('\r\n')+'\r\n';}
 function markdown(model){const t=table(model);return '# '+t.title+'\n\n'+notes(model).map(escapeMD).join('\n\n')+'\n\n| '+t.headers.map(escapeMD).join(' | ')+' |\n| '+t.headers.map(()=>'---').join(' | ')+' |\n'+t.rows.map(row=>'| '+row.map(escapeMD).join(' | ')+' |').join('\n')+'\n';}
 function html(model){const t=table(model);return '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>'+t.title+'</title><style>body{font:15px/1.5 system-ui,sans-serif;color:#163047;background:white;margin:2rem}table{border-collapse:collapse;width:100%}td,th{padding:.5rem;border:1px solid #bfd0dd;text-align:left}th{background:#e4eef6}tr{break-inside:avoid}</style></head><body><h1>'+t.title+'</h1>'+notes(model).map(n=>'<p>'+escapeHTML(n)+'</p>').join('')+'<table><thead><tr>'+t.headers.map(n=>'<th>'+escapeHTML(n)+'</th>').join('')+'</tr></thead><tbody>'+t.rows.map((row,i)=>'<tr>'+row.map((v,j)=>'<td'+(j===5?valueStyle(model.rows[i].value,model.scale):'')+'>'+escapeHTML(v)+'</td>').join('')+'</tr>').join('')+'</tbody></table></body></html>\n';}
 return{GROUPS,PARTS,FAMILIES,format,panelLocations,compact,reserveValue,build,scale,valueColor,colorStops,table,notes,csv,markdown,html};
});
