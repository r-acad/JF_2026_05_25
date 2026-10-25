'use strict';
const assert=require('node:assert/strict'),W=require('../web/workspace.js');
const view=controls=>({controls,layers:{},camera:{target:[0,0,0],alpha:0,beta:1,radius:10},workspace:{activeTab:'displaygeometry',width:360,collapsed:false},activeCase:1});
let checks=0;
for(const n of ['1','10','200'])for(const enabled of [true,false]){
 const controls={'show-loft-cuts':enabled,'loft-cut-count':n,'loft-cut-color':'#ff4080','show-reference-loft-cuts':!enabled,'reference-loft-cut-color':'#ff40d8'},saved=W.completeView(view(controls),null);
 assert.deepEqual(saved.controls,{'show-fuel-tank':true,...controls});checks++;
 const nodes={'show-loft-cuts':{checked:!enabled},'loft-cut-count':{value:'99'},'loft-cut-color':{value:'#00ffff'},'show-reference-loft-cuts':{checked:enabled},'reference-loft-cut-color':{value:'#000000'}};
 W.applyControls({getElementById:id=>nodes[id]},saved.controls);
 assert.equal(nodes['show-loft-cuts'].checked,enabled);assert.equal(nodes['loft-cut-count'].value,n);assert.equal(nodes['loft-cut-color'].value,'#ff4080');assert.equal(nodes['show-reference-loft-cuts'].checked,!enabled);assert.equal(nodes['reference-loft-cut-color'].value,'#ff40d8');checks++;
}
for(const n of ['','0','201','1.1','NaN','Infinity']){assert.throws(()=>W.validateView(view({'loft-cut-count':n,'loft-cut-color':'#ff4080'})));checks++;}
assert.throws(()=>W.validateView(view({'show-loft-cuts':'true'})));checks++;
assert.throws(()=>W.validateView(view({'show-reference-loft-cuts':'true'})));checks++;
for(const color of ['cyan','#fff','#1234567',''])for(const id of ['loft-cut-color','reference-loft-cut-color']){assert.throws(()=>W.validateView(view({[id]:color})));checks++;}
const defaults={'show-loft-cuts':{defaultChecked:false},'loft-cut-count':{defaultValue:'10'},'loft-cut-color':{defaultValue:'#00ffff'},'show-reference-loft-cuts':{defaultChecked:false},'reference-loft-cut-color':{defaultValue:'#ff40d8'}};
for(const old of [W.completeView(view({}),{getElementById:id=>defaults[id]}),W.newModelView({getElementById:id=>defaults[id]})]){
 assert.equal(old.controls['show-loft-cuts'],false);assert.equal(old.controls['loft-cut-count'],'10');assert.equal(old.controls['loft-cut-color'],'#00ffff');assert.equal(old.controls['show-reference-loft-cuts'],false);assert.equal(old.controls['reference-loft-cut-color'],'#ff40d8');checks++;
}
console.log(JSON.stringify({passed:true,checks,scope:'Loft-cut Study roundtrip, invalid-count rejection and defaults on older/new models'}));
