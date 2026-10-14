"use strict";
const assert=require("node:assert/strict"),A=require("../web/airfoils.js");
let checks=0;
const near=(a,b,t=1e-12)=>{assert(Math.abs(a-b)<=t,`${a} != ${b}`);checks++;};
const profile=(xu,zu,xl,zl)=>({name:"Sampled fixture",xu,zu,xl,zl});
// Independent hand-calculated extrema on different upper/lower abscissae.
const p=profile([0,.2,.6,1],[0,.12,.08,0],[0,.4,.8,1],[0,-.04,-.02,0]),m=A.profileMetrics(p);
near(m.maxThickness.value,.14);near(m.maxThickness.x,.2);
near(m.maxCamber.value,.05);near(m.maxCamber.x,.2);
assert.deepEqual(m.xs,[0,.2,.4,.6,.8,1]);checks++;
for(let i=0;i<m.xs.length;i++){near(m.camber[i],(m.upper[i]+m.lower[i])/2);near(m.thickness[i],m.upper[i]-m.lower[i]);}
// A dense independent scan cannot exceed the exact piecewise-linear maxima.
for(let k=0;k<=2000;k++){const x=k/2000,u=A.tableOrdinate(p.xu,p.zu,x),l=A.tableOrdinate(p.xl,p.zl,x);assert(u-l<=m.maxThickness.value+1e-12);assert(Math.abs((u+l)/2)<=m.maxCamber.value+1e-12);}checks+=4002;
const flat=A.profileMetrics(profile([0,.2,.7,1],[0,.08,.08,0],[0,.2,.7,1],[0,-.04,-.04,0]));
assert.deepEqual(flat.maxThickness.locations,[{start:.2,end:.7}]);assert.deepEqual(flat.maxCamber.locations,[{start:.2,end:.7}]);checks+=2;
const symmetric=A.profileMetrics(A.nacaProfile("0012"));assert(symmetric.maxCamber.zero);assert.equal(A.locationLabel(symmetric.maxCamber),"all x/c (zero throughout)");checks+=2;
const reflected=A.profileMetrics(profile(p.xl,p.zl.map(v=>-v),p.xu,p.zu.map(v=>-v)));near(reflected.maxCamber.signedValue,-m.maxCamber.signedValue);near(reflected.maxThickness.value,m.maxThickness.value);
const reflex=A.profileMetrics(profile([0,.25,.5,.75,1],[0,.07,.03,.03,0],[0,.25,.5,.75,1],[0,-.03,-.03,-.07,0]));
assert.equal(reflex.maxCamber.locations.length,2);near(reflex.maxCamber.value,.02);checks++;
const cambered=A.profileMetrics(A.nacaProfile("2412"));assert(Math.abs(cambered.maxThickness.value-.12)>1e-5,"Do not substitute nominal NACA thickness for sampled chordwise thickness");checks++;
for(const invalid of [profile([0,.3,.2,1],[0,.1,.1,0],[0,.5,1],[0,-.1,0]),profile([0,.5,2],[0,.1,0],[0,.5,1],[0,-.1,0]),profile([0,.5,1],[0,-.1,0],[0,.5,1],[0,.1,0])]){assert.throws(()=>A.profileMetrics(invalid));checks++;}
// Actual adjacent-section formula, using unequal station spacing. The maxima
// are measured from blended tables, not interpolated extrema/nominal codes.
for(const cosine of [false,true]){
 const eta=.35,left=.2,right=.8,t=(eta-left)/(right-left),w=cosine?(1-Math.cos(Math.PI*t))/2:t,other=A.nacaProfile("0010"),xs=[...new Set([...p.xu,...p.xl,...other.xu,...other.xl])].sort((a,b)=>a-b);
 const blend=profile(xs,xs.map(x=>(1-w)*A.tableOrdinate(p.xu,p.zu,x)+w*A.tableOrdinate(other.xu,other.zu,x)),xs,xs.map(x=>(1-w)*A.tableOrdinate(p.xl,p.zl,x)+w*A.tableOrdinate(other.xl,other.zl,x)));
 const bm=A.profileMetrics(blend);for(let i=0;i<xs.length;i++)near(bm.camber[i],(1-w)*(A.tableOrdinate(p.xu,p.zu,xs[i])+A.tableOrdinate(p.xl,p.zl,xs[i]))/2);
}
console.log(JSON.stringify({passed:true,checks,sampledNACA2412:{thickness:cambered.maxThickness,camber:cambered.maxCamber}},null,2));
