'use strict';
const assert=require('node:assert/strict'),Export=require('../web/geometry_export.js'),Workspace=require('../web/workspace.js');
(async()=>{
 const data={nodes:{count:2,n_structural:2,xyz:Float32Array.of(0,0,0,1,0,0),ids:Int32Array.of(10,20)},groups:[],spc:{count:0,nodes:Int32Array.of(1)}};
 // The physical preload reactions can have a different SPC mask from a buckling variant.
 const snapshot={data,diag:1,activeCase:1,analysis:'SOL105',reactions:{nodes:Int32Array.of(0),forces:Float32Array.of(1,-2,3),moments:Float32Array.of(-4,5,-6)}};
 for(const [forces,moments] of [[true,false],[false,true],[true,true],[false,false]]){
  const out=await Export.collect({...snapshot,visibility:{NODES:true,SUPPORT_FORCES:forces,SUPPORT_MOMENTS:moments}},{scope:'visible',references:false});
  const reactions=out.parts.filter(part=>part.extras.entity_type==='support_reaction');
  assert.equal(reactions.filter(part=>part.extras.kind==='force').length,forces?3:0);
  assert.equal(reactions.filter(part=>part.extras.kind==='moment').length,moments?3:0);
 }
 const all=await Export.collect({...snapshot,visibility:{SUPPORT_FORCES:false,SUPPORT_MOMENTS:false}},{scope:'all',references:false});
 assert.equal(all.parts.filter(part=>part.extras.entity_type==='support_reaction').length,6);
 for(const enabled of [true,false])for(const labels of [true,false]){
  const legacy={controls:{'show-support-forces':enabled,'show-support-force-values':labels},layers:{SUPPORT_FORCES:enabled}};
  Workspace.migrateReactionControls(legacy);
  assert.equal(legacy.controls['show-support-moments'],enabled);assert.equal(legacy.controls['show-support-moment-values'],labels);assert.equal(legacy.layers.SUPPORT_MOMENTS,enabled);
 }
 const split={controls:{'show-support-forces':true,'show-support-force-values':true,'show-support-moments':false,'show-support-moment-values':false},layers:{SUPPORT_FORCES:true,SUPPORT_MOMENTS:false}};
 Workspace.migrateReactionControls(split);assert.equal(split.controls['show-support-moments'],false);assert.equal(split.controls['show-support-moment-values'],false);
 split.controls['show-support-fx']=false;split.controls['support-force-diameter']='0.03';const before=JSON.stringify(split);Workspace.migrateReactionControls(split);assert.equal(JSON.stringify(split),before);
 const selected=await Export.collect({...snapshot,supportForceDiameter:.03,supportComponents:{force:[false,true,false],moment:[true,false,false]}},{scope:'visible',references:false});
 const selectedParts=selected.parts.filter(part=>part.extras.entity_type==='support_reaction');assert.deepEqual(selectedParts.map(part=>part.extras.kind+part.extras.axis),['forceY','momentX']);
 const allComponents=await Export.collect({...snapshot,supportComponents:{force:[false,false,false],moment:[false,false,false]}},{scope:'all',references:false});assert.equal(allComponents.parts.filter(part=>part.extras.entity_type==='support_reaction').length,6);
 assert(Workspace.CONTROL_IDS.includes('show-support-moments')&&Workspace.CONTROL_IDS.includes('show-support-moment-values'));
 console.log('Reaction export and Study migration: 13 groups passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
