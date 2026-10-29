'use strict';
const assert=require('node:assert/strict'),A=require('../web/aerodynamic_study.js'),D=require('../web/aerodynamic_derivatives.js');
const old=A.validateState({settings:{alpha:4}});assert.equal(old.settings.wake_model,'straight');assert.equal(old.settings.wake_rows,16);
const free=A.validateState({settings:{wake_model:'relaxed',compressibility:'incompressible',wake_derivatives:'relaxed',wake_rows:24}});assert.equal(free.settings.wake_rows,24);
assert.throws(()=>A.validateState({settings:{wake_model:'relaxed'}}),/incompressible/);assert.throws(()=>A.validateState({settings:{wake_model:'false'}}),/wake_model/);assert.throws(()=>A.validateState({settings:{wake_derivatives:'none'}}),/wake_derivatives/);
const curve=[[0,0,0],[1,.2,-.1],[2,.6,-.4],[3,1,-.8]],c={span_m:2,wake:{model:'relaxed',converged:true,iterations:44,residual:.001,tolerance:.002,length_m:4,rows:3,core_radius_m:.03,sheets:[{lines:[curve]}]},condition:{alpha:4,beta:0,controls:{},wake_derivatives:'frozen'},coefficients:{},reference:[0,0,0],id:1};
const before=JSON.stringify(c),short=A.wakeLines(c,.5);assert.equal(short[0].length,2);assert(Math.abs(Math.hypot(...short[0][1])-1)<1e-12);assert.equal(JSON.stringify(c),before);assert.deepEqual(A.wakeLines(c,10),[curve]);assert.notEqual(A.wakeLines(c,10)[0],curve);
assert.deepEqual(A.wakeLines({span_m:2,wake_origins:[[1,2,3]],wake_direction:[1,0,0]},.5),[[[1,2,3],[2,2,3]]]);assert.deepEqual(A.wakeLines(null),[]);
for(const frame of ['body','aerodynamic','wind','stability'])c.coefficients[frame]={force:[.01,0,.4],moment:[0,-.02,0]};
const row=A.coefficientRows({cases:[c]})[0];assert.equal(row.wake_model,'relaxed');assert.equal(row.wake_iterations,44);assert.equal(row.wake_residual,.001);
for(const type of ['html','markdown']){const report=A.coefficientReport({cases:[c]},type);assert(report.includes('Wake calculation'));assert(report.includes('relaxed'));assert(report.includes('0.001'));assert(report.includes('Core (m)'));}
c.derivatives={wake_policy:'frozen',method:'Frozen finite wake',rows:[{variable:'alpha',unit:'rad^-1',method:'central',step:.001,stencil_width:.002,coefficients:c.coefficients,CDi_trefftz:null,span_efficiency:null}]};
assert.equal(D.rows({cases:[c]})[0].wake_policy,'frozen');assert.equal(D.rows({cases:[c]})[0].wake_model,'relaxed');
console.log('PASS Backward-compatible wake settings, invalid-mode guards, exact curve display/cutoff without mutation, rigid fallback, and convergence/derivative export context.');
