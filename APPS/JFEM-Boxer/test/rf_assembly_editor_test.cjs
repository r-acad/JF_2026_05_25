'use strict';
// Form-contract tests use a deliberate scope-provider stub. Actual topology
// and numerical membership are verified by rf_panel_scope and native tests.
const assert=require('node:assert/strict'),api=require('../web/rf_assembly_editor.js');
const {context:fixture}=require('./rf_property_editor_test.cjs');
const c=fixture();
c.panels.push({id:3,key:'lower:1:2:1',skin:'lower',rib_bay:1,stringer:2,segment:1,shell_pid:6000003,stringer_pid:7000003,label:'Lower R1-R2, stringer 2'});
c.groups.push({pid:6000003},{pid:7000003});
const scope={key:'compression:lower:1:1:1',kind:'compression_panel',panelKey:c.panels[0].key,label:'Lower R1-R2, stringer 1',editablePropertyIds:[6000001,7000001,6000003],elementIds:[11,12,21]};
c.fixtureScope=scope;
const assessment={available:true,value:.51,mode:'Euler column buckling',caseLabel:'+2.5g',checks:[
 {modeKey:'von_mises',mode:'Skin strength',memberKind:'skin',value:1.2,complete:true,scope:'Selected skin',scopeKey:'skin-strength',caseLabel:'+2.5g'},
 {modeKey:'von_mises',mode:'Stringer strength',memberKind:'stringer',value:.8,complete:true,scope:'Selected stringer',scopeKey:'stringer-strength',caseLabel:'+2.5g'},
 {modeKey:'euler_column',mode:'Euler column buckling',value:.51,complete:true,scope:'Selected stringer and associated skin',scopeKey:c.panels[0].key,caseLabel:'+2.5g'}
],failures:[{mode:'Euler column buckling',value:.51,scope:'Selected column',caseLabel:'+2.5g'}]};
const report={failureMode:'minimum_rf',rows:[],panelAssessment:assessment};
const calls=[],previous=globalThis.WingRFPanelScope;
globalThis.WingRFPanelScope={resolve(context,focus){calls.push({operation:'resolve',context,focus});return context.fixtureScope;},summary(input,current,selected){calls.push({operation:'summary',input,report:current,scope:selected});return current?.panelAssessment||{available:false,reason:'No panel assessment',checks:[],failures:[]};}};
let checks=0;function test(name,run){run();checks++;console.log('PASS '+name);}
try{
 test('The editor delegates picked physical identity and RF summary to the field scope provider',()=>{
  const bundle=api.related(c,6000001,report,{eid:11,scopeKey:'explicit-fragment',detail:{modeKey:'skin_buckling'}});
  assert.equal(bundle.scope,scope);assert.equal(bundle.assessment,assessment);assert.equal(calls.find(call=>call.operation==='resolve').focus.eid,11);
  assert.equal(calls.find(call=>call.operation==='resolve').focus.scopeKey,'explicit-fragment');assert.equal(bundle.panelKey,scope.key);
 });
 test('One stringer and its actual associated skins are editable with no adjacent cards',()=>{
  const bundle=api.related(c,6000001,report);assert.deepEqual(bundle.descriptors.map(d=>d.pid),[6000001,6000003,7000001]);
  assert.equal(bundle.descriptors.filter(d=>d.kind==='stringers').length,1);assert(!bundle.descriptors.some(d=>d.pid===7000003));assert.equal(bundle.sharedPanels,undefined);
 });
 test('Changing the governing mode cannot change the helper-selected panel or editable sections',()=>{
  const before=api.related(c,6000001,report,{eid:11});
  for(const mode of['euler_column','skin_buckling','von_mises']){const next=api.related(c,6000001,{...report,panelAssessment:{...assessment,mode}},{eid:11,detail:{modeKey:mode}});assert.equal(next.scope,before.scope);assert.deepEqual(next.descriptors.map(d=>d.pid),before.descriptors.map(d=>d.pid));}
 });
 test('Plain skin has one scoped skin assessment and no stringer controls',()=>{
  const plain={...c,fixtureScope:{...scope,key:'skin:front',kind:'plain_skin',label:'Front spar-S1',editablePropertyIds:[6000001]}};
  const result=api.related(plain,6000001,{...report,panelAssessment:{...assessment,checks:assessment.checks.filter(check=>check.memberKind==='skin')}});
  assert.equal(result.selectionKind,'plain_skin');assert.deepEqual(result.descriptors.map(d=>d.pid),[6000001]);assert.doesNotMatch(result.explanation,/Euler/);
 });
 test('Shell web and flange IDs stay one section editor',()=>{
  const shell=fixture();shell.parameters['stringers.model']='shell';shell.panels[0].stringer_web_pid=19000001;shell.panels[0].stringer_flange_pid=20000001;
  shell.fixtureScope={...scope,editablePropertyIds:[6000001,7000001,19000001,20000001]};const sections=api.related(shell,6000001,report).descriptors.filter(d=>d.kind==='stringers');
  assert.equal(sections.length,1);assert.deepEqual(sections[0].propertyIds,[7000001,19000001,20000001]);
 });
 test('Live summary uses the fixed physical scope and the supplied projected assessment input',()=>{
  const bundle=api.related(c,6000001,report),input={projected:true},next={...report,panelAssessment:{...assessment,value:1.3}};
  assert.equal(bundle.assess(next,input).value,1.3);assert.equal(calls.at(-1).input,input);assert.equal(calls.at(-1).scope,scope);
 });
 test('Explicit component/runout physical scopes retain their local assessment',()=>{
  const local={...c,fixtureScope:{key:'runout:99',kind:'property',label:'Runout connector 99',editablePropertyIds:[13],elementIds:[99]}};
  const bundle=api.related(local,13,report);assert.equal(bundle.scope,local.fixtureScope);assert.equal(bundle.selectionKind,'property');assert.deepEqual(bundle.descriptors.map(d=>d.pid),[13]);assert.equal(bundle.assessment,assessment);
 });
 test('Atomic property updates remain SI and reject partial writes',()=>{
  const before=JSON.stringify(c),result=api.prepare(c,[{pid:6000001,values:{thickness:'4'}},{pid:7000001,values:{height:'45',web_thickness:'3'}}]);
  assert.equal(result.patches.length,1);assert.equal(result.patches[0].rows[0].skin.thickness,.004);assert.equal(result.patches[0].rows[0].stringer.height,.045);assert.equal(result.patches[0].rows[0].stringer.web_thickness,.003);
  assert.equal(JSON.stringify(c),before);assert.throws(()=>api.prepare(c,[{pid:6000001,values:{thickness:'4'}},{pid:7000001,values:{height:'1'}}]),/minimum/);assert.equal(JSON.stringify(c),before);
 });
 console.log(JSON.stringify({passed:true,checks}));
}finally{if(previous===undefined)delete globalThis.WingRFPanelScope;else globalThis.WingRFPanelScope=previous;}
module.exports={context:c,report,scope,assessment};
