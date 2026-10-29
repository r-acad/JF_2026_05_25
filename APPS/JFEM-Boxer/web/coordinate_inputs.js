/* User-defined non-dimensional locations use five significant figures. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingCoordinates=api;})(globalThis,function(){
 'use strict';
 const isKey=key=>/(?:^|[._-])(?:eta|d?x_?c|z_?c|[xz]_over_c)(?:$|[._-])/.test(key)||['front_spar_start','front_spar_end','hinge_start','hinge_end'].includes(key);
 const round=value=>typeof value==='number'&&Number.isFinite(value)?Number(value.toPrecision(5)):value;
 function roundInputs(value,key=''){
  if(Array.isArray(value))return value.map(v=>Array.isArray(v)&&v.length===2&&typeof v[0]==='string'?[v[0],roundInputs(v[1],v[0])]:roundInputs(v,key));
  if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).map(([k,v])=>[k,roundInputs(v,k)]));
  return isKey(key)?round(value):value;
 }
 function isField(input){
  if(input?.tagName!=='INPUT'||input.type!=='number')return false;
  if(isKey(input.id.replace(/^p-/,''))||isKey(input.dataset.field||'')||isKey(input.name||''))return true;
  const label=(input.closest('label')?.textContent||input.getAttribute('aria-label')||'');
  return /\beta\b|\u03b7|[xz]\s*\/\s*c/i.test(label);
 }
 function format(input){if(isField(input)&&input.value.trim()!==''&&Number.isFinite(input.valueAsNumber))input.value=String(round(input.valueAsNumber));}
 function install(doc){
  const visit=node=>{if(node.nodeType!==1)return;if(node!==doc.activeElement)format(node);for(const input of node.querySelectorAll('input[type=number]'))if(input!==doc.activeElement)format(input);};
  const observer=new doc.defaultView.MutationObserver(records=>{for(const r of records)for(const node of r.addedNodes)visit(node);});
  observer.observe(doc.documentElement,{childList:true,subtree:true});visit(doc.documentElement);
  doc.addEventListener('change',event=>{const input=event.target;if(!isField(input))return;const old=input.value;format(input);if(input.value!==old)input.dispatchEvent(new doc.defaultView.Event('input',{bubbles:true}));},true);
  return observer;
 }
 return{isKey,round,roundInputs,isField,install};
});
