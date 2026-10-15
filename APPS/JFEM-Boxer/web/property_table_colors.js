/* Colors describe effective, active values in the visible property table. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./color_scales.js'):root.WingColorScales);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingPropertyTableColors=api;})(globalThis,function(colors){
 'use strict';
 const PALETTES={viridis:'Viridis',spectrum:'Spectrum',inferno:'Inferno',coolwarm:'Blue–red',grayscale:'Grayscale',signed:'Signed red (-) / blue (+)'};
 const categorical=['#6db3dd','#e6a85a','#b799dc','#75c3a6','#df8da5','#c4c45a','#a4b3c3','#bf986b'];
 function dormant(kind,value,field){
  if(kind==='ribstiffeners'&&value.enabled===false&&field!=='enabled')return true;
  if(['stringers','ribstiffeners','sparcaps'].includes(kind))return false;
  return value.kind==='sandwich'?['thickness','material'].includes(field):['face_thickness','core_thickness','face_material','core_material'].includes(field);
 }
 function build(api,snapshot,kind,layout,field){
  const cells=new Map(),categories=new Map();let min=Infinity,max=-Infinity,count=0,inactive=0;
  const names=new Map(api.materialList(snapshot.parameters).map(m=>[m.id,m.name]));
  for(const list of layout.cells.values())for(const panel of list){
   const effective=api.effective(snapshot,panel,kind),value=effective[field.name],active=!dormant(kind,effective,field.name),cell={value,active};cells.set(panel.key,cell);
   if(!active){inactive++;continue;}
   if(field.type==='number'){if(!Number.isFinite(value)){cell.active=false;continue;}min=Math.min(min,value);max=Math.max(max,value);count++;}
   else{const key=String(value);if(value===undefined){cell.active=false;continue;}count++;if(!categories.has(key))categories.set(key,{value,label:field.type==='material'?(names.get(Number(value))||'Missing material')+' (ID '+value+')':field.type==='boolean'?(value?'On':'Off'):value==='sandwich'?'Sandwich':'Monolithic'});}
  }
  const entries=[...categories.values()].sort((a,b)=>field.type==='material'?Number(a.value)-Number(b.value):String(a.value).localeCompare(String(b.value)));
  return {cells,categories:entries,min:count&&field.type==='number'?min:null,max:count&&field.type==='number'?max:null,count,inactive,numeric:field.type==='number',unit:field.unit||'',field};
 }
 function categoryColor(value){let hash=0;for(const c of String(value))hash=(hash*31+c.charCodeAt(0))>>>0;return categorical[hash%categorical.length];}
 function valueColor(value,scale,palette='viridis'){
  if(!scale.numeric)return categoryColor(value);
  if(!Number.isFinite(value)||!Number.isFinite(scale.min)||!Number.isFinite(scale.max))return null;
  return colors.css(colors.valueColor(PALETTES[palette]?palette:'viridis',value,scale.min,scale.max));
 }
 function foreground(background){const numbers=background.startsWith('#')?background.slice(1).match(/../g).map(c=>parseInt(c,16)):background.match(/\d+/g).map(Number),linear=n=>{const v=n/255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;},l=.2126*linear(numbers[0])+.7152*linear(numbers[1])+.0722*linear(numbers[2]);return(l+.05)/.05>=1.05/(l+.05)?'#000000':'#ffffff';}
 function gradient(scale,palette='viridis'){
  if(!Number.isFinite(scale.min))return '';
  return colors.gradient(PALETTES[palette]?palette:'viridis',scale.min,scale.max);
 }
 return{PALETTES,dormant,build,categoryColor,valueColor,foreground,gradient};
});
