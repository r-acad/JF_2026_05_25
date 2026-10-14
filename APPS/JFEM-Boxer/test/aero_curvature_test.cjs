"use strict";
const assert=require("node:assert/strict"),{gaussianCurvature}=require("../web/aero_display.js");
function grid(n,surface){
 const positions=[],indices=[];
 for(let j=0;j<n;j++)for(let i=0;i<n;i++)positions.push(...surface(-1+2*i/(n-1),-1+2*j/(n-1)));
 for(let j=0;j<n-1;j++)for(let i=0;i<n-1;i++){const a=j*n+i;indices.push(a,a+1,a+n+1,a,a+n+1,a+n);}
 return{positions,indices};
}
const plane=grid(17,(x,y)=>[x,y,.7*x+.3*y+4]),flat=gaussianCurvature(plane.positions,plane.indices);
assert.equal(flat.available,15*15);assert.equal(flat.unavailable,17*17-15*15);assert.equal(flat.min,0);assert.equal(flat.max,0);
const saddle=grid(41,(x,y)=>[x,y,(x*x-y*y)/2]),negative=gaussianCurvature(saddle.positions,saddle.indices),middle=20*41+20;
assert(Math.abs(negative.values[middle]+1)<.004,negative.values[middle]);assert(negative.max<0);
const dome=grid(41,(x,y)=>[x,y,(x*x+y*y)/2]),positive=gaussianCurvature(dome.positions,dome.indices);
assert(Math.abs(positive.values[middle]-1)<.004,positive.values[middle]);assert(positive.min>0);
const scaled=gaussianCurvature(dome.positions.map(v=>v*7),dome.indices);assert(Math.abs(scaled.values[middle]-positive.values[middle]/49)<1e-12);
const cylinder=grid(21,(x,y)=>[Math.sin(x),y,Math.cos(x)]),developable=gaussianCurvature(cylinder.positions,cylinder.indices);
assert.equal(developable.min,0);assert.equal(developable.max,0);
const masked=gaussianCurvature(dome.positions,dome.indices,{excluded:[middle]});assert(Number.isNaN(masked.values[middle]));assert.equal(masked.available,positive.available-1);
const badIndices=[...dome.indices,middle,middle+1,middle];const bad=gaussianCurvature(dome.positions,badIndices);assert(Number.isNaN(bad.values[middle]));assert(Number.isNaN(bad.values[middle+1]));
const translated=dome.positions.map((v,i)=>v+[200,-350,70][i%3]),invariant=gaussianCurvature(translated,dome.indices);
assert(Math.abs(invariant.values[middle]-positive.values[middle])<1e-10);
console.log("Aerodynamic curvature: planes/cylinder, dome/saddle analytic curvature, scale/translation, boundaries and degeneracy passed.");
