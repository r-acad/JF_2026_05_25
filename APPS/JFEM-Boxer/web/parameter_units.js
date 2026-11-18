/* User-facing component dimensions use mm. Study and solver data stay in SI.
 * Remember an untouched displayed value so shortening a loaded label never
 * changes its original SI double, including an irrational minimum gauge.
 */
(function(root,factory){
 const api=factory(root,typeof module==='object'&&module.exports?require('./numeric_inputs.js'):root.WingNumericInputs);
 if(typeof module==='object'&&module.exports)module.exports=api;
 else{root.WingParameterUnits=api;if(root.document)api.install(root.document);}
})(globalThis,function(root,numeric){
 'use strict';
 const DIMENSION_KEYS=Object.freeze([
  'properties.t_skin_upper','properties.t_skin_lower','properties.t_spar_web','properties.t_rib_web',
  'properties.spar_cap_side','properties.runout_side',
  ...['stringer','rib_stiffener'].flatMap(family=>['flange_width','height','flange_thickness','web_thickness'].map(field=>'properties.'+family+'_'+field)),
  'leading_edge.t_skin','leading_edge.t_rib',
  ...['upper_thickness','lower_thickness','web_thickness','rib_thickness'].map(field=>'movable_structure.surfaces#'+field),
  'movable_structure.attachments#lug_thickness'
 ]),dimensions=new Set(DIMENSION_KEYS),loaded=new WeakMap(),installed=new WeakSet();
 const isMillimetreKey=key=>dimensions.has(key),factor=key=>isMillimetreKey(key)?1000:key==='material.E'?1e-9:1;
 const displayUnit=(key,unit='')=>isMillimetreKey(key)?'mm':key==='material.E'?'GPa':unit;
 const toDisplay=(key,value)=>typeof value==='number'?value*factor(key):value;
 const toModel=(key,value)=>Number(value)/factor(key);
 function displayHelp(key,text=''){
  if(!isMillimetreKey(key))return text;
  return text.replace(/\bin metres\b/g,'in millimetres').replace(/\bin meters\b/g,'in millimetres')+
   (text?' ':'')+'Enter millimetres. Saved Studies and solver calculations retain metres.';
 }
 const keyFor=input=>input?.dataset?.parameterUnitKey||input?.id?.replace(/^p-/,'');
 function readModel(input,key=keyFor(input)){
  if(!input||input.value.trim()==='')return NaN;
  const saved=loaded.get(input);
  if(saved&&saved.key===key&&input.value===saved.text)return saved.value;
  // Unmarked controls in standalone/legacy editors still contain SI values.
  const value=numeric?.value(input)??Number(input.value);
  return input.dataset?.parameterUnitKey===key?toModel(key,value):value;
 }
 function writeModel(input,key,value){
  if(!input)return;
  input.dataset.parameterUnitKey=key;
  input.dataset.parameterDisplayUnit=displayUnit(key);
  const display=toDisplay(key,value),text=factor(key)!==1&&typeof display==='number'&&Number.isFinite(display)?numeric?.format(display)??String(display):String(display??'');
  input.value=text;loaded.set(input,{key,text,value});
 }
 function install(doc){
  if(installed.has(doc))return;
  installed.add(doc);
  doc.addEventListener('input',event=>{loaded.delete(event.target);},true);
 }
 return{DIMENSION_KEYS,isMillimetreKey,displayUnit,displayHelp,toDisplay,toModel,readModel,writeModel,install,
  displayStep:(key,step='any')=>isMillimetreKey(key)?'0.1':step};
});
