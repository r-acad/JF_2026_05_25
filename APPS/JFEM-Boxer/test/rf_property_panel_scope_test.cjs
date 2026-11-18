'use strict';
// Actual generated geometry with explicit synthetic RF oracles. This tests
// editor/field scope integration, not the native structural formulations.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const editor=require('../web/rf_assembly_editor.js'),scopeApi=require('../web/rf_panel_scope.js'),stress=require('../web/stress_report_data.js'),msgpack=require('../web/vendor/msgpack.min.js');
const[payloadFile,schemaFile,output]=process.argv.slice(2),bytes=fs.readFileSync(payloadFile),data=msgpack.decode(bytes),schema=JSON.parse(fs.readFileSync(schemaFile,'utf8'));
const context={data,parameters:schema.values,groups:data.groups,panels:data.stiffened_panels.panels,ribs:data.annotations.ribs,layout_token:data.stiffened_panels.layout_token,generated:true};
const layout=scopeApi.index(context),criteria={};
const collections={euler_column:data.stiffened_panels.euler_columns,stringer_blade:data.stiffened_panels.blade_columns,skin_buckling:data.stiffened_panels.skin_buckling_panels};
for(const[mode,raws]of Object.entries(collections))criteria[mode]={rows:raws.map(raw=>({panelKey:raw.key,rowKey:mode+':'+raw.key,label:raw.label||raw.key,reserveFactor:.6,complete:true,envelopeCaseLabel:'Scope oracle case',caseResults:[]}))};
for(const[mode,kind]of[['spar_cap_buckling','spar_cap'],['rib_web_buckling','rib_web'],['spar_web_buckling','spar_web'],['rib_stiffener_buckling','rib_stiffener'],['rib_stiffener_blade','rib_stiffener_blade']]){
 const raw=Object.values(data.component_buckling||{}).flat().filter(item=>item.kind===kind);criteria[mode]={rows:raw.map(item=>({panelKey:item.key,rowKey:mode+':'+item.key,label:item.label||item.key,reserveFactor:.8,complete:true,caseResults:[]}))};
}
function makeReport(value){
 const report={failureMode:'minimum_rf',rows:[],materialRegions:layout.materialRegions.map(region=>({materialRegionKey:region.key,pid:region.pid,failureMode:'von_mises',reserveFactor:value,complete:true,label:region.label,envelopeCaseLabel:'Material oracle case',caseResults:[]}))};
 const all=JSON.parse(JSON.stringify(criteria));for(const r of Object.values(all))for(const row of r.rows)row.reserveFactor=value;stress.rememberCriteria(report,all);return report;
}
const report=makeReport(.6),observed=[];
for(const pid of[5000058,5000063]){
 const panel=context.panels.find(p=>p.shell_pid===pid);assert(panel);
 const compression=layout.byKey.get(panel.key),plain=layout.parts.find(part=>part.kind==='plain_skin'&&part.skin==='upper'&&part.ribBay===panel.rib_bay&&part.sparSide==='front');assert(compression&&plain);
 for(const scope of[compression,plain]){
  const eid=scope.skinElementIds.find(id=>panel.shell_eids.includes(id));assert(Number.isSafeInteger(eid));
  const bundle=editor.related(context,pid,report,{eid,scopeKey:scope.key,detail:{modeKey:'euler_column'}});
  assert.equal(bundle.scope,scope);assert.equal(bundle.assessment.value,.6);assert(bundle.assessment.available,bundle.assessment.reason);
  assert.equal(bundle.sharedPanels,undefined);assert.deepEqual(bundle.descriptors.flatMap(d=>d.propertyIds).sort((a,b)=>a-b),scope.editablePropertyIds.slice().sort((a,b)=>a-b));
  if(scope.kind==='plain_skin'){
   assert.equal(bundle.descriptors.filter(d=>d.kind==='stringers').length,0);
   assert(!bundle.assessment.checks.some(check=>['euler_column','stringer_blade'].includes(check.modeKey)));
   assert(bundle.assessment.checks.some(check=>check.modeKey==='skin_buckling'));
  }else{
   assert.equal(bundle.descriptors.filter(d=>d.kind==='stringers').length,1);
   assert.deepEqual(bundle.assessment.checks.filter(check=>check.modeKey==='euler_column').map(check=>check.scopeKey),[panel.key]);
   assert.deepEqual(bundle.assessment.checks.filter(check=>check.modeKey==='stringer_blade').map(check=>check.scopeKey),[panel.key]);
  }
  const passing=makeReport(1.3);passing.estimated=true;const next=bundle.assess(passing,context);
  assert(next.available);assert.equal(next.value,1.3);assert.equal(next.failures.length,0);
  assert.deepEqual(next.checks.map(check=>check.modeKey+'|'+check.scopeKey),bundle.assessment.checks.map(check=>check.modeKey+'|'+check.scopeKey));
  const reopened=editor.related(context,pid,passing,{eid,scopeKey:scope.key,detail:{modeKey:'von_mises'}});assert.equal(reopened.scope.key,scope.key);assert.deepEqual(reopened.descriptors.map(d=>d.pid),bundle.descriptors.map(d=>d.pid));
  observed.push({pid,eid,kind:scope.kind,key:scope.key,editorPids:bundle.descriptors.map(d=>d.pid),checkKeys:bundle.assessment.checks.map(check=>check.modeKey+'|'+check.scopeKey),liveRF:next.value});
 }
}
const result={passed:true,payload:path.resolve(payloadFile),payload_sha256:crypto.createHash('sha256').update(bytes).digest('hex'),observed,scopeVerificationOnly:true,numericalValuesAreSynthetic:true};
fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,JSON.stringify(result,null,2));console.log(JSON.stringify(result));
