'use strict';
const assert=require('node:assert/strict'),R=require('../web/aerodynamic_reference.js'),P=require('../web/aerodynamic_plots.js'),A=require('../web/aerodynamic_study.js');
const near=(a,b)=>assert(Math.abs(a-b)<1e-10),origin=[10,20,30],g=R.geometry({alpha:30,beta:20},origin,2);
near(g.velocity[0],Math.sqrt(3)/2*Math.cos(Math.PI/9));near(g.velocity[1],-Math.sin(Math.PI/9));near(g.velocity[2],.5*Math.cos(Math.PI/9));
assert(g.alpha.points.at(-1)[2]>g.glyphOrigin[2]);assert(g.beta.points.at(-1)[1]<g.glyphOrigin[1]);
for(const p of g.alpha.points)near(Math.hypot(...p.map((v,i)=>v-g.glyphOrigin[i])),2);
for(const p of g.beta.points)near(Math.hypot(...p.map((v,i)=>v-g.glyphOrigin[i])),2.7);
g.beta.points.at(-1).forEach((v,i)=>near(v,g.glyphOrigin[i]+2.7*g.velocity[i]));assert.deepEqual(origin,[10,20,30]);
const negative=R.geometry({alpha:-15,beta:-10},origin,1);assert(negative.alpha.points.at(-1)[2]<negative.glyphOrigin[2]);assert(negative.beta.points.at(-1)[1]>negative.glyphOrigin[1]);
const zero=R.geometry({alpha:0,beta:0},origin,1);assert.deepEqual(zero.alpha.points[0],zero.alpha.points[1]);assert.deepEqual(zero.beta.points[0],zero.beta.points[1]);
const cases=[];for(const alpha of [-2,4])for(const beta of [-1,3])cases.push({id:cases.length+1,condition:{alpha,beta},coefficients:{body:{force:[alpha,beta,alpha+beta],moment:[1,2,3]},wind:{force:[.01,beta,alpha*2+beta],moment:[4,5,6]},stability:{force:[.02,beta,alpha*3+beta],moment:[7,8,9]}},CDi_trefftz:.03,span_efficiency:.8});
for(const c of cases)c.coefficients.aerodynamic={force:[.2,.3,.4],moment:[.5,.6,.7]};
const result={cases,settings:{sweeps:[{variable:'alpha'},{variable:'beta'}]},basis:'BASIC X aft, Y right, Z up.',limitations:'Attached flow.'};
assert.equal(P.coefficientSpecs().length,26);for(const frame of ['body','wind','stability'])assert.equal(P.coefficientSpecs(frame).length,8);
const plots=P.sweepPlots(result,'alpha','all');assert.equal(plots.length,26);const lift=plots.find(p=>p.key==='wind.CL');assert.equal(lift.series.length,2);assert.deepEqual(lift.series[0].points,[[-2,-5],[4,7]]);assert.deepEqual(lift.series[1].points,[[-2,-1],[4,11]]);
const all=P.allSweepPlots(result);assert.equal(all.length,53);assert.equal(P.dataRows(all).length,212);assert(P.csv(P.dataRows(all)).includes('stability.Cn'));
const byBeta=P.sweepPlots(result,'beta','body').find(p=>p.key==='body.CX');assert.deepEqual(byBeta.series[0].points,[[-1,-2],[3,-2]]);assert.match(byBeta.series[1].name,/Alpha.*4/);
assert.equal(P.variableValue({condition:{controls:{Flap:{left:7,right:8}}}},'control_left:Flap'),7);assert.equal(P.variableValue({condition:{controls:{Flap:{left:7,right:8}}}},'control:Flap'),8);
const unsafe={...lift,title:'CL <script> vs alpha',series:lift.series.map(s=>({...s,name:'Flap <b> & "A"'}))};
const svg=P.svg(unsafe,{stale:true,metadata:'Snapshot <b>'});assert(svg.startsWith('<svg'));assert(svg.includes('STALE RESULTS'));assert(!svg.includes('<script>'));assert(svg.includes('&lt;script&gt;'));assert(svg.includes('&lt;b&gt;'));assert(svg.includes('Alpha (deg)'));assert(svg.includes("Wind W' CL"));
assert(P.report(result,all,{stale:true}).includes('STALE RESULTS'));assert.equal((P.report(result,all).match(/<svg /g)||[]).length,53);
cases[0].span_efficiency=null;assert.equal(P.dataRows(P.allSweepPlots(result)).length,210);assert.throws(()=>P.sweepPlots(result,'q'),/completed sweep/);assert.throws(()=>P.coefficientSpecs('other'),/frame/);
const view=A.validateState(null);assert(view.referenceAxes&&view.flowAngles);assert.equal(view.sweepFrame,'wind');assert.throws(()=>A.validateState({sweepFrame:'unknown'}),/sweep/);assert.throws(()=>A.validateState({referenceAxes:'yes'}),/display/);
console.log('PASS Reference axes, signed alpha/beta geometry, zero angles, all 26 coefficients, Cartesian grouping, variable selection, data conservation, missing values and safe portable SVG/HTML/CSV exports.');

