'use strict';
const assert=require('node:assert/strict'),S=require('../web/aerodynamic_strip_loads.js'),A=require('../web/aerodynamic_study.js'),SVG=require('../web/aerodynamic_view_svg.js');
const add=(a,b)=>a.map((v,i)=>v+b[i]),sub=(a,b)=>a.map((v,i)=>v-b[i]),scale=(a,s)=>a.map(v=>v*s),cross=S.cross;
const sum=rows=>rows.reduce(add,[0,0,0]),near=(a,b,tol=2e-12)=>a.forEach((x,i)=>assert(Math.abs(x-b[i])<=tol*Math.max(1,Math.abs(x),Math.abs(b[i])),`${a} != ${b}`));
function fixture({reference=[.2,.3,.4],offset=[0,0,0],factor=1}={}){
 const c={id:1,reference,span_m:20,area_m2:40,mac_m:2,condition:{alpha:5,beta:0},vector_frame:'construction C',strip_geometry:[],panels:[]};
 let id=0;
 for(const [s,side]of ['left','right'].entries()){
  const sign=side==='left'?-1:1,q=e=>add([.5,sign*10*e,.05*e*e],offset);
  for(const [component,bounds]of [[[0,1]],[[0,.4],[.4,1]]].entries())for(const [index,[lo,hi]]of bounds.entries()){
   const patch=1+s*2+component,strip=index+1,eta=(lo+hi)/2;
   c.strip_geometry.push({side,patch,strip,eta_bounds:[lo,hi],quarter_chord_bounds:[q(lo),q(hi)],quarter_chord_position:q(eta)});
   for(let chord=1;chord<=2;chord++){
    id++;const x=component+chord*.2,position=add([x,sign*10*eta,.1],offset),force=scale([id%3-1,2-id%2,3+id],factor),couple=scale([.2,2-id%5,.3],factor),application=add(position,[.03,-.02,.05]);
    const moment=add(cross(sub(application,reference),force),couple),corners=[[x-.1,sign*10*lo,.1],[x+.1,sign*10*lo,.1],[x+.1,sign*10*hi,.1],[x-.1,sign*10*hi,.1]].map(p=>add(p,offset));
    c.panels.push({id,side,region:side+' / '+component,control:component?'Flap':'',patch,strip,chord,eta,chord_fraction:component?.7+chord*.1:chord*.1,area_m2:(hi-lo)*2,position,corners,force_N:force,moment_Nm:moment});
   }
  }
 }
 c.panel_count=c.panels.length;return c;
}
const c=fixture(),before=JSON.stringify(c),loads=S.resultants(c);
assert.equal(loads.bins.length,4,'The full-chord strip is conservatively split at the independent flap span boundary.');
assert.deepEqual(loads.bins.filter(b=>b.side==='right').map(b=>b.eta_bounds),[[0,.4],[.4,1]]);
const F=sum(c.panels.map(p=>p.force_N)),M=sum(c.panels.map(p=>add(p.moment_Nm,cross(c.reference,p.force_N))));
near(loads.force_N,F);near(loads.moment_origin_Nm,M);
near(sum(loads.bins.map(b=>add(b.moment_Nm,cross(b.origin,b.force_N)))),M);
assert.equal(JSON.stringify(c),before,'Display aggregation cannot change solver arrays.');
assert(loads.bins.every(b=>b.native_panel_weight>0));

// A changed reference and changed geometry are both transported to A's quarter chord.
const b=fixture({reference:[-2,1,3],offset:[.25,-.4,.6],factor:.6});b.id=2;
const delta=S.resultants(c,b),Fb=sum(b.panels.map(p=>p.force_N)),Mb=sum(b.panels.map(p=>add(p.moment_Nm,cross(b.reference,p.force_N))));
near(delta.force_N,sub(F,Fb));near(delta.moment_origin_Nm,sub(M,Mb));
near(sum(delta.bins.map(row=>add(row.moment_Nm,cross(row.origin,row.force_N)))),sub(M,Mb));
const reverse=S.resultants(b,c);near(reverse.force_N,scale(delta.force_N,-1));near(reverse.moment_origin_Nm,scale(delta.moment_origin_Nm,-1));

