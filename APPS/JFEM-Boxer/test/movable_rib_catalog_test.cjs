'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8'),start=source.indexOf('function planformPointSignature('),end=source.indexOf('\nfunction formSignature(',start),P=require('../web/planform_view.js');
const points=['planform.leading_edge_points','planform.trailing_edge_points','box.front_spar_points','box.rear_spar_points'];
const params={'planform.area':20,'planform.aspect_ratio':8,'planform.taper_ratio':.5,'planform.sweep':10,'planform.sweep_ref_xc':.25,'planform.root_ref_x':0,'box.front_spar_xc':.2,'box.rear_spar_xc':.7,'box.stringer_angle':0,'box.rib_pitch':.5,'ribs.masters':[],...Object.fromEntries(points.map(k=>[k,[]]))};
const ribs=[{index:1,eta:0},{index:2,eta:.2}],context={WingPlanformView:P,WingRibLayout:{PARAM_KEYS:Object.keys(params)},state:{modelDirty:true,data:{model_params:structuredClone(params),annotations:{ribs}}},readEditorParams:()=>context.current};
vm.createContext(context);vm.runInContext(source.slice(start,end),context);let checks=0;
function reset(){context.current=structuredClone(params);for(const k of points)context.current[k]=P.endpointRows([],k,params);}
reset();assert.equal(context.currentSupportRibs(),ribs);checks++;
assert.deepEqual(context.state.data.model_params,params);checks++;
for(const key of points){reset();context.current[key][1].dxc=.01;assert.equal(context.currentSupportRibs().length,0);checks++;reset();context.current[key].push({eta:.5,dxc:.03,...(key==='box.rear_spar_points'?{stringer_angle:0}:{})});assert.equal(context.currentSupportRibs().length,0);checks++;reset();context.current[key][1].incoming_angle_deg=5;assert.equal(context.currentSupportRibs().length,0);checks++;}
reset();context.current['box.rear_spar_points'][1].stringer_angle=12;assert.equal(context.currentSupportRibs().length,0);checks++;
reset();context.current['box.rib_pitch']=.7;assert.equal(context.currentSupportRibs().length,0);checks++;
reset();context.current['ribs.masters']=[{eta:.3}];assert.equal(context.currentSupportRibs().length,0);checks++;
reset();context.current['planform.sweep']=11;assert.equal(context.currentSupportRibs().length,0);checks++;
reset();context.current['planform.leading_edge_points'][1].eta=.9;assert.equal(context.currentSupportRibs().length,0);checks++;
reset();context.state.data.annotations=null;assert.equal(context.currentSupportRibs().length,0);checks++;
console.log(JSON.stringify({passed:true,checks,scope:'Automatic zero-offset endpoints retain actual rib snapping; independent station/offset/angle, rib and planform changes still invalidate the generated catalog'}));
