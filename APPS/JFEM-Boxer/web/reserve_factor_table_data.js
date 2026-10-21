/* Property reserve factors arranged by verified physical rib/bay ownership.
 * The stress report remains the numerical authority: this adapter never
 * divides a shared property result into invented local values. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./color_scales.js'):root.WingColorScales);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingReserveFactorTableData=api;})(globalThis,function(colors){
 'use strict';
 const GROUPS={upper:'Upper skin / stringers',lower:'Lower skin / stringers',sparwebs:'Spar webs',sparcaps:'Spar caps',ribwebs:'Rib webs',ribstiffeners:'Rib stiffeners',leskins:'Leading-edge skins',leribs:'Leading-edge ribs'};
 const PALETTES=[['signed','Red below 1 / blue above 1'],['spectrum','Spectrum'],['viridis','Viridis'],['inferno','Inferno'],['coolwarm','Cool / warm'],['grayscale','Grayscale']];
 const PRESENTATIONS=[['reserve_factor','Minimum RF'],['critical_case','Critical case'],['failure_mode','Failure mode']];
 const FAILURE_MODES={minimum_rf:'Minimum RF across failure modes',von_mises:'Von Mises stress',principal_strain:'Laminate principal strain',euler_column:'Euler column buckling',stringer_blade:'Stringer blade instability',skin_buckling:'Skin panel buckling'};
 const MINIMUM_GAUGE_COLOR='rgb(255, 222, 89)';
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
  return{report:raw.report?clone(raw.report):null,requestedFailureMode:String(raw.requestedFailureMode||''),generated:raw.generated===true,caseScopeLabel:String(raw.caseScopeLabel||''),error:String(raw.error||''),
   panels:(raw.panels||[]).map(p=>Object.fromEntries(['id','key','skin','rib_bay','stringer','segment','shell_pid','stringer_pid','stringer_web_pid','stringer_flange_pid'].filter(k=>p[k]!==undefined).map(k=>[k,p[k]]))),
   componentGroups:entries(raw.componentGroups||raw.properties).map(p=>Object.fromEntries(['pid','name','part','index','component_key'].filter(k=>p[k]!==undefined).map(k=>[k,p[k]])))};
 }
 function reserveValue(record){
  if(!record)return{value:null,status:'unavailable',reason:'No stress-report result is available for this property.'};
  if(record.complete!==true||record.coverage?.recovered!==record.coverage?.total||!(record.coverage?.total>0))return{value:null,status:record.status||'partial',reason:record.reserveFactorReason||'Incomplete case or element coverage; reserve factor is not assessed.'};
  if(record.reserveFactorReason)return{value:null,status:'unassessed',reason:record.reserveFactorReason};
  if(!finite(record.reserveFactor)||record.reserveFactor<0)return{value:null,status:'unassessed',reason:'No finite nonnegative reserve factor is available.'};
  return{value:record.reserveFactor,status:record.reserveFactor<1?'below':record.reserveFactor>1?'above':'limit',reason:record.combined?.sentinel?'No destabilizing demand in the complete applicable check set. RF 99 is a display sentinel, not a computed margin.':record.skinBuckling?.noDestabilizingLoad?'No destabilizing averaged membrane state in the complete recovered case set. RF 99 is a display sentinel; local element stresses can still be destabilizing.':record.blade?.noCompression?'No average axial compression in the complete recovered case set; individual bars can still be compressive. RF 99 is a display sentinel, not a calculated ratio.':record.euler?.noCompression?'No compression in the complete recovered case set; RF 99 is a display sentinel, not a calculated ratio.':record.reserveFactor<1?'Capacity exceeded.':record.reserveFactor>1?'Below the specified capacity.':'At the specified capacity.'};
 }
 function scale(items){let actualMin=null,actualMax=null,count=0;const seen=new Set();for(const item of items){const key=item.rowKey??item.pid;if(seen.has(key)||!finite(item.value))continue;seen.add(key);actualMin=actualMin===null?item.value:Math.min(actualMin,item.value);actualMax=actualMax===null?item.value:Math.max(actualMax,item.value);count++;}return{min:count?0:null,max:count?2:null,actualMin,actualMax,count,threshold:1,unit:'dimensionless'};}
 function atMinimumGauge(record,value=record?.reserveFactor){
  return finite(value)&&value>1&&record?.complete===true&&record.coverage?.total>0&&record.coverage.recovered===record.coverage.total&&record.minimumGauge?.known===true&&record.minimumGauge.atMinimum===true&&!record.reserveFactorReason;
 }
 function minimumGaugeLabel(record){return record?.minimumGauge?.known===true?(record.minimumGauge.atMinimum===true?'All relevant dimensions at minimum':'Dimensions above minimum'):'Minimum gauge unknown';}
 function presentationValue(record,presentation='reserve_factor',failureMode){
  if(presentation==='critical_case')return record?.envelopeCaseLabel||record?.combined?.governingCase||'Unavailable';
  if(presentation==='failure_mode')return record?.combined?.governingModeLabel||FAILURE_MODES[record?.combined?.governingMode||failureMode]||'Unavailable';
  return format(record?.reserveFactor);
 }
 function valueColor(value,bounds,palette='signed',record){
  if(!finite(value)||value<0||!finite(bounds?.min)||!finite(bounds?.max)||bounds.min>bounds.max)return null;
  if(atMinimumGauge(record,value))return MINIMUM_GAUGE_COLOR;
  if(!['signed','coolwarm'].includes(palette)&&colors?.scales[palette])return colors.css(colors.valueColor(palette,value,0,2));
  if(value===1)return 'rgb(245, 246, 248)';
  // Keep an unmistakable hue on each side of one, including RF 0.999/1.001.
  // The small deliberate discontinuity distinguishes passing/failing regions.
  const coolwarm=palette==='coolwarm',pale=value<1?(coolwarm?[240,144,131]:[242,150,158]):(coolwarm?[142,177,242]:[153,190,236]),end=value<1?(coolwarm?[180,4,38]:[205,57,74]):(coolwarm?[59,76,192]:[42,105,181]),t=Math.min(1,Math.abs(value-1));
  return 'rgb('+pale.map((v,i)=>Math.round(v+(end[i]-v)*t)).join(', ')+')';
 }
 function colorStops(bounds,palette='signed'){
  if(!finite(bounds?.min)||!finite(bounds?.max))return[];
  if(!['signed','coolwarm'].includes(palette)&&colors?.scales[palette])return colors.stops(palette,0,2).map(s=>({...s,color:colors.css(s.color)}));
  return[0,.999999,1,1.000001,2].map(value=>({value,position:value/2,color:valueColor(value,bounds,palette)}));
 }
 function valueInk(value,bounds,palette='signed',record){
  const color=valueColor(value,bounds,palette,record);if(!color)return {color:'',backing:''};
  const luminance=rgb=>rgb.map(v=>v/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4).reduce((sum,v,i)=>sum+v*[.2126,.7152,.0722][i],0),level=luminance(color.match(/[\d.]+/g).slice(0,3).map(Number)),dark=luminance([16,34,53]),ink=(level+.05)/(dark+.05)>=1.05/(level+.05)?'#102235':'#fff';
  return{color:value>2?'#963e00':ink,backing:value>2?'#fff1df':''};
 }
 function valueStyle(value,bounds,palette='signed',record){
  const color=valueColor(value,bounds,palette,record);if(!color)return '';return ' style="background:'+color+';color:'+valueInk(value,bounds,palette,record).color+'"';
 }
 function build(input={}){
  const report=input.report||{},euler=report.failureMode==='euler_column',blade=report.failureMode==='stringer_blade',skin=report.failureMode==='skin_buckling',physical=euler||blade||skin,byPid=new Map(),ownership=new Map();
  for(const row of report.rows||[])if(positiveID(row.pid)&&!byPid.has(Number(row.pid)))byPid.set(Number(row.pid),row);
  function own(pid,where){if(!positiveID(pid)||!where)return;pid=Number(pid);if(!ownership.has(pid))ownership.set(pid,new Map());ownership.get(pid).set(where.key,where);}
  // Imported PIDs can coincidentally match generated numbering; require an
  // explicit generated-model context before using physical table metadata.
  if(input.report&&input.generated===true&&!physical){
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
  const all=[];if(physical){for(const record of report.rows||[]){const locations=input.generated===true?(record.locations||[]).filter(p=>['upper','lower'].includes(p.group)&&positiveID(p.index)&&typeof p.rowKey==='string'):[];all.push({pid:record.pid,rowKey:record.rowKey||record.panelKey,label:record.label,propertyType:record.propertyType,record,locations,shared:false,...reserveValue(record)});}}
  else for(const pid of [...new Set([...byPid.keys(),...ownership.keys()])].sort((a,b)=>a-b)){
   const record=byPid.get(pid)||null,locations=[...(ownership.get(pid)?.values()||[])],assessment=reserveValue(record);
   all.push({pid,label:record?.label||'P'+pid,propertyType:record?.propertyType||'Unknown',record,locations,shared:locations.length>1||locations.some(p=>p.unlocated),...assessment});
  }
  const groups=[{id:'all',label:skin?'All skin panels':euler?'All stringer columns':blade?'All stringer blades':'All properties'},...Object.entries(GROUPS).filter(([id])=>all.some(item=>item.locations.some(p=>p.group===id))).map(([id,label])=>({id,label:skin&&['upper','lower'].includes(id)?(id==='upper'?'Upper skin panels':'Lower skin panels'):label}))];
  const group=groups.some(g=>g.id===input.group)?input.group:'all',query=String(input.filter||'').trim().toLowerCase();
  const rows=all.filter(item=>(group==='all'||item.locations.some(p=>p.group===group))&&(!query||[item.label,item.pid,item.propertyType,...(item.record?.propertyIds||[]),...(item.record?.names||[]),...(item.record?.materialIds||[]).map(mid=>'MID '+mid),...item.locations.map(p=>p.cellLabel)].join(' ').toLowerCase().includes(query)));
  const view=input.view==='flat'||group==='all'||input.generated!==true?'flat':'grid',rowMap=new Map(),columnMap=new Map(),cells=new Map(),shared=[];
  for(const item of rows){
   if(item.shared)shared.push(item);
   for(const p of item.locations.filter(p=>p.group===group)){
    if(p.unlocated)continue;
    rowMap.set(p.rowKey,{key:p.rowKey,label:p.rowLabel,part:p.part,stringer:p.stringer,stripIndex:p.stripIndex});columnMap.set(p.index,{key:String(p.index),index:p.index,label:p.columnLabel});
    const key=p.rowKey+':'+p.index;if(!cells.has(key))cells.set(key,[]);
    cells.get(key).push({...item,cellLabel:p.cellLabel,location:p,sharedReference:item.shared,...(item.shared?{value:null,status:'shared',reason:'This property spans multiple physical locations. Its full-region reserve factor is shown once under Shared properties.'}:{})});
   }
  }
  const partOrder=Object.keys(PARTS),matrixRows=[...rowMap.values()].sort((a,b)=>(a.stripIndex??a.stringer??partOrder.indexOf(a.part))-(b.stripIndex??b.stringer??partOrder.indexOf(b.part)));
  for(const items of cells.values())items.sort((a,b)=>(a.location.segment||0)-(b.location.segment||0)||a.pid-b.pid);
  const matrix={rows:matrixRows,columns:[...columnMap.values()].sort((a,b)=>a.index-b.index),cells,shared,ribs:['ribwebs','ribstiffeners','leribs'].includes(group)};
  const note=(report.failureMode==='minimum_rf'?'Each property shows the minimum complete RF over its applicable failure checks and selected load cases. Physical plate and column checks retain their full source scope; involving a property does not make a shared physical check local to that property. Read the governing scope and candidate details before interpretation. ':skin?'Skin panel reserve factor is the elastic plate buckling multiplier for the combined area-averaged biaxial and shear membrane state. Tension is positive and compression negative; x follows the panel span and y its transverse width. RF 99 denotes complete recovery with no destabilizing average membrane state, not absence of local compressive stresses. ':blade?'Blade reserve factor = elastic free-web critical stress / average compressive axial bar stress. Each selected case uses an equal-weight arithmetic mean of signed bar stresses within the rib bay; tension offsets compression. RF 99 means complete recovery with no average compression, and does not mean every bar is in tension. ':euler?'Euler reserve factor = critical column load / governing recovered compression. RF 99 denotes a completely recovered column with no compression. ':'Reserve factor = material allowable / selected property stress envelope. A shared property retains one full-region result; it is never divided into rib-bay values. ')+'Reserve-factor colors use fixed limits 0 and 2, saturating above 2. Both red/blue palettes are red below 1, blue above 1, and neutral exactly at 1. Values above 2 have dark-orange numbers. Yellow overrides the palette when RF > 1 and every relevant dimension is confirmed at minimum gauge. Unavailable or incomplete results have no color. SOL106 ratios are demand checks, not predicted failure load multipliers.';
  return{report,groups,group,view,rows,matrix,scale:scale(rows),note,palette:PALETTES.some(([id])=>id===input.palette)?input.palette:'signed',generated:input.generated===true,filter:String(input.filter||''),caseScopeLabel:String(input.caseScopeLabel||''),error:String(input.error||''),presentation:PRESENTATIONS.some(([id])=>id===input.presentation)?input.presentation:'reserve_factor'};
 }
 const escapeHTML=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const escapeMD=v=>String(v??'').replace(/\\/g,'\\\\').replace(/[|*_`\[\]<>]/g,'\\$&').replace(/\r?\n/g,'<br>');
 function notes(model){
  const report=model.report||{},euler=report.failureMode==='euler_column',blade=report.failureMode==='stringer_blade',skin=report.failureMode==='skin_buckling',method={maximum:'Maximum',mean:'Average',trimmed_mean:'Average below percentile'}[report.method]||report.method||'Unspecified';
  return['Presentation: '+(PRESENTATIONS.find(([id])=>id===model.presentation)?.[1]||'Minimum RF'),'Yellow: RF > 1 and all relevant dimensions confirmed at their enforced minimum. Unknown gauges and incomplete assessments retain their ordinary treatment. A complete RF 99 no-demand sentinel can be yellow at minimum gauge; 99 remains a sentinel, not a computed margin.','Failure mode: '+(report.failureMode==='minimum_rf'?'Minimum RF across applicable failure modes':skin?'Skin panel buckling':blade?'Stringer blade instability':euler?'Euler column buckling':'Von Mises stress'),'Group: '+(GROUPS[model.group]||(skin?'All skin panels':blade?'All stringer blades':euler?'All stringer columns':'All properties')),'Selected view: '+(model.view==='grid'?'Structural group grid':'Property list')+'. Export layout: one row per '+(skin?'physical skin panel.':blade?'physical stringer blade.':euler?'physical stringer column.':'property.'),'Color scale: '+(PALETTES.find(([id])=>id===model.palette)?.[1]||PALETTES[0][1])+'; fixed reserve-factor limits 0 to 2.',model.filter?'Filter: '+model.filter:'',model.caseScopeLabel?'Load-case scope: '+model.caseScopeLabel:'',skin?'Demand: combined area-averaged signed membrane stresses in panel axes. The lowest converged plate buckling multiplier over the selected cases governs.':blade?'Demand: equal-weight arithmetic mean of signed axial bar stresses per rib-bay stringer and case; the smallest critical-stress / average-compression ratio governs.':euler?'Demand: recovered axial compression at each section cut over each physical column and selected case set.':'Envelope: '+method+(report.method==='trimmed_mean'?' / '+format(report.percentile)+'th percentile':''),(euler?'Force values: '+(report.forceUnit||'source force units'):'Stress values: '+(report.stressUnit||'unspecified units'))+'; reserve factors: dimensionless.',model.note,model.error||'',report.note||'',...(report.excludedCases||[]).map(c=>'Excluded '+c.label+': '+c.reason),...(report.missingCases||[]).map(c=>'Missing '+c.label+': '+c.reason)].filter(Boolean);
 }
 function rawTable(model){
  const report=model.report||{},euler=report.failureMode==='euler_column',blade=report.failureMode==='stringer_blade',factor=finite(report.stressFactor)?report.stressFactor:1,stress=v=>finite(v)?format(v*factor):'Unavailable',unit=report.stressUnit||'unspecified units';
  if(report.failureMode==='minimum_rf'){
   const headers=['Property','Type','Material IDs','Physical locations','Scope','Minimum reserve factor','Critical case','Governing failure mode','Governing physical scope','Recovery','Assessment','Known minimum RF'];
   const rows=model.rows.map(item=>{const r=item.record||{};return[item.label,item.propertyType,(r.materialIds||[]).join('; '),item.locations.map(p=>(GROUPS[p.group]||p.group)+' / '+p.rowLabel+' / '+p.columnLabel).join('; '),item.shared?'Shared property region':'Property region',format(item.value),r.envelopeCaseLabel||'Unavailable',r.combined?.governingModeLabel||'Unavailable',r.combined?.governingScope||'Unavailable',r.coverage?r.coverage.recovered+' / '+r.coverage.total:'Unavailable',item.reason,format(r.combined?.knownMinimum)];});
   return{title:'Minimum reserve factors across failure modes',headers,rows};
  }
  if(report.failureMode==='skin_buckling'){
   const headers=['Skin panel','Type','Material IDs','Physical locations','Scope','Reserve factor','Average sigma x ('+unit+')','Average sigma y ('+unit+')','Average tau xy ('+unit+')','Governing load case','Recovery','Assessment','Panel length (m)','Panel width (m)','Skin buckling fixity coefficient','Source shells','Basis order','Convergence error','Property IDs'];
   const rows=model.rows.map(item=>{const r=item.record,p=r?.skinBuckling||{};return[item.label,item.propertyType,(r?.materialIds||[]).join('; '),item.locations.map(p=>(GROUPS[p.group]||p.group)+' / '+p.rowLabel+' / '+p.columnLabel+(p.segment>1?' / segment '+p.segment:'')).join('; '),'Physical skin panel',format(item.value),stress(p.averageStressX),stress(p.averageStressY),stress(p.averageShear),r?.envelopeCaseLabel||'Unavailable',r?.coverage?r.coverage.recovered+' / '+r.coverage.total:'Unavailable',item.reason,format(p.length),format(p.width),format(p.fixityCoefficient),format(p.sourceCount),format(p.basisOrder),format(p.convergenceError),(r?.propertyIds||[item.pid]).join('; ')];});
   return{title:'Skin panel buckling reserve factors',headers,rows};
  }
  const headers=[blade?'Stringer blade':euler?'Stringer column':'Property','Type','Material IDs','Physical locations','Scope','Reserve factor',blade?'Critical buckling stress ('+unit+')':euler?'Critical load ('+(report.forceUnit||'source force units')+')':'Allowable ('+unit+')',blade?'Average compression ('+unit+')':euler?'Governing compression ('+(report.forceUnit||'source force units')+')':'Envelope ('+unit+')','Governing load case','Recovery','Assessment',...(blade?['Signed average axial stress ('+unit+')','Clear web height (mm)','Web thickness (mm)','Buckling coefficient k','Source bars','Critical element ID','Critical property ID']:euler?['Length ('+(report.lengthUnit||'source length units')+')','End-fixity coefficient c','Weakest EI']:[])];
  const rows=model.rows.map(item=>{const r=item.record;return[item.label,item.propertyType,(r?.materialIds||[]).join('; '),item.locations.map(p=>(GROUPS[p.group]||p.group)+' / '+p.rowLabel+' / '+p.columnLabel+(p.segment>1?' / segment '+p.segment:'')).join('; '),blade?'Physical stringer blade':euler?'Physical column':item.shared?'Shared property region':item.locations.length?'Local property region':'Property region',format(item.value),blade?stress(r?.blade?.criticalStress):euler?format(r?.euler?.criticalLoad):stress(r?.allowableStress),blade?stress(r?.blade?.compressionDemand):euler?format(r?.euler?.compressionDemand):stress(r?.envelopeStress),r?.envelopeCaseLabel||'Unavailable',r?.coverage?r.coverage.recovered+' / '+r.coverage.total:'Unavailable',item.reason,...(blade?[stress(r?.blade?.averageStress),finite(r?.blade?.clearHeight)?format(r.blade.clearHeight*1000):'Unavailable',finite(r?.blade?.thickness)?format(r.blade.thickness*1000):'Unavailable',format(r?.blade?.coefficient),format(r?.blade?.sourceCount),format(r?.blade?.criticalEid),format(r?.blade?.criticalPid)]:euler?[format(r?.euler?.length),format(r?.euler?.endFactor),format(r?.euler?.weakestEI)]:[])];});
  return{title:blade?'Stringer blade instability reserve factors':euler?'Euler column reserve factors':'Reserve factor table',headers,rows};
 }
 function table(model){const t=rawTable(model);t.headers.push('Presentation','Presented label','Minimum gauge');t.rows.forEach((r,i)=>{const item=model.rows[i];r.push(PRESENTATIONS.find(([id])=>id===model.presentation)?.[1]||'Minimum RF',finite(item.value)?presentationValue(item.record,model.presentation,model.report?.failureMode):'Unassessed',minimumGaugeLabel(item.record));});return t;}
 function csvCell(value){let s=String(value??'');if(/^\s*[=+@-]/.test(s))s="'"+s;return '"'+s.replaceAll('"','""')+'"';}
 function csv(model){const t=table(model);return '\uFEFF'+[[t.title],...notes(model).map(n=>[n]),[],t.headers,...t.rows].map(row=>row.map(csvCell).join(',')).join('\r\n')+'\r\n';}
 function markdown(model){const t=table(model);return '# '+t.title+'\n\n'+notes(model).map(escapeMD).join('\n\n')+'\n\n| '+t.headers.map(escapeMD).join(' | ')+' |\n| '+t.headers.map(()=>'---').join(' | ')+' |\n'+t.rows.map(row=>'| '+row.map(escapeMD).join(' | ')+' |').join('\n')+'\n';}
 function html(model){const t=table(model);return '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>'+t.title+'</title><style>body{font:15px/1.5 system-ui,sans-serif;color:#163047;background:white;margin:2rem}table{border-collapse:collapse;width:100%}td,th{padding:.5rem;border:1px solid #bfd0dd;text-align:left}th{background:#e4eef6}tr{break-inside:avoid}</style></head><body><h1>'+t.title+'</h1>'+notes(model).map(n=>'<p>'+escapeHTML(n)+'</p>').join('')+'<table><thead><tr>'+t.headers.map(n=>'<th>'+escapeHTML(n)+'</th>').join('')+'</tr></thead><tbody>'+t.rows.map((row,i)=>'<tr>'+row.map((v,j)=>'<td'+(j===5?valueStyle(model.rows[i].value,model.scale,model.palette,model.rows[i].record):'')+'>'+(j===5&&model.rows[i].value>2?'<span style="background:#fff1df;color:#963e00;padding:2px 4px;border-radius:2px">'+escapeHTML(v)+'</span>':escapeHTML(v))+'</td>').join('')+'</tr>').join('')+'</tbody></table></body></html>\n';}
 return{GROUPS,PARTS,FAMILIES,PALETTES,PRESENTATIONS,FAILURE_MODES,MINIMUM_GAUGE_COLOR,atMinimumGauge,minimumGaugeLabel,presentationValue,format,panelLocations,compact,reserveValue,build,scale,valueColor,valueInk,colorStops,table,notes,csv,markdown,html};
});
