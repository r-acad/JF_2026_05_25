'use strict';
const assert=require('node:assert/strict'),C=require('../web/color_scales.js'),L=require('../web/viewport-legends.js'),P=require('../web/property_table_colors.js'),S=require('../web/sensitivity_table_data.js'),W=require('../web/workspace.js');
let checks=0;
for(const [min,max]of [[-2,8],[-8,2],[-10,-1],[-1,0],[1,10],[0,10],[0,0],[-3,-3],[3,3]]){
 const stops=C.stops('signed',min,max);assert.equal(stops[0].position,0);assert.equal(stops.at(-1).position,1);
 for(const value of [...new Set([min,max,(min+max)/2,...(min<=0&&max>=0?[0]:[])])]){
  const rgb=C.valueColor('signed',value,min,max),css=C.css(rgb);
  if(value<0)assert(rgb[0]>rgb[2],`negative ${value} must be red`);
  if(value>0)assert(rgb[2]>rgb[0],`positive ${value} must be blue`);
  if(value===0)assert.deepEqual(rgb,C.scales.signed[1][1]);
  assert.equal(S.valueColor(value,{min,max}),css);assert.equal(P.valueColor(value,{numeric:true,min,max},'signed'),css);checks+=3;
 }
 if(min<0&&max>0){const neutral=stops.find(s=>s.value===0);assert.equal(neutral.position,-min/(max-min));assert(C.gradient('signed',min,max).includes(100*neutral.position+'%'));checks+=2;}
 assert.equal(P.gradient({min,max},'signed'),C.gradient('signed',min,max));checks++;
}
for(const scope of ['fe','vlm','sensitivity','properties','aero-curvature'])L.setPalette(scope,'signed');
const persisted=JSON.parse(JSON.stringify(L.capture()));L.restore(null);L.restore(persisted);
for(const scope of Object.keys(persisted.palettes)){assert.equal(L.getPalette(scope),'signed');checks++;}
const view=W.newModelView(null);view.controls['result-palette']='signed';view.legends=persisted;W.validateView(view);checks++;
assert.equal(C.valueColor('signed',NaN,0,1),null);assert.equal(C.valueColor('signed',1,2,1),null);checks+=2;
console.log('Signed numerical palettes: '+checks+' checks passed');
