"use strict";
// Real model-signature code: derived constraint offsets may round differently
// across Julia/JS, but independent changes must still invalidate old results.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8'),P=require('../web/planform_view.js');
const keys=[...P.POINT_KEYS,'box.front_spar_points','box.rear_spar_points'];
const base={'planform.area':44.035,'planform.aspect_ratio':8.2,'planform.taper_ratio':.53,'planform.sweep':1.2,'planform.sweep_ref_xc':.25,'box.front_spar_xc':.2,'box.rear_spar_xc':.65,'box.stringer_angle':2};
const schema=[...Object.keys(base).map(key=>({key,kind:'float'})),...keys.map(key=>({key,kind:'planformpoints'}))];
const state={schema},context={state,WingPlanformView:P,document:{getElementById:()=>({value:'[]'})},parameterDisplayValue:(_,v)=>v,parameterModelValue:(_,v)=>v,readEditorParams:()=>base};vm.createContext(context);
for(const [start,end]of [['function affectsModel(','function readPlanformParams('],['function planformPointSignature(','function currentSupportRibs('],['function formSignature(','function syncLeadingEdgeOrientation(']])vm.runInContext(source.slice(source.indexOf(start),source.indexOf(end)),context);
const sig=p=>context.formSignature(p),clone=p=>JSON.parse(JSON.stringify(p));let count=0;
const params={...base};for(const key of keys)params[key]=[{eta:0,dxc:.04},{eta:.4,dxc:.12,incoming_angle_deg:0},{eta:1,dxc:.08,incoming_angle_deg:3}].map(p=>({...p,...(key==='box.rear_spar_points'?{stringer_angle:2}:{})}));
const normalized=clone(params);for(const key of keys)normalized[key]=P.constrainPointRows(P.normalizePointRows(params[key],key,params),key,params);
for(const key of keys){const roundoff=clone(normalized);roundoff[key][0].dxc+=1e-16;roundoff[key][1].dxc-=2e-16;assert.equal(sig(roundoff),sig(normalized),key+' constrained offset rounding');count++;
 for(const [i,field,change]of [[2,'dxc',1e-8],[1,'eta',1e-8],[1,'incoming_angle_deg',1e-8]]){const changed=clone(normalized);changed[key][i][field]+=change;assert.notEqual(sig(changed),sig(normalized),key+' independent '+field);count++;}
 const unconstrained=clone(normalized);delete unconstrained[key][1].incoming_angle_deg;const changed=clone(unconstrained);changed[key][0].dxc+=1e-12;assert.notEqual(sig(changed),sig(unconstrained),key+' independent preceding offset');count++;
 assert.equal(context.planformPointSignature(normalized[key],key,normalized),context.planformPointSignature(JSON.stringify(normalized[key]),key,normalized));count++;
}
for(const key of ['planform.area','planform.sweep','box.front_spar_xc','box.rear_spar_xc']){const changed=clone(normalized);changed[key]+=1e-9;assert.notEqual(sig(changed),sig(normalized),key);count++;}
const rear=clone(normalized);rear['box.rear_spar_points'][1].stringer_angle+=.1;assert.notEqual(sig(rear),sig(normalized));count++;
// Real incoming-angle offsets saved by Julia in the reported Study.
const exact={...base,'planform.area':44.035};for(const key of keys)exact[key]=[];exact['box.front_spar_points']=[{eta:0,dxc:.022553294609234636},{eta:.42041816405239857,dxc:.08178760928296375,incoming_angle_deg:0},{eta:1,dxc:.21449122558765366}];
const ui=clone(exact);ui['box.front_spar_points']=P.constrainPointRows(P.normalizePointRows(exact['box.front_spar_points'],'box.front_spar_points',exact),'box.front_spar_points',exact);assert.equal(sig(exact),sig(ui));count++;
console.log('Constrained model/result identity: '+count+' checks passed');
