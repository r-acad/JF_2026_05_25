'use strict';
// Portable Study serialization contract; Node.js built-ins only.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const W=require('../web/workspace.js'),sandbox={};
vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../web/sensitivity.js'),'utf8'),sandbox);
const parse=value=>JSON.parse(JSON.stringify(sandbox.WingSensitivity.parse(value)));
const view={controls:{'surface-mode':'solid'},layers:{},camera:{target:[0,0,0],alpha:1,beta:.7,radius:12},activeCase:1,
 workspace:{activeTab:'sensitivity',width:430,collapsed:false,maximizedTab:null},reference:{selectedIndex:-1,mode:'off'}};
(async()=>{
 const cases=[
  {case_id:2,objective:{type:'shell_stress',element_id:4101,component:'von_mises',surface:'z2'},variables:['properties.panels#upper:bay2:stringer1:segment1#skin#thickness','properties.t_spar','material.E'],derivative_method:'analytic'},
  {case_id:7,objective:{type:'displacement',node_id:38,component:'z'},variables:['nastran.PSHELL#123#T','nastran.MAT1#2#E'],derivative_method:'analytic'},
  {case_id:1,objective:{type:'frequency_eigenvalue',mode:3},variables:[],derivative_method:'analytic'},
  {case_id:4,objective:{type:'buckling_factor',mode:1},variables:['properties.ribs#2#web_thickness'],derivative_method:'operator_differences',relative_step:.005,check_step:false}
 ];
 for(const source of cases){
  const selected=parse(source),saved=await W.snapshot({'sensitivity.settings':JSON.stringify(selected)},null,view);
  const restored=parse(W.parse(JSON.stringify(saved)).data.parameters['sensitivity.settings']);
  assert.deepEqual(restored,selected);assert.deepEqual(restored.variables,source.variables);
 }
 const source={variables:['original']},cloned=sandbox.WingSensitivity.parse(source);cloned.variables.push('separate');assert.deepEqual(source.variables,['original']);
 assert.deepEqual(parse('').variables,[]);
 console.log('Sensitivity Study setup persistence: 6 checks passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