assert.deepEqual(g.axes[0][0],origin);assert.deepEqual(g.flow[1],origin);assert(g.glyphOrigin.every((v,i)=>Math.abs(v-origin[i]+7.6*g.velocity[i])<1e-10));
const sheet=P.sheet(all.slice(0,11),{title:'Spanwise <test>',stale:true,metadata:'case=1'});assert.equal((sheet.match(/<svg /g)||[]).length,12);assert(sheet.includes('Spanwise &lt;test&gt;'));assert(sheet.includes('STALE RESULTS'));
console.log('PASS Upstream flow/angle origin, preserved reference axes and combined spanwise SVG sheet.');

const body=R.geometry({alpha:30,beta:20},origin,1,'body');assert.deepEqual(body.axes[0][1],[-1.65+origin[0],origin[1],origin[2]]);assert(body.axes[2][1][2]<origin[2]);
const stable=R.geometry({alpha:30,beta:20,stability_alpha:7},origin,1,'stability'),stable2=R.geometry({alpha:5,beta:-3,stability_alpha:7},origin,1,'stability');assert.deepEqual(stable.axes,stable2.axes);const wind=R.geometry({alpha:30,beta:20},origin,1,'wind');wind.axes[0][1].forEach((x,i)=>near((x-origin[i])/1.65,-wind.velocity[i]));
console.log('PASS B forward/right/down, fixed-alpha0 S and W-prime velocity alignment.');

const fifteen=R.axisGeometry({alpha:12,beta:10,stability_alpha:7},origin,1,A.validateState(null));assert.equal(fifteen.length,15);const yb=fifteen.find(a=>a.name==='Y_B');assert(yb.points[1][1]>yb.points[0][1]);near(yb.points[1][0],yb.points[0][0]);near(yb.points[1][2],yb.points[0][2]);const flags=A.validateState(null);flags.axisVisibility.body[1]=false;assert.equal(R.axisGeometry({alpha:12,beta:10},origin,1,flags).length,14);assert(!R.axisGeometry({},origin,1,flags).some(a=>a.name==='Y_B'));
const positiveBeta=R.geometry({alpha:0,beta:10},origin,1);assert(positiveBeta.flow[0][1]>origin[1]);assert(positiveBeta.velocity[1]<0);
const positive={title:'Positive-only',xlabel:'x',ylabel:'y',series:[{name:'case',points:[[2,3],[4,5]]}]},lay=P.layout(positive);assert(lay.xmin<=0&&lay.ymin<=0);const zeros=P.svg(positive,{dark:true});assert(zeros.includes('data-zero-axis="x"'));assert(zeros.includes('data-zero-axis="y"'));assert(zeros.includes('stroke-width="1.9"'));const hit=P.nearest(positive,lay.x(3.8),lay.y(4.8));assert.deepEqual(hit.point,[4,5]);assert(hit.distance<1e-8);console.log('PASS All 15 independently selectable axes, +Y_B/right wind source, visible zero references and real-sample curve picking.');

for(const [alpha,beta] of [[20,-20],[-17,9],[0,0],[1.3,-2.1]]){
 const angles=R.geometry({alpha,beta},origin,2);
 for(const key of ['alpha','beta'])assert.deepEqual(angles[key].label,angles[key].points[(angles[key].points.length-1)/2]);
}
console.log('PASS Signed and zero-angle label anchors coincide exactly with the sampled angular midpoint.');
