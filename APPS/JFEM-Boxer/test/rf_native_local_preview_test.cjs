'use strict';
// Native acceptance against an actual recovered model. Inputs are supplied
// privately: complete RF input, generated section-only edit, output, endpoint.
// No mesh, equilibrium solve, or finite-difference solve is requested here.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const V=require('../web/rf_native_report_view.js'),D=require('../web/stress_report_data.js'),S=require('../web/rf_sizing_estimate.js'),C=require('../web/rf_compute_client.js');
const entries=v=>v instanceof Map?[...v]:Object.entries(v||{}),key=g=>[g.name,g.kind,g.pid].join('|');
function hydrate(raw,payload){
 const signature=JSON.stringify([['properties.panels',[]]]),points=[],nodes=new Map();
 const elements=new Map(entries(raw.elements).map(([id,e])=>[Number(id),{...e,nodes:(e.points||[]).map(p=>{const k=JSON.stringify(p);if(!nodes.has(k)){nodes.set(k,nodes.size);points.push(...p);}return nodes.get(k);})}]));
 const input={...raw,elements,generated:true,sourceUnits:false,studyEpoch:1,analysisEpoch:1,meshIdentity:'actual-recovered-fixture',signature,definitionSignature:signature,modelDirty:false,pendingDrafts:false,running:false,
  nodeIds:Int32Array.from({length:nodes.size},(_,i)=>i+1),nodePositions:Float64Array.from(points),failureMode:'minimum_rf',caseId:'all',panels:[],componentGroups:[],expectedCases:entries(raw.cases).map(([id,c])=>({id:Number(id),solution:101,label:c.label||'Case '+id,enabled:true})),
  cases:new Map(entries(raw.cases).map(([id,c])=>[Number(id),{...c,signature,meshIdentity:'actual-recovered-fixture'}]))};
 if(payload){const groups=new Map(payload.groups.map(g=>[key(g),g.properties]));for(const e of elements.values()){assert(groups.has(key(e.group)),'Generated baseline property identity differs from solved source');e.group={...e.group,properties:groups.get(key(e.group))};}Object.assign(input,{panels:payload.stiffened_panels.panels,componentGroups:payload.groups,eulerColumns:payload.stiffened_panels.euler_columns,stringerBlades:payload.stiffened_panels.blade_columns,skinBucklingPanels:payload.stiffened_panels.skin_buckling_panels,componentBuckling:payload.component_buckling});}
 delete input.response_ids;return input;
}
function edited(base,sections,tag){
 const groups=new Map(sections.groups.map(g=>[key(g),g.properties])),signature=JSON.stringify([['properties.panels',tag]]),panels=sections.stiffened_panels;
 const current={...base,signature,definitionSignature:signature,sectionBaselineSignature:base.signature,modelDirty:true,
  elements:new Map([...base.elements].map(([id,e])=>[id,{...e,group:{...e.group,properties:groups.get(key(e.group))||e.group.properties}}])),panels:panels.panels,componentGroups:sections.groups,
  eulerColumns:panels.euler_columns,stringerBlades:panels.blade_columns,skinBucklingPanels:panels.skin_buckling_panels,componentBuckling:sections.component_buckling};
 current.sectionUpdateCertificate=S.certifySections(current);const estimate=S.project(base,current);assert(estimate.estimated,estimate.reason);return estimate;
}
const rows=report=>report.rows.map(r=>({pid:r.pid,complete:r.complete,rf:r.reserveFactor,mode:r.combined?.governingMode,case:r.envelopeCaseKey,checks:r.combined?.assessments.map(a=>({mode:a.failureMode,scope:a.scopeKey,complete:a.complete,rf:a.reserveFactor,cases:a.caseResults.map(c=>({key:c.caseKey,complete:c.complete,rf:c.reserveFactor}))}))}));
async function run(inputFile,sectionsFile,out,endpoint,baselinePayloadFile){
 fs.mkdirSync(out,{recursive:true});const baselinePayload=baselinePayloadFile?require('../web/vendor/msgpack.min.js').decode(fs.readFileSync(baselinePayloadFile)):null,base=hydrate(JSON.parse(fs.readFileSync(inputFile,'utf8')),baselinePayload),sections=JSON.parse(fs.readFileSync(sectionsFile,'utf8')),estimate=edited(base,sections,'edited-section-only');
 const payload=input=>JSON.stringify({input:C.wire(input),request_id:'rf-local-test-'+Date.now()+'-'+Math.random().toString(36).slice(2)},C.jsonReplacer),timings={};
 async function request(input,name){const body=payload(input),start=performance.now(),response=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},body}),packet=await response.json();assert(response.ok&&packet.ok!==false,packet.error||'Native RF endpoint failed');timings[name]={wallSeconds:(performance.now()-start)/1000,requestBytes:Buffer.byteLength(body),responses:packet.assessment?.responses?.length};fs.writeFileSync(path.join(out,name+'_packet.json'),JSON.stringify(packet));return packet;}
 const baselinePacket=await request(base,'baseline_full'),baseline=V.build(base,baselinePacket),prior={...base};assert(baseline.report.rows.every(r=>r.complete),'The actual fresh baseline must have complete property assessments');
 const originalPacketFile=path.join(path.dirname(inputFile),'assessment_before_fix.json'),alignment={freshMetadata:!!baselinePayloadFile,sourceRecoveryUnchanged:true,completeProperties:baseline.report.rows.length};
 if(fs.existsSync(originalPacketFile)){const original=JSON.parse(fs.readFileSync(originalPacketFile,'utf8')),byId=new Map(original.map(r=>[r.response_id,r]));let maxRelative=0,compared=0;for(const row of baselinePacket.assessment.responses){const old=byId.get(row.response_id);if(row.status==='ok'&&old?.status==='ok'&&Number.isFinite(row.raw_RF)&&Number.isFinite(old.raw_RF)){const relative=Math.abs(row.raw_RF-old.raw_RF)/Math.max(Math.abs(row.raw_RF),Math.abs(old.raw_RF),Number.MIN_VALUE);maxRelative=Math.max(maxRelative,relative);compared++;}}assert(maxRelative<1e-9,'Fresh equivalent metadata must retain the existing physical RF values');Object.assign(alignment,{originalResponsesCompared:compared,maxRelativeRFChange:maxRelative});}
 const plan=V.planner(estimate.context,baseline.report,prior,baseline.criteria);assert(plan.incremental&&!plan.reuse,'First draft must use local evaluation');assert(plan.counts.cachedCriteria>plan.counts.affectedCriteria,'A local section edit must retain unrelated cached criteria');
 const sparse=V.scopedInput(estimate.context,plan);assert(sparse.elements.size<base.elements.size);for(const c of sparse.cases.values())assert.equal(entries(c.elementResults||c.element_results).length,sparse.elements.size);
 const localPacket=await request(sparse,'edited_sparse'),fullPacket=await request(estimate.context,'edited_full'),local=V.build(estimate.context,localPacket,{previousReports:baseline.criteria,replaceScopes:plan.replaceScopes,changedPropertyIds:plan.changedPropertyIds}),full=V.build(estimate.context,fullPacket);
 assert.deepEqual(rows(local.report),rows(full.report),'Localized native checks and cached rows must exactly reproduce full native assessment');
 const nativeFull=new Map(fullPacket.assessment.responses.map(r=>[r.response_id,r]));for(const r of localPacket.assessment.responses){const expected=nativeFull.get(r.response_id);assert(expected);assert.equal(r.status,expected.status);assert.equal(r.raw_RF,expected.raw_RF);assert.equal(r.reason,expected.reason);}
 // Request identity is required for safe reuse. Policy/case changes must not
 // silently keep obsolete cached criteria, while repeated unchanged drafts do.
 assert(V.planner(estimate.context,local.report,estimate.context,local.criteria).reuse);
 assert.equal(V.planner({...estimate.context,caseId:1},local.report,estimate.context,local.criteria).incremental,false);
 assert.equal(V.planner({...estimate.context,assessmentPolicy:{...estimate.context.assessmentPolicy,strengthSafetyFactor:2}},local.report,estimate.context,local.criteria).incremental,false);
 const result={passed:true,source:path.resolve(inputFile),actualSolvedCaseCount:base.cases.size,alignment,changedPropertyIds:estimate.changedPropertyIds,recoveredElementRecords:estimate.recoveredElementRecords,plan,scope:sparse.transportScope,timings,requestReductionPercent:100*(1-timings.edited_sparse.requestBytes/timings.edited_full.requestBytes),evaluatedRows:local.report.incremental.evaluatedRows,reusedRows:local.report.incremental.reusedRows,globalPropertyRows:full.report.rows.length,exactRFAndCoverageMatch:true,requestedMeshOrEquilibriumSolve:false};
 fs.writeFileSync(path.join(out,'full_input.json'),JSON.stringify(C.wire(estimate.context),C.jsonReplacer));fs.writeFileSync(path.join(out,'sparse_input.json'),JSON.stringify(C.wire(sparse),C.jsonReplacer));fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result,null,2));return result;
}
module.exports={hydrate,edited,rows,run};
if(require.main===module)run(...process.argv.slice(2)).catch(error=>{console.error(error.stack);process.exitCode=1;});
