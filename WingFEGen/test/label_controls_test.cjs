'use strict';
const assert=require('node:assert/strict'),W=require('../web/workspace.js');
const ribs='mesh-labels-ribs',stringers='mesh-labels-stringers',none='mesh-labels-none',both='mesh-labels-both';
const view=controls=>({controls,layers:{},camera:{target:[0,0,0],alpha:0,beta:1,radius:10},activeCase:1,workspace:{activeTab:'displaylabels',width:360,collapsed:false}});
const document={getElementById:id=>[ribs,stringers,'show-rib-datums'].includes(id)?{type:'checkbox',defaultChecked:false}:null};
let checks=0;
for(const [selected,expected]of [[none,[false,false]],[ribs,[true,false]],[stringers,[false,true]],[both,[true,true]]]){
 const saved=view(Object.fromEntries([none,ribs,stringers,both].map(id=>[id,id===selected])));
 const parsed=W.parse(JSON.stringify({format:W.FORMAT,version:W.VERSION,parameters:{},references:[],view:saved})).data.view;
 const restored=W.completeView(parsed,document);
 assert.deepEqual([restored.controls[ribs],restored.controls[stringers]],expected);
 assert(!Object.hasOwn(restored.controls,none));assert(!Object.hasOwn(restored.controls,both));checks++;
}
for(const showRibs of [false,true])for(const showStringers of [false,true]){
 const saved=view({[ribs]:showRibs,[stringers]:showStringers,'show-rib-datums':true});
 const restored=W.completeView(saved,document);assert.deepEqual([restored.controls[ribs],restored.controls[stringers]],[showRibs,showStringers]);assert(restored.controls['show-rib-datums']);
 const inputs=new Map([ribs,stringers,'show-rib-datums'].map(id=>[id,{checked:false}]));
 W.applyControls({getElementById:id=>inputs.get(id)},restored.controls);assert.equal(inputs.get(ribs).checked,showRibs);assert.equal(inputs.get(stringers).checked,showStringers);checks++;
}
const defaults=W.completeView(view({}),document);assert.equal(defaults.controls[ribs],false);assert.equal(defaults.controls[stringers],false);checks++;
for(const id of [ribs,stringers,none,both])assert.throws(()=>W.validateView(view({[id]:'true'})),/checkbox/);
assert(!W.CONTROL_IDS.includes(none));assert(!W.CONTROL_IDS.includes(both));
console.log('Independent label controls and legacy Study migration: '+checks+' scenarios passed');