// A remote model origin must not erase a small local couple by cancellation.
const local=fixture({reference:[0,0,0]});for(const p of local.panels){p.force_N=[0,0,10];p.moment_Nm=add(cross(add(p.position,[.125,0,0]),p.force_N),[0,5,0]);}
const translated=structuredClone(local),translation=[1e9,-1e9,1e9];translated.reference=add(translated.reference,translation);
for(const p of translated.panels){p.position=add(p.position,translation);p.corners=p.corners.map(v=>add(v,translation));}
for(const row of translated.strip_geometry){row.quarter_chord_position=add(row.quarter_chord_position,translation);row.quarter_chord_bounds=row.quarter_chord_bounds.map(v=>add(v,translation));}
const localResult=S.resultants(local),remoteResult=S.resultants(translated);
for(let i=0;i<localResult.bins.length;i++)near(remoteResult.bins[i].moment_Nm,localResult.bins[i].moment_Nm);
assert.deepEqual(A.quarterChordArrowData(translated).groups.map(g=>g.moments.map(a=>a.vector)),A.quarterChordArrowData(local).groups.map(g=>g.moments.map(a=>a.vector)));

// Native panel and metadata order, including descending left eta, is immaterial.
const reordered=structuredClone(c);reordered.panels.reverse();reordered.strip_geometry.reverse();
for(const row of reordered.strip_geometry){row.eta_bounds.reverse();row.quarter_chord_bounds.reverse();}
const zero=S.resultants(c,reordered);assert.deepEqual(zero.force_N,[0,0,0]);assert.deepEqual(zero.moment_origin_Nm,[0,0,0]);
assert(zero.bins.every(row=>row.force_N.every(n=>n===0)&&row.moment_Nm.every(n=>n===0)));
assert.deepEqual(A.quarterChordArrowData(c,reordered).groups,[],'A-A produces no force or moment arrow.');

const arrows=A.quarterChordArrowData(c);assert(arrows.available);assert.equal(arrows.unit,'N');assert.equal(arrows.placement,'quarter_chord');
assert.equal(arrows.groups.reduce((n,g)=>n+g.arrows.length,0),4);
assert.equal(arrows.maximum*arrows.scale,2.4);assert.equal(arrows.momentMaximum*arrows.momentScale,2.4);
const couple=fixture();for(const p of couple.panels){p.force_N=[0,0,0];p.moment_Nm=[0,5,0];}
const noseUp=A.quarterChordArrowData(couple);assert(noseUp.groups.every(g=>g.arrows.length===0&&g.moments.every(m=>m.vector[0]>0&&m.vector[1]===0&&m.vector[2]===0)));
for(const p of couple.panels)p.moment_Nm=[0,-5,0];const noseDown=A.quarterChordArrowData(couple);assert(noseDown.groups.every(g=>g.moments.every(m=>m.vector[0]<0)));
for(const p of couple.panels)p.moment_Nm=[0,1e-17,0];assert.deepEqual(A.quarterChordArrowData(couple).groups,[],'Unresolvable numerical moment noise must not normalize into long glyphs.');
assert(!A.quarterChordArrowData({...c,strip_geometry:undefined}).available);
assert.match(A.quarterChordArrowData({...c,strip_geometry:undefined}).reason,/Run aerodynamics again/);
assert.throws(()=>S.resultants({...c,strip_geometry:[...c.strip_geometry,c.strip_geometry[0]]}));
assert.throws(()=>S.resultants({...c,panels:c.panels.map((p,i)=>i? p:{...p,moment_Nm:undefined})}));
assert.throws(()=>S.resultants(c,{...b,panels:b.panels.slice(1),panel_count:b.panels.length-1}));
assert.equal(A.validateState({}).vectorPlacement,'panels');assert(A.validateState({}).quarterMoments);
assert.equal(A.validateState({vectorPlacement:'quarter_chord',quarterMoments:false}).vectorPlacement,'quarter_chord');
assert.throws(()=>A.validateState({vectorPlacement:'bad'}));assert.throws(()=>A.validateState({quarterMoments:'true'}));
const svg=SVG.svg({width:800,height:300,title:'Quarter-chord span loads',lines:[{points:[{x:100,y:100,z:.5},{x:200,y:100,z:.5}],surface:'strip:right',quantity:'pitch_moment',color:'#ffb833',label:'Pitching moment / N m; -X_C nose down, +X_C nose up'}],vectorLegend:{title:'Quarter-chord forces / N and pitch / N m; separate scales',items:[{label:'Pitch moment / N m',color:'#ffb833'}]}});
assert(svg.includes('data-arrow-quantity="pitch_moment"'));assert(svg.includes('separate scales'));assert(svg.includes('-X_C nose down, +X_C nose up'));
console.log('PASS Conservative full-chord rebinning, force/moment transport, changed references/geometry, exact reordered A-A, pitch signs, immutable arrays, persistence and SVG semantics.');
