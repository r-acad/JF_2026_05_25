/* Display adapters only: result arrays, persisted ranges and CSV remain canonical. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingResultDisplay=api;})(globalThis,function(){
 'use strict';
 function stressUnit(unit=''){return /^Pa(?=$|\s*\/)/.test(unit)?{unit:unit.replace(/^Pa/,'GPa'),factor:1e-9}:{unit,factor:1};}
 function stressValue(value,unit){return typeof value==='number'?value*stressUnit(unit).factor:value;}
 function stressText(value,unit,format=String){return format(stressValue(value,unit))+(unit?' '+stressUnit(unit).unit:'');}
 function stressSummary(value,format=String){
  if(typeof value!=='string')return value;
  const match=value.match(/^\s*([+-]?[\d.]+(?:e[+-]?\d+)?)(?:\s+to\s+([+-]?[\d.]+(?:e[+-]?\d+)?))?\s+Pa$/i);
  return match&&Number.isFinite(Number(match[1]))?format(Number(match[1])*1e-9)+(match[2]?' to '+format(Number(match[2])*1e-9):'')+' GPa':value;
 }
 const stressFields=new Set(['normal_x','normal_y','shear_xy','von_mises','major','minor','axial','axial_end_a','axial_end_b','torsional',...Array.from({length:8},(_,i)=>'p'+(i+1))]);
 function stressRecord(record){
  const sourceUnit=/^GPa\b/.test(record?.stress_units||'')?'GPa':'Pa';
  function visit(value,inStress=false){
   if(Array.isArray(value))return value.map(item=>visit(item,inStress));
   if(!value||typeof value!=='object')return value;
   return Object.fromEntries(Object.entries(value).map(([key,item])=>[key,key==='stress_units'&&typeof item==='string'?item.replace(/^Pa\b/,'GPa'):inStress&&stressFields.has(key)&&typeof item==='number'?stressValue(item,sourceUnit):visit(item,inStress||key==='stress')]));
  }
  return visit(record);
 }
 function peakProperties(shape,nodeIds,elements){
  let maximum=-Infinity;const magnitudes=[];
  for(let i=0;i<nodeIds.length;i++){const value=Math.hypot(shape[3*i],shape[3*i+1],shape[3*i+2]);magnitudes.push(value);if(Number.isFinite(value))maximum=Math.max(maximum,value);}
  if(!Number.isFinite(maximum))return{maximum:null,nodes:[],pids:[]};
  // Float32 payloads can round equivalent peaks slightly differently.
  const tolerance=maximum*1e-6,peaks=new Map();
  for(let i=0;i<nodeIds.length;i++)if(Number.isFinite(magnitudes[i])&&Math.abs(magnitudes[i]-maximum)<=tolerance)peaks.set(i,{id:nodeIds[i],pids:new Set()});
  for(const element of elements.values()){
   const pid=element.group?.pid;
   if(!Number.isInteger(pid)||pid<=0)continue;
   for(const index of element.nodes||[]){const peak=peaks.get(index);if(peak)peak.pids.add(pid);}
  }
  const nodes=[...peaks.values()].map(row=>({id:row.id,pids:[...row.pids].sort((a,b)=>a-b)})).sort((a,b)=>a.id-b.id);
  return{maximum,nodes,pids:[...new Set(nodes.flatMap(row=>row.pids))].sort((a,b)=>a-b)};
 }
 function peakDescription(peak){
  if(!peak.nodes.length)return'Maximum translation unavailable';
  if(peak.maximum===0)return'All '+peak.nodes.length+' GRIDs have zero translation; no unique maximum';
  const ids=pids=>pids.slice(0,16).join(', ')+(pids.length>16?' … ('+pids.length+' PIDs total)':'');
  return'Max |u|: '+peak.nodes.slice(0,8).map(row=>'GRID '+row.id+' · '+(row.pids.length?'PID'+(row.pids.length>1?'s ':' ')+ids(row.pids):'no incident property')).join('; ')+
   (peak.nodes.length>8?'; '+(peak.nodes.length-8)+' additional tied GRIDs. Incident PIDs across all tied GRIDs: '+(ids(peak.pids)||'none'):'');
 }
 function buckling(multiplier,loadFactor=1,imported=false){
  return{factor:multiplier*(imported?1:loadFactor),basis:imported?'source deck preload':'base case preload',
   explanation:imported?'λ multiplies the complete preload defined by the source deck for this subcase. No generated load multiplier is applied.':
    'λ multiplies the solved preload. The displayed factor is λ × the case load multiplier, relative to the base case at multiplier 1. It includes the combined aerodynamic or prescribed loads and inertial loads present in that case; it is not aircraft g.'};
 }
 function bucklingHelp(){return 'λ is the linear buckling eigenvalue multiplying the solved static preload: (K + λ Kg) φ = 0. For generated cases, × base-case preload = λ × the case load multiplier; the base case has multiplier 1. Example: λ = 2.7367 and case multiplier 1.5 give 4.10505 × base-case preload. This scales the complete selected load pattern, including aerodynamic/prescribed forces, moments and inertial loads present in the preload, not aerodynamic loads alone or aircraft g. Imported decks use × source-deck preload = λ, because their deck already defines the load scaling. Each mode shape is normalized and has arbitrary amplitude; its displacement is not the physical deflection at buckling. Linear buckling predicts an idealized instability and does not include postbuckling or imperfection effects.';}
 return{stressUnit,stressValue,stressText,stressSummary,stressRecord,peakProperties,peakDescription,buckling,bucklingHelp};
});
