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
  signed: [[0,[195/255,52/255,66/255]],[.5,[242/255,243/255,239/255]],[1,[48/255,112/255,196/255]]],
};
function sample(name,t){const ramp=scales[name]||CMAP,x=Math.min(1,Math.max(0,t));for(let i=1;i<ramp.length;i++){if(x<=ramp[i][0]){const [a,c]=ramp[i-1],[b,d]=ramp[i],w=(x-a)/(b-a);return c.map((v,j)=>v+(d[j]-v)*w);}}return ramp.at(-1)[1].slice();}
// Signed fields use their actual numerical zero, never the range midpoint.
// One-sided ranges retain only their sign's hue, including constant fields.
function valueColor(name,value,min,max){
  if(![value,min,max].every(Number.isFinite)||min>max)return null;
  if(name!=='signed')return sample(name,min===max?.5:(value-min)/(max-min));
  const red=scales.signed[0][1],zero=scales.signed[1][1],blue=scales.signed[2][1];
  const mix=(a,b,t)=>a.map((v,i)=>v+(b[i]-v)*Math.min(1,Math.max(0,t)));
  if(value===0)return zero.slice();
  if(min===max)return mix(zero,value<0?red:blue,.55);
  if(max<=0&&value<0)return mix(red,max===0?zero:[251/255,225/255,228/255],(value-min)/(max-min));
  if(min>=0&&value>0)return mix(min===0?zero:[220/255,233/255,250/255],blue,(value-min)/(max-min));
  return value<0?mix(zero,red,min<0?value/min:1):mix(zero,blue,max>0?value/max:1);
}
const css=color=>'rgb('+color.map(v=>Math.round(255*v)).join(', ')+')';
const hex=color=>'#'+color.map(v=>Math.round(255*v).toString(16).padStart(2,'0')).join('');
// Nominal IDs are separate classes, not positions on a continuous ramp.
// Adjacent entries deliberately alternate hue and brightness. Keep this order
// stable so a case retains its color when the user filters the assessment.
const CATEGORY_COLORS=Object.freeze(['#0072b2','#e87500','#009e73','#a34ec7','#f0ce32','#ed5290',
  '#24c9dc','#d53b32','#8ab83d','#4253b8','#b78351','#db8ed8',
  '#80bfee','#9c4300','#006e55','#663780','#b39b00','#a82763',
  '#007f91','#ff8b7f','#c9df72','#9698ef','#f2ba89','#9b507e']);
function categoryColor(index){
  const n=Math.max(0,Math.trunc(Number(index)||0));
  if(n<CATEGORY_COLORS.length){const c=CATEGORY_COLORS[n];return[1,3,5].map(i=>parseInt(c.slice(i,i+2),16)/255);}
  // Large ID sets retain individual, deterministic colors without repeating a
  // short palette. Labels in the discrete legend remain the exact identifier.
  const h=(n*137.507764)%360,s=.72,l=[.44,.62,.53][Math.floor(n/24)%3],a=s*Math.min(l,1-l);
  return[0,8,4].map(v=>{const k=(v+h/30)%12;return l-a*Math.max(-1,Math.min(k-3,9-k,1));});
}
function stops(name,min,max){
  if(![min,max].every(Number.isFinite)||min>max)return [];
  if(min===max)return [0,1].map(position=>({position,value:min,color:valueColor(name,min,min,max)}));
  const positions=name==='signed'?(min<0&&max>0?[0,-min/(max-min),1]:[0,.5,1]):(scales[name]||CMAP).map(s=>s[0]);
  return positions.map(position=>{const value=name==='signed'&&min<0&&max>0&&position===-min/(max-min)?0:min+(max-min)*position;return {position,value,color:valueColor(name,value,min,max)};});
}
function gradient(name,min,max){return 'linear-gradient(90deg, '+stops(name,min,max).map(s=>css(s.color)+' '+100*s.position+'%').join(', ')+')';}
return {scales,sample,valueColor,stops,gradient,css,hex,CATEGORY_COLORS,categoryColor};
});
