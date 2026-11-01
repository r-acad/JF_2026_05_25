'use strict';
const assert=require('node:assert/strict'),D=require('../web/aero_case_difference.js');
const clone=value=>JSON.parse(JSON.stringify(value));
function panel(id,patch,area,force){return{id,patch,strip:1,chord:1,side:patch===1?'left':'right',region:'wing / flap',control:'flap',eta:.5,chord_fraction:.75,corners:[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],position:[.5,.5,0],area_m2:area,normal:[0,0,1],force_N:force,delta_cp:2,delta_pressure_Pa:20,circulation_m2_s:4,speed_ratio:1.2,force_wind_N:[1,2,3],wind_loads_N:[1,2,3],moment_Nm:[1,2,3],velocity_m_s:[70,0,0]};}
const a={id:2,condition:{alpha:5},vector_frame:'construction C',span_m:10,area_m2:20,mac_m:2,panel_count:2,panels:[panel(1,1,2,[2,4,8]),panel(2,2,1,[0,0,6])],force_N:[2,4,14],coefficients:{wind:{force:[1,2,3]}},derivatives:{},strips:[],moment_Nm:[1,2,3],CDi_trefftz:.03,span_efficiency:.9,trefftz:{},residual_over_V:.001,wake:{sheets:[]},wake_origins:[[0,0,0]],wake_direction:[1,0,0],wake_model:'relaxed'};
const b=clone(a);b.id=1;b.panels[0].force_N=[1,2,4];b.panels[0].area_m2=1;b.panels[0].delta_cp=.5;b.panels[0].delta_pressure_Pa=5;b.panels[0].circulation_m2_s=1;b.panels[0].speed_ratio=1;b.panels[1].force_N=[0,0,2];
// Array order and generated global IDs need not match; material panel keys do.
b.panels.reverse();b.panels.forEach(p=>p.id+=10);
const before=JSON.stringify([a,b]),difference=D.subtract(a,b);
assert.equal(D.compare(a,b).compatible,true);
assert.deepEqual(difference.panels.map(p=>p.force_N),[[1,2,4],[0,0,4]]);
assert.deepEqual(difference.panels.map(p=>p.pressure_vector_Pa),[[0,0,0],[0,0,4]]);
assert.equal(difference.panels[0].delta_cp,1.5);assert.equal(difference.panels[0].delta_pressure_Pa,15);assert.equal(difference.panels[0].circulation_m2_s,3);assert(Math.abs(difference.panels[0].speed_ratio-.2)<1e-12);
assert.equal(difference.difference.label,'Case 2 - Case 1');assert.equal(difference.difference.minuend,2);assert.equal(difference.difference.subtrahend,1);assert.deepEqual(difference.force_N,[1,2,8]);
for(const k of ['coefficients','derivatives','strips','moment_Nm','CDi_trefftz','span_efficiency','trefftz','residual_over_V','wake','wake_origins','wake_direction','wake_model'])assert(!Object.hasOwn(difference,k),k);
for(const k of ['force_wind_N','wind_loads_N','moment_Nm','velocity_m_s'])assert(!Object.hasOwn(difference.panels[0],k),k);
assert.equal(JSON.stringify([a,b]),before,'Inputs stay unchanged');
const zero=D.subtract(a,a);assert(zero.panels.every(p=>p.force_N.every(v=>v===0)&&p.pressure_vector_Pa.every(v=>v===0)));assert(zero.panels.every(p=>p.delta_cp===0));
const inverse=D.subtract(b,a);for(const p of difference.panels){const q=inverse.panels.find(q=>q.patch===p.patch);for(let i=0;i<3;i++){assert.equal(p.force_N[i],-q.force_N[i]||0);assert.equal(p.pressure_vector_Pa[i],-q.pressure_vector_Pa[i]||0);}}
// A control deflection can move corresponding panels without changing their grid.
const moved=clone(b);moved.panels[0].corners=moved.panels[0].corners.map(([x,y,z])=>[x,y,z+.1]);moved.panels[0].position[2]+=.1;
assert.equal(D.compare(a,moved).geometryChanged,true);assert.deepEqual(D.subtract(a,moved).panels[0].corners,a.panels[0].corners);
function reject(edit,message){const invalid=clone(b);edit(invalid);const verdict=D.compare(a,invalid);assert.equal(verdict.compatible,false);assert.match(verdict.reason,message);assert.throws(()=>D.subtract(a,invalid),message);}
reject(c=>c.panels.pop(),/panel count/i);
reject(c=>c.panels[0].chord=2,/topology/i);
reject(c=>c.panels[0].control='aileron',/topology/i);
reject(c=>c.panels[0].eta+=.01,/spacing/i);
reject(c=>c.panels[0].chord_fraction+=.01,/spacing/i);
reject(c=>c.panels[1]=clone(c.panels[0]),/duplicate/i);
reject(c=>delete c.panels[0].force_N,/computed panel forces/i);
reject(c=>c.panels[0].force_N[0]=Infinity,/computed panel forces/i);
reject(c=>c.panels[0].area_m2=0,/area/i);
reject(c=>c.panels[0].corners[0][0]=NaN,/geometry/i);
reject(c=>delete c.panels[0].chord_fraction,/coordinates/i);
reject(c=>c.vector_frame='body B',/vector frames/i);
reject(c=>c.span_m=12,/reference geometry/i);
const missing=clone(b);delete missing.panels[1].delta_cp;assert.equal(D.subtract(a,missing).panels[0].delta_cp,null);
console.log('PASS Sweep differences: stable material-panel pairing, geometry checks, signed force and pressure vectors, scalar subtraction, reversed/self comparison, no false wake/result quantities and immutable inputs.');
