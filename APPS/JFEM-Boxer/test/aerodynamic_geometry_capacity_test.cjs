'use strict';
const assert=require('node:assert/strict'),P=require('../web/planform_view.js'),L=require('../web/loft.js'),M=require('../web/movable_surfaces.js'),A=require('../web/airfoils.js');
const n=105,points=Array.from({length:n},(_,i)=>({eta:(i+1)/(n+1),dxc:0}));
assert.equal(P.normalizePointRows(points,'planform.leading_edge_points').length,n);
assert.equal(L.normalizeSchedule(points.map(({eta})=>({eta,shift_percent:0})),'vertical_shift').length,n);
const controls=Array.from({length:n},(_,i)=>({name:'Control '+i,kind:'flap',edge:'trailing',eta_start:i/n,eta_end:(i+1)/n,hinge_start:.75,hinge_end:.75,deflection:0,color:'#ffcc00'}));
assert.equal(M.normalize(controls).length,n);
assert.throws(()=>L.normalizeSchedule([{eta:.2,twist:0},{eta:.2,twist:1}],'twist'),/distinct/);
// More than the old 20,000 coordinates per surface / 40,000 total ceiling.
const profile=A.nacaProfile('0012',{n:20001}),coords=profile.xu.map((x,i)=>[x,profile.zu[i]]).reverse().concat(profile.xl.slice(1).map((x,i)=>[x,profile.zl[i+1]]));
const parsed=A.parseCoordinateFile('Dense section\n'+coords.map(p=>p.join(' ')).join('\n'));
assert.equal(parsed.xu.length,20001);assert.equal(parsed.xl.length,20001);
assert(A.profileMetrics(parsed).maxThickness.value>0);
// Extrema used to spread the entire input into Math.max/min and fail for
// large coordinate tables; validate their streaming reductions as well.
const many=150001,x=Array.from({length:many},(_,i)=>i/(many-1)),z=x.map(v=>.06*Math.sin(Math.PI*v));
assert(Math.abs(A.profileMetrics({xu:x,zu:z,xl:x,zl:z.map(v=>-v)}).maxThickness.value-.12)<1e-12);
const SVG=require('../web/aerodynamic_view_svg.js'),line={points:[{x:0,y:0,z:.5},{x:1,y:1,z:.5}],color:'#fff'};
const exported=SVG.svg({width:800,height:600,title:'Large wake export',lines:Array(many).fill(line)});
assert.equal(Array.from(exported.matchAll(/<polyline /g)).length,many);
console.log('PASS: >100 geometry stations/controls, >40000 airfoil coordinates, 150001-point extrema and 150001 SVG filaments retain validity checks.');
