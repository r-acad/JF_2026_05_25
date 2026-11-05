/* Conservative display of chordwise VLM loads at the wing quarter-chord line. */
(function(root,factory){const api=factory(typeof module==='object'&&module.exports?require('./aero_case_difference.js'):root.WingAeroCaseDifference);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingAerodynamicStripLoads=api;})(globalThis,function(Difference){
 'use strict';
 const vector=v=>Array.isArray(v)&&v.length===3&&v.every(Number.isFinite);
 const zero=()=>[0,0,0],add=(a,b)=>a.map((v,i)=>v+b[i]),sub=(a,b)=>a.map((v,i)=>v-b[i]),mul=(a,s)=>a.map(v=>v*s);
 const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
 const key=p=>JSON.stringify([p.side,p.patch,p.strip]);
 const close=(a,b)=>Math.abs(a-b)<=64*Number.EPSILON*Math.max(1,Math.abs(a),Math.abs(b));
 const message='This saved result has no complete quarter-chord load geometry. Run aerodynamics again to display span-strip loads.';

 function nativeStrips(c,reference=c?.reference){
  if(!vector(c?.reference)||!vector(reference)||!Array.isArray(c?.strip_geometry)||!Array.isArray(c?.panels))throw Error(message);
  const strips=new Map();
  for(const row of c.strip_geometry){
   if(!['left','right'].includes(row.side)||!Number.isInteger(row.patch)||!Number.isInteger(row.strip)||
      !Array.isArray(row.eta_bounds)||row.eta_bounds.length!==2||!row.eta_bounds.every(Number.isFinite)||row.eta_bounds[0]===row.eta_bounds[1]||
      !Array.isArray(row.quarter_chord_bounds)||row.quarter_chord_bounds.length!==2||!row.quarter_chord_bounds.every(vector)||!vector(row.quarter_chord_position))throw Error(message);
   const k=key(row);if(strips.has(k))throw Error('Duplicate aerodynamic strip geometry. Recompute the result.');
   const ascending=row.eta_bounds[0]<row.eta_bounds[1];
   strips.set(k,{key:k,side:row.side,patch:row.patch,strip:row.strip,
    bounds:ascending?row.eta_bounds.slice():row.eta_bounds.slice().reverse(),
    quarterBounds:ascending?row.quarter_chord_bounds.map(p=>p.slice()):row.quarter_chord_bounds.slice().reverse().map(p=>p.slice()),
    quarter:row.quarter_chord_position.slice(),force:zero(),momentReference:zero(),panelCount:0});
  }
  // Stable native order makes a reordered copy of A subtract to exact zero.
  const panels=c.panels.slice().sort((a,b)=>key(a).localeCompare(key(b))||a.chord-b.chord);
  for(const p of panels){
   const strip=strips.get(key(p));
   if(!strip||!vector(p.force_N)||!vector(p.moment_Nm))throw Error(message);
   strip.force=add(strip.force,p.force_N);
   // Native panel moments include every force segment, about c.reference.
   // A centroid cross force is not an equivalent recovery of that moment.
   strip.momentReference=add(strip.momentReference,add(p.moment_Nm,cross(sub(c.reference,reference),p.force_N)));
   strip.panelCount++;
  }
  return [...strips.values()].filter(s=>s.panelCount).sort((a,b)=>a.key.localeCompare(b.key));
 }
 function stations(strips){
  const values=strips.flatMap(s=>s.bounds).sort((a,b)=>a-b),out=[];
  for(const value of values)if(!out.length||!close(value,out.at(-1)))out.push(value);
  return out;
 }
 function quarterAt(strip,eta){
  const [a,b]=strip.bounds;
  if(close(eta,(a+b)/2))return strip.quarter.slice();
  const t=(eta-a)/(b-a);return strip.quarterBounds[0].map((v,i)=>v+t*(strip.quarterBounds[1][i]-v));
 }
 function binWrench(strips,a,b){
  const eta=(a+b)/2,cover=strips.filter(s=>s.bounds[0]<eta&&s.bounds[1]>eta);
  if(!cover.length)return null;
  const anchor=cover.slice().sort((s,t)=>(s.bounds[1]-s.bounds[0])-(t.bounds[1]-t.bounds[0])||s.key.localeCompare(t.key))[0];
  let force=zero(),momentReference=zero(),panels=0;
  for(const strip of strips){
   const overlap=Math.min(b,strip.bounds[1])-Math.max(a,strip.bounds[0]);if(overlap<=0)continue;
   const fraction=overlap/(strip.bounds[1]-strip.bounds[0]);force=add(force,mul(strip.force,fraction));momentReference=add(momentReference,mul(strip.momentReference,fraction));panels+=strip.panelCount*fraction;
  }
  return{quarter:quarterAt(anchor,eta),force,momentReference,panels};
 }
 /** Rebin to common span intervals, treating each native strip's integrated
  * force and moment as uniform in eta. This reduces every chordwise component,
  * including movable sheets with different span grids, without losing loads.
  * Quarter-chord anchors are exact at native centres; newly split positions
  * interpolate the native quarter-chord line. Moment transport is exact.
  * Differences refer both wrenches to the minuend quarter chord before A-B.
  */
 function resultants(a,b=null){
  if(b){const match=Difference?.compare(a,b);if(!match?.compatible)throw Error(match?.reason||'The cases cannot be compared.');}
  // Keep moment arithmetic local to A's reference. Forming moments about a
  // distant global zero and subtracting them would lose small physical couples.
  const reference=a?.reference,first=nativeStrips(a,reference),second=b?nativeStrips(b,reference):[],bins=[];
  for(const side of ['left','right']){
   const left=first.filter(s=>s.side===side),right=second.filter(s=>s.side===side),edges=stations([...left,...right]);
   for(let i=0;i<edges.length-1;i++){
    const lo=edges[i],hi=edges[i+1];if(close(lo,hi))continue;
    const A=binWrench(left,lo,hi),B=b?binWrench(right,lo,hi):null;if(!A&&!B)continue;
    if(!A||(b&&!B))throw Error('The compared cases cover different aerodynamic span intervals.');
    const force=B?sub(A.force,B.force):A.force.slice(),moment=B?sub(A.momentReference,B.momentReference):A.momentReference.slice();
    bins.push({side,eta_bounds:[lo,hi],eta:(lo+hi)/2,origin:A.quarter,force_N:force,
     moment_Nm:sub(moment,cross(sub(A.quarter,reference),force)),moment_origin_Nm:add(moment,cross(reference,force)),native_panel_weight:A.panels});
   }
  }
  return{bins,force_N:bins.reduce((sum,row)=>add(sum,row.force_N),zero()),
   moment_origin_Nm:bins.reduce((sum,row)=>add(sum,row.moment_origin_Nm),zero()),
   moment_roundoff_scale:[...first,...second].reduce((sum,row)=>sum+Math.hypot(...row.momentReference)+Math.hypot(...sub(row.quarter,reference))*Math.hypot(...row.force),0),
   difference:!!b,definition:'Uniform native-strip force and moment per eta; conservative common span intervals. Quarter-chord line interpolated at additional stations; pitch moments refer to case A quarter chord in differences.'};
 }
 return{resultants,nativeStrips,cross};
});
