/* Read-only derivative tables. Fixed-state operator samples are not responses. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./sensitivity_results.js'):root.WingSensitivityResults);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingSensitivityTableData=api;})(globalThis,function(effects){
 'use strict';const clone=value=>JSON.parse(JSON.stringify(value));
 function panel(row){const key=row.panel_key||/^properties\.panels#([^#]+)#/.exec(row.id||'')?.[1],match=/^(upper|lower):bay([1-9]\d*):stringer([1-9]\d*):segment([1-9]\d*)$/.exec(key||'');if(!match)return null;
  const ids=[...new Set((row.pids||[]).map(Number).filter(pid=>[5,6,7].includes(Math.floor(pid/1000000))).map(pid=>pid%1000000))],id=ids.length===1?ids[0]:Number(/^P(\d+)\b/.exec(row.label||'')?.[1])||null;
  return{key,skin:match[1],rib_bay:Number(match[2]),stringer:Number(match[3]),segment:Number(match[4]),id};
 }
 function family(row){const parts=String(row.id||'').split('#'),part=parts.at(-2),field=parts.at(-1),key=row.field_key||(part==='skin'?'shell.':part==='stringer'?'section.':'')+field;
  return{key:key+'|'+(row.derivative_unit||row.unit||''),name:row.field_label||field.replaceAll('_',' '),unit:row.derivative_unit||''};
 }
 function propertyLabel(row){const p=panel(row);if(!p)return effects.propertyLabel(row);const parts=String(row.id||'').split('#'),part=parts.at(-2),field=parts.at(-1),name=(part==='skin'?'Skin ':part==='stringer'?'Stringer ':'')+field.replaceAll('_',' ');
  return(p.id?'P'+p.id:'Panel')+' \u00b7 '+(p.skin==='upper'?'Upper':'Lower')+' R'+p.rib_bay+'\u2013R'+(p.rib_bay+1)+', stringer '+p.stringer+', segment '+p.segment+': '+name;
 }
 function families(result){const groups=new Map();for(const row of result?.rows||[])if(panel(row)){const f=family(row);if(!groups.has(f.key))groups.set(f.key,f);}return[...groups.values()];}
 function value(result,row,quantity='derivative'){
  if(['failed','unavailable','error'].includes(String(row.status||'').toLowerCase()))return{value:null,reason:row.warning||row.message||'Derivative unavailable ('+row.status+').',status:row.status};
  if(!Number.isFinite(row.derivative))return{value:null,reason:row.warning||row.message||'No finite derivative was returned.',status:'unavailable'};
  if(quantity==='derivative')return{value:row.derivative,unit:row.derivative_unit||((effects.baseline(result).unit||'response')+' / '+(row.unit||'property')),reason:row.warning||'',status:row.status||'ok'};
  const base=effects.baseline(result).value;if(!Number.isFinite(base)||base===0)return{value:null,unit:'dimensionless',reason:'Normalized derivative is undefined for a missing or zero baseline; choose df/dp.',status:'undefined'};
  const normalized=(row.value/base)*row.derivative;
  return Number.isFinite(normalized)?{value:normalized,unit:'dimensionless',reason:row.warning||'',status:row.status||'ok'}:{value:null,unit:'dimensionless',reason:'No finite normalized derivative is available.',status:'unavailable'};
 }
 function compact(raw={}){
  const result=raw.result?clone({...raw.result,rows:(raw.result.rows||[]).map(({samples,...row})=>row),scope:undefined,baseline_analysis:undefined}):null;
  return{result,compatibility:clone(raw.compatibility||raw.result?.compatibility||{}),sourcePath:String(raw.sourcePath||raw.source_path||''),error:String(raw.error||''),panels:(raw.panels||[]).map(({id,key,skin,rib_bay,stringer,segment})=>({id,key,skin,rib_bay,stringer,segment}))};
 }
 function matrix(snapshot,skin,field){
  const definitions=new Map(),records=new Map(),rows=snapshot.result?.rows||[];
  if(snapshot.compatibility?.topology_match===true)for(const p of snapshot.panels||[])if(p.skin===skin)definitions.set(p.key,p);
  for(const row of rows){const p=panel(row);if(!p||p.skin!==skin)continue;definitions.set(p.key,p);if(family(row).key===field){if(!records.has(p.key))records.set(p.key,[]);records.get(p.key).push(row);}}
  const panels=[...definitions.values()],stringers=[...new Set(panels.map(p=>p.stringer))].sort((a,b)=>a-b),bays=[...new Set(panels.map(p=>p.rib_bay))].sort((a,b)=>a-b),cells=new Map();
  for(const p of panels){const key=p.stringer+':'+p.rib_bay;if(!cells.has(key))cells.set(key,[]);cells.get(key).push({...p,rows:records.get(p.key)||[]});}for(const cell of cells.values())cell.sort((a,b)=>a.segment-b.segment||a.id-b.id);
  return{stringers,bays,cells};
 }
 function selectRows(snapshot,{mode='all',skin='upper',field='',filter=''}={}){const query=filter.toLowerCase();return(snapshot.result?.rows||[]).filter(row=>{const p=panel(row);return(mode==='other'?!p:mode==='panels'?p?.skin===skin&&family(row).key===field:true)&&(!query||[propertyLabel(row),row.id,row.field_label,p?.key].join(' ').toLowerCase().includes(query));});}
 const csvCell=value=>{let text=value==null?'':String(value);if(typeof value==='string'&&/^\s*[=+@-]/.test(text))text="'"+text;return '"'+text.replaceAll('"','""')+'"';};
 function csv(snapshot,options={}){const result=snapshot.result||{},baseline=effects.baseline(result),rows=[['Case','Objective','Baseline','Response unit','Property','Property ID','Panel','Skin','Stringer','Rib bay','Segment','Property value','Property unit','df/dp','Derivative unit','p/f * df/dp','Selected quantity','Selected value','Status','Note']];
  for(const row of selectRows(snapshot,options)){const p=panel(row),raw=value(result,row,'derivative'),normalized=value(result,row,'normalized'),selected=options.quantity==='normalized'?normalized:raw;rows.push([result.case_label||result.case_id,effects.objectiveLabel(result),baseline.value,baseline.unit,propertyLabel(row),row.id,p?.id? 'P'+p.id:'',p?.skin,p?.stringer,p?.rib_bay,p?.segment,row.value,row.unit,raw.value,raw.unit,normalized.value,options.quantity==='normalized'?'p/f * df/dp':'df/dp',selected.value,selected.status,selected.reason]);}
  return rows.map(row=>row.map(csvCell).join(',')).join('\r\n')+'\r\n';
 }
 return{panel,family,families,propertyLabel,value,compact,matrix,selectRows,csv};
});
