/* Numeric entry policy. Only committed user edits are quantized: loaded Study
 * values and computed solver/geometry values retain their original precision.
 * Engineering notation keeps small SI dimensions nonzero without changing units.
 */
(function(root,factory){
 const api=factory();
 if(typeof module==='object'&&module.exports)module.exports=api;
 else {root.WingNumericInputs=api;if(root.document)api.install(root.document);}
})(globalThis,function(){
 'use strict';
 const installations=new WeakMap(),internalEvents=new WeakSet(),steps=new WeakMap();
 const trim=text=>text.includes('.')?text.replace(/0+$/,'').replace(/\.$/,''):text;
 function format(value,{integer=false}={}){
  if(typeof value!=='number'||!Number.isFinite(value))return String(value);
  if(value===0)return '0';
  // Counts and identifiers must remain exact; rounding an entity ID selects
  // a different object. Integer-field validation remains the editor's job.
  if(integer&&Number.isInteger(value))return String(value);
  const rounded=Number(value.toPrecision(5)),plain=String(rounded);
  if(Number.isFinite(rounded)&&Math.abs(rounded)<1e5&&!/[eE]/.test(plain)&&(!plain.includes('.')||plain.split('.')[1].length<=3))return plain;
  const exponent=3*Math.floor(Math.log10(Math.abs(value))/3);
  // Division by 10**exponent underflows for subnormal doubles. Scaling in
  // decimal scientific notation works for that extreme as well.
  const parts=value.toExponential(15).split('e');
  const mantissa=Number(parts[0])*10**(Number(parts[1])-exponent);
  const places=Math.max(0,Math.min(3,5-1-Math.floor(Math.log10(Math.abs(mantissa)))));
  let text=trim(mantissa.toFixed(places))+(exponent?'e'+exponent:'');
  // Do not turn the largest finite double into Infinity by rounding upward.
  if(!Number.isFinite(Number(text))){
   const scale=10**places,bounded=Math.trunc(mantissa*scale)/scale;
   text=trim(bounded.toFixed(places))+(exponent?'e'+exponent:'');
  }
  return text;
 }
 function normalizeText(raw,options={}){
  const text=String(raw).trim();
  if(text===''||!Number.isFinite(Number(text)))return String(raw);
  return format(Number(text),options);
 }
 function isField(input){
  return input?.tagName==='INPUT'&&!input.readOnly&&!input.disabled&&
   (input.type==='number'||input.type==='text'&&['decimal','numeric'].includes(input.inputMode))&&
   input.dataset.numericPrecision!=='exact';
 }
 function isInteger(input){
  return input.dataset.numericPrecision==='integer'||input.inputMode==='numeric'||(steps.get(input)||input.step)==='1';
 }
 function reconcileStep(input){
  if(!isField(input)||input.type!=='number')return;
  const current=input.getAttribute('step'),step=current&&current!=='any'?current:steps.get(input);
  if(!step||!(Number(step)>0))return;
  steps.set(input,step);input.step=step;
  // Step is an editing increment, not a physical accuracy restriction. Keep
  // min/max validation, but accept finite non-grid values from valid Studies.
  if(input.validity.stepMismatch)input.step='any';
 }
 function formatExact(input){
  if(!isField(input)||input.value.trim()==='')return;
  const old=Number(input.value),next=normalizeText(input.value,{integer:isInteger(input)});
  // A shorter spelling is safe on load only if every numeric reader still
  // receives the identical double. Values needing quantization wait for edits.
  if(Number.isFinite(old)&&Number(next)===old)input.value=next;
  reconcileStep(input);
 }
 function install(doc){
  if(installations.has(doc))return installations.get(doc);
  const dirty=new Set(),recreated=new Set();let committing=false;
  const key=input=>input.dataset.editorId||null;
  function mark(event){
   if(internalEvents.has(event)||!isField(event.target))return;
   dirty.add(event.target);const id=key(event.target);if(id)recreated.add(id);
   reconcileStep(event.target);
  }
  function commit(input){
   if(!isField(input)||!dirty.has(input)&&!(key(input)&&recreated.has(key(input))))return false;
   dirty.delete(input);if(key(input))recreated.delete(key(input));
   const old=input.value,next=normalizeText(old,{integer:isInteger(input)});
   if(next===old){reconcileStep(input);return false;}
   input.value=next;
   reconcileStep(input);
   // Existing editors generally store drafts on input, not on blur. Refresh
   // those drafts synchronously before their change/blur/save handlers run.
   const event=new doc.defaultView.Event('input',{bubbles:true});
   internalEvents.add(event);input.dispatchEvent(event);return true;
  }
  function commitAll(){
   if(committing)return;committing=true;
   try{
    for(const input of [...dirty])if(input.isConnected)commit(input);else dirty.delete(input);
    if(recreated.size)for(const input of doc.querySelectorAll('input[data-editor-id]'))commit(input);
   }finally{committing=false;}
  }
  doc.addEventListener('input',mark,true);
  doc.addEventListener('change',event=>commit(event.target),true);
  doc.addEventListener('blur',event=>commit(event.target),true);
  const nativeStep=input=>{
   const step=steps.get(input);if(!isField(input)||!step)return;
   input.step=step;
   // Native number spinners/ArrowUp/ArrowDown use the original increment.
   // After their default action, relax an unchanged off-grid value again.
   doc.defaultView.setTimeout(()=>reconcileStep(input),0);
  };
  doc.addEventListener('pointerdown',event=>nativeStep(event.target),true);
  doc.addEventListener('keydown',event=>{
   if(event.key==='Enter')commit(event.target);
   else if(event.key==='ArrowUp'||event.key==='ArrowDown')nativeStep(event.target);
  },true);
  const visit=node=>{if(node.nodeType!==1)return;if(node!==doc.activeElement)formatExact(node);for(const input of node.querySelectorAll('input'))if(input!==doc.activeElement)formatExact(input);};
  const observer=new doc.defaultView.MutationObserver(records=>{for(const record of records)for(const node of record.addedNodes)visit(node);});
  observer.observe(doc.documentElement,{childList:true,subtree:true});visit(doc.documentElement);
  const api={commit,commitAll,observer};installations.set(doc,api);return api;
 }
 function commitAll(doc){install(doc).commitAll();}
 return {format,normalizeText,isField,isInteger,formatExact,reconcileStep,install,commitAll};
});
