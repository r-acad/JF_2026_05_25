(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingColorScales=api;})(globalThis,function(){
'use strict';
/* A blue to red ramp for the contours. */
const CMAP = [
  [0.00, [0.14, 0.24, 0.50]],
  [0.25, [0.16, 0.56, 0.74]],
  [0.50, [0.28, 0.72, 0.44]],
  [0.75, [0.94, 0.79, 0.26]],
  [1.00, [0.86, 0.24, 0.22]],
];
const scales = {
  spectrum: CMAP,
  viridis: [[0,[.267,.005,.329]],[.25,[.230,.322,.546]],[.5,[.128,.567,.551]],[.75,[.369,.789,.383]],[1,[.993,.906,.144]]],
  inferno: [[0,[.001,.000,.014]],[.25,[.342,.062,.429]],[.5,[.735,.216,.330]],[.75,[.978,.558,.035]],[1,[.988,.998,.645]]],
  coolwarm: [[0,[.230,.299,.754]],[.25,[.554,.690,.996]],[.5,[.865,.865,.865]],[.75,[.957,.598,.477]],[1,[.706,.016,.150]]],
  grayscale: [[0,[.10,.10,.10]],[1,[1,1,1]]],
};
function sample(name,t){const ramp=scales[name]||CMAP,x=Math.min(1,Math.max(0,t));for(let i=1;i<ramp.length;i++){if(x<=ramp[i][0]){const [a,c]=ramp[i-1],[b,d]=ramp[i],w=(x-a)/(b-a);return c.map((v,j)=>v+(d[j]-v)*w);}}return ramp.at(-1)[1].slice();}
return {scales,sample};
});
