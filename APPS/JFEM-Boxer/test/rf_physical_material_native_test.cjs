'use strict';
// Actual, already-solved fixture acceptance. No FE solve or invented RF oracle.
// RF_INPUT_JSON PAYLOAD_MSGPACK OUTPUT NATIVE_API_BASE
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {hydrate,edited}=require('./rf_native_local_preview_test.cjs'),MP=require('../web/vendor/msgpack.min.js'),
 P=require('../web/rf_panel_scope.js'),V=require('../web/rf_native_report_view.js'),C=require('../web/rf_compute_client.js'),E=require('../web/rf_assembly_editor.js');
async function run(inputFile,payloadFile,out,api){
 fs.mkdirSync(out,{recursive:true});const payload=MP.decode(fs.readFileSync(payloadFile)),input=hydrate(JSON.parse(fs.readFileSync(inputFile,'utf8')),payload);
 input.data=payload;input.materialRegions=P.index(input).materialRegions;
 const started=performance.now(),response=await fetch(api+'/api/rf_assessment',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({input:C.wire(input),request_id:'actual-physical-material-'+Date.now()},C.jsonReplacer)}),packet=await response.json();
 assert(response.ok&&packet.ok!==false,packet.error);fs.writeFileSync(path.join(out,'assessment.json'),JSON.stringify(packet));
 const built=V.build(input,packet),layout=P.index(input),parts=[],relative=(a,b)=>Math.abs(a-b)/Math.max(Math.abs(a),Math.abs(b),Number.MIN_VALUE);
 for(const key of ['plain:upper:bay3:skinstrip1:segment1','upper:bay3:stringer2:segment1','plain:upper:bay2:skinstrip1:segment1']){
  const part=layout.byKey.get(key),summary=P.summary(input,built.report,part),strength=[];assert(summary.available,summary.reason);
  for(const region of part.materialRegions){
   const row=built.report.materialRegions.find(r=>r.materialRegionKey===key&&r.pid===region.pid);assert(row?.complete);
   for(const item of row.caseResults){
    const caseId=String(item.caseKey).split(':')[0],caseRecord=[...input.cases].find(([id])=>String(id)===caseId)?.[1];assert(caseRecord,'Cannot identify exact physical case '+item.caseKey);
    const maxima=region.member_element_ids.map(eid=>{const record=caseRecord.elementResults[eid],stress=record.stress;if(Number.isFinite(stress.von_mises))return stress.von_mises;return Math.max(...Object.values(stress).filter(v=>v&&typeof v==='object'&&Number.isFinite(v.normal_x)).map(v=>Math.sqrt(v.normal_x*v.normal_x-v.normal_x*v.normal_y+v.normal_y*v.normal_y+3*v.shear_xy*v.shear_xy)));});
    const element=input.elements.get(region.member_element_ids[0]),allowable=element.group.properties.material.allowables.stress,policy=input.assessmentPolicy.strengthSafetyFactor??1.5,expected=allowable/(policy*Math.max(...maxima));
    assert(relative(item.reserveFactor,expected)<2e-12,'Native local strength differs from independently sampled recovered stress: '+key+' P'+region.pid);
    strength.push({pid:region.pid,case:item.caseKey,memberElementIds:region.member_element_ids,rf:item.reserveFactor,independentRF:expected});
   }
  }
  if(part.kind==='plain_skin'){assert(!summary.checks.some(c=>['euler_column','stringer_blade'].includes(c.modeKey)));assert(part.capElementIds.length>0);assert.equal(part.stringerElementIds.length,0);}
  else{const euler=summary.checks.filter(c=>c.modeKey==='euler_column');assert.equal(euler.length,1);assert.equal(euler[0].scopeKey,key);assert.equal(part.stringerElementIds.length,3);}
  parts.push({key,kind:part.kind,pids:part.editablePropertyIds,rf:summary.value,checks:summary.checks.map(c=>({mode:c.modeKey,scope:c.scopeKey,rf:c.value})),strength});
 }
 // Run the normal property-edit preparation and section-only certification,
 // then compare localized native evaluation with a full independent replay.
 const parameters=JSON.parse(JSON.stringify(payload.model_params)),prepared=E.prepare({data:payload,parameters},[{pid:5000063,values:{thickness:'10'}},{pid:8000003,values:{side:'60'}}]);
 for(const patch of prepared.patches)parameters[patch.parameter]=patch.rows;
 const sectionResponse=await fetch(api+'/api/rf_sections',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({parameters,baseline:payload.model_params})}),sections=await sectionResponse.json();assert(sectionResponse.ok&&sections.ok!==false,sections.error);
 fs.writeFileSync(path.join(out,'edited_sections.json'),JSON.stringify(sections));
 const estimate=edited(input,sections,'plain63-skin10-cap60'),current=estimate.context;current.data=payload;current.materialRegions=P.index(current).materialRegions;
 const plan=V.planner(current,built.report,input,built.criteria);assert(plan.incremental&&!plan.reuse);assert(plan.counts.cachedCriteria>plan.counts.affectedCriteria);
 async function native(context,name){const response=await fetch(api+'/api/rf_assessment',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({input:C.wire(context),request_id:'actual-physical-'+name+'-'+Date.now()},C.jsonReplacer)}),packet=await response.json();assert(response.ok&&packet.ok!==false,packet.error);fs.writeFileSync(path.join(out,name+'.json'),JSON.stringify(packet));return packet;}
 const sparse=V.scopedInput(current,plan),sparsePacket=await native(sparse,'edited_sparse'),fullPacket=await native(current,'edited_full'),local=V.build(current,sparsePacket,{previousReports:built.criteria,replaceScopes:plan.replaceScopes,changedPropertyIds:plan.changedPropertyIds}),full=V.build(current,fullPacket);
 for(const part of P.index(current).parts){const a=P.summary(current,local.report,part),b=P.summary(current,full.report,part);assert.equal(a.available,b.available);assert.equal(a.value,b.value,part.key);assert.equal(a.modeKey,b.modeKey);}
 const passing=P.summary(current,local.report,P.index(current).byKey.get('plain:upper:bay3:skinstrip1:segment1')),neighbor=P.summary(current,local.report,P.index(current).byKey.get('upper:bay3:stringer2:segment1'));
 assert(passing.available&&passing.value>1);assert(passing.checks.every(c=>c.complete&&c.value>=1));assert(neighbor.available&&neighbor.value<1);assert.equal(neighbor.modeKey,'stringer_blade');
 const result={passed:true,elapsedSeconds:(performance.now()-started)/1000,actualPhysicalCases:input.cases.size,physicalParts:layout.parts.length,materialRegions:input.materialRegions.length,nativeResponses:packet.assessment.responses.length,unavailableResponses:packet.assessment.responses.filter(r=>r.status!=='ok').length,parts,edited:{plan,recoveredElementRecords:estimate.recoveredElementRecords,passingPlainRF:passing.value,failingNeighborRF:neighbor.value,failingNeighborMode:neighbor.modeKey,exactFullAndSparsePhysicalRFMatch:true},independentStrengthFormula:'maximum recovered element von Mises within each explicit real-PID physical region, divided into material allowable with strength safety coefficient',noNewEquilibriumSolve:true};
 fs.writeFileSync(path.join(out,'rf_input.json'),JSON.stringify(C.wire(input),C.jsonReplacer));fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result,null,2));return result;
}
module.exports={run};if(require.main===module)run(...process.argv.slice(2)).catch(e=>{console.error(e.stack);process.exitCode=1;});
