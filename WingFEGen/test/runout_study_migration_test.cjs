'use strict';
const assert=require('node:assert/strict'),W=require('../web/workspace.js');
const study=parameters=>({format:W.FORMAT,version:W.VERSION,parameters,references:[],view:{controls:{},layers:{},camera:{target:[0,0,0],alpha:0,beta:1,radius:10},activeCase:1,workspace:{activeTab:'mesh',width:360,collapsed:false}}});
assert.equal(W.parse(JSON.stringify(study({'box.stringer_pitch':.15}))).data.parameters['mesh.stringer_runout_ratio'],1);
for(const ratio of [.5,.75,1])assert.equal(W.parse(JSON.stringify(study({'mesh.stringer_runout_ratio':ratio}))).data.parameters['mesh.stringer_runout_ratio'],ratio);
console.log('Legacy Study runout layout migration and explicit ratios: 4 checks passed');
