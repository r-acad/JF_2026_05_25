(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingStiffenedPanels=api;})(globalThis,function(){
 'use strict';
 function color(index){
  const h=((index*.618033988749895)%1)*6,s=.48+.12*(index%3),v=.78+.08*(index%2),c=v*s,x=c*(1-Math.abs(h%2-1)),m=v-c;
  return ([[c,x,0],[x,c,0],[0,c,x],[0,x,c],[x,0,c],[c,0,x]][Math.floor(h)]).map(value=>value+m);
 }
 function index(data){
  const panels=data?.stiffened_panels?.panels||[],byElement=new Map(),byId=new Map(),colors=new Map();
  panels.forEach((panel,i)=>{byId.set(panel.id,panel);colors.set(panel.id,color(i));for(const eid of [...panel.shell_eids,...panel.stringer_eids]){
   if(byElement.has(eid))throw Error('Element '+eid+' belongs to more than one stiffened panel.');byElement.set(eid,panel);
  }});
  return{panels,byElement,byId,colors};
 }
 function contour(index){return{kind:'panels',name:'Stiffened skin panels',location:'element',domain:'all',
  byId:new Map([...index.byElement].map(([eid,panel])=>[eid,panel.id])),colors:index.colors,min:0,max:index.panels.length};}
 return{color,index,contour};
});
