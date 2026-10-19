'use strict';
const assert=require('node:assert/strict'),W=require('../web/workspace.js');
const view=controls=>({controls,layers:{},camera:{target:[0,0,0],alpha:0,beta:1,radius:10},workspace:{activeTab:'displaygeometry',width:360,collapsed:false},activeCase:1});
let checks=0;
for(const n of ['1','10','200'])for(const enabled of [true,false]){
 const controls={'show-loft-cuts':enabled,'loft-cut-count':n},saved=W.completeView(view(controls),null);
 assert.deepEqual(saved.controls,{'show-fuel-tank':true,...controls});checks++;
 const nodes={'show-loft-cuts':{checked:!enabled},'loft-cut-count':{value:'99'}};
 W.applyControls({getElementById:id=>nodes[id]},saved.controls);
 assert.equal(nodes['show-loft-cuts'].checked,enabled);assert.equal(nodes['loft-cut-count'].value,n);checks++;
}
for(const n of ['','0','201','1.1','NaN','Infinity']){assert.throws(()=>W.validateView(view({'loft-cut-count':n})));checks++;}
assert.throws(()=>W.validateView(view({'show-loft-cuts':'true'})));checks++;
const defaults={'show-loft-cuts':{defaultChecked:false},'loft-cut-count':{defaultValue:'10'}};
for(const old of [W.completeView(view({}),{getElementById:id=>defaults[id]}),W.newModelView({getElementById:id=>defaults[id]})]){
 assert.equal(old.controls['show-loft-cuts'],false);assert.equal(old.controls['loft-cut-count'],'10');checks++;
}
console.log(JSON.stringify({passed:true,checks,scope:'Loft-cut Study roundtrip, invalid-count rejection and defaults on older/new models'}));
