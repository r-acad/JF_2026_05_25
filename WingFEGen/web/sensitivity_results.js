/* Pure scalar-response interpretation. Operator samples are never responses. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingSensitivityResults=api;})(globalThis,function(){
 'use strict';
 function baseline(result){return typeof result?.baseline==='number'?{value:result.baseline,unit:result.unit||''}:result?.baseline||{};}
 function propertyLabel(row,catalog){
  const record=catalog?.variables?.find(item=>item.id===row.id),id=String(row.id||''),label=String(row.label||record?.label||id),pids=row.pids||record?.pids||[];
  const family=id.startsWith('properties.rib_stiffener_')?'Rib stiffener':id.startsWith('properties.stringer_')?'Stringer':/^T\b/.test(label)&&pids.length===1?(pids[0]===14?'Rib stiffener':pids[0]===11?'Stringer':''):'';
  return family&&!label.toLowerCase().startsWith(family.toLowerCase())?family+' · '+label:label;
 }
 function rowEffect(result,row,changePercent=1){
  const base=baseline(result),p=row?.value,d=row?.derivative;
  const unavailable=['failed','unavailable','error'].includes(String(row?.status||'').toLowerCase());
  const valid=!unavailable&&Number.isFinite(p)&&Number.isFinite(d)&&Number.isFinite(base.value)&&Number.isFinite(changePercent);
  if(!valid)return{valid:false,reason:row?.warning||row?.message||'No finite derivative is available.',changePercent};
  const deltaProperty=p*changePercent/100,deltaResponse=d*deltaProperty,predictedResponse=base.value+deltaResponse;
  if(![deltaProperty,p+deltaProperty,deltaResponse,predictedResponse].every(Number.isFinite))return{valid:false,reason:'The proposed change is outside the finite numeric range.',changePercent};
  const ratio=base.value!==0?100*(deltaResponse/base.value):null,normalized=base.value!==0?(p/base.value)*d:null;
  return{valid:true,changePercent,originalProperty:p,deltaProperty,proposedProperty:p+deltaProperty,derivative:d,
   deltaResponse,predictedResponse,baselineResponse:base.value,responseUnit:base.unit||result.unit||'',propertyUnit:row.unit||'',
   percentOfBaseline:Number.isFinite(ratio)?ratio:null,normalizedDerivative:Number.isFinite(normalized)?normalized:null,
   warning:row.warning||'',propertyNonpositive:p>0&&p+deltaProperty<=0};
 }
 function rankEffects(result,changePercent=1,metric='percent',catalog){
  const usePercent=metric==='percent'&&baseline(result).value!==0&&(result?.rows||[]).every(row=>{const effect=rowEffect(result,row,changePercent);return !effect.valid||effect.percentOfBaseline!==null;});
  return(result?.rows||[]).map((row,index)=>({row,index,label:propertyLabel(row,catalog),effect:rowEffect(result,row,changePercent)}))
   .filter(item=>item.effect.valid).map(item=>({...item,metric:usePercent?'percent':'absolute',chartValue:usePercent?item.effect.percentOfBaseline:item.effect.deltaResponse}))
   .sort((a,b)=>Math.abs(b.chartValue)-Math.abs(a.chartValue)||a.index-b.index);
 }
 function summarize(result,changePercent=1,metric='percent',catalog){
  const ranked=rankEffects(result,changePercent,metric,catalog),rows=result?.rows||[],warnings=rows.filter(row=>rowEffect(result,row,changePercent).valid&&(row.status==='warning'||row.warning)).length;
  return{total:rows.length,available:ranked.length,failed:rows.length-ranked.length,warnings,ranked,influential:ranked.slice(0,3),baseline:baseline(result)};
 }
 function objectiveLabel(result){
  const obj=result?.objective||result?.request?.objective||{},component=String(obj.component||'').replaceAll('_',' ');
  if(obj.type==='displacement')return'Node '+obj.node_id+' · displacement '+component;
  if(obj.type==='shell_stress')return'Element '+obj.element_id+' · shell stress '+component+(obj.surface?' · '+obj.surface:'');
  if(obj.type==='bar_stress')return'Element '+obj.element_id+' · beam stress '+component;
  if(obj.type==='frequency_eigenvalue')return'Mode '+obj.mode+' · modal eigenvalue';
  if(obj.type==='buckling_factor')return'Mode '+obj.mode+' · buckling factor';
  return'Selected scalar response';
 }
 return{baseline,propertyLabel,rowEffect,rankEffects,summarize,objectiveLabel};
});
