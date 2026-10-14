'use strict';
const assert=require('node:assert/strict'),W=require('../web/workspace.js');
const view=variant=>({controls:{'surface-mode':'solid'},layers:{UPPER_SKIN:true},camera:{target:[0,0,0],alpha:1,beta:.7,radius:12},activeCase:1,
 resultVariant:variant,workspace:{activeTab:'results',width:430,collapsed:false,maximizedTab:null},reference:{selectedIndex:-1,mode:'off'}});
(async()=>{
 let checks=0;
 for(const variant of ['','sol101','sol103','sol105','sol106','sensitivity_sensitivity_baseline_101_sol101','sensitivity_sensitivity_20261008_122621_3Gw1JA_sol103','sensitivity_sensitivity_20261009_123456_A1b2c3_sol105','sensitivity_run_sol106']){
  const saved=await W.snapshot({'output.solution':'101'},null,view(variant));
  assert.equal(W.parse(JSON.stringify(saved)).data.view.resultVariant,variant);checks++;
 }
 for(const variant of ['sensitivity_../private_sol101','sensitivity_bad/path_sol101','sensitivity_bad\\path_sol101','sensitivity_<script>_sol101','sensitivity_run_sol999','sensitivity_run','sensitivity__sol101','arbitrary','sensitivity_'+'a'.repeat(181)+'_sol101',123,null]){
  assert.throws(()=>W.validateView(view(variant)),/Invalid selected result analysis/);checks++;
 }
 console.log('Sensitivity baseline variant persistence: '+checks+' checks passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
