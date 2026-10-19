"use strict";
const assert=require("node:assert/strict"),V=require("../web/svg_viewport.js"),D=require("../web/dimensioned_plan_view.js");
const near=(a,b)=>assert(Math.abs(a-b)<1e-10*Math.max(1,Math.abs(b)),`${a} != ${b}`);
const image={name:"pixel.png",width:1,height:1,dataUrl:"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII="};
const pin={image:{x:.25,y:.75},drawing:{x:23,y:-15}};
const state={...V.defaults(),image,pin,transform:{x:22.5,y:-16.5,scale:2},viewport:{x:90,y:-32,scale:1.75},filledFigures:false};
for(const validator of [V.validateState,D.validateState]){
  const saved=validator(state);assert.deepEqual(saved.pin,pin);assert.equal(saved.filledFigures,false);
  assert.deepEqual(validator(JSON.parse(JSON.stringify(saved))),saved);
  assert.equal(validator({}).pin,null);assert.equal(validator({}).filledFigures,true);
  for(const bad of [{...state,image:null},{...state,filledFigures:0},{...state,pin:{image:{x:2,y:0},drawing:pin.drawing}},{...state,pin:{image:pin.image,drawing:{x:Infinity,y:0}}}])assert.throws(()=>validator(bad));
}
for(const factor of [.02,.5,1.1,2,10]){
  const t=V.zoomTransform(state,"transform",factor,{x:100,y:200});
  near(t.x+t.scale*pin.image.x,pin.drawing.x);near(t.y+t.scale*pin.image.y,pin.drawing.y);
  const view=V.zoomTransform(state,"viewport",factor,{x:100,y:200});
  near(view.x+view.scale*pin.drawing.x,state.viewport.x+state.viewport.scale*pin.drawing.x);
  near(view.y+view.scale*pin.drawing.y,state.viewport.y+state.viewport.scale*pin.drawing.y);
}
for(const deltaMode of [0,1,2]){
  const normal=V.wheelZoomFactor({deltaY:-3,deltaMode,altKey:false}),fine=V.wheelZoomFactor({deltaY:-3,deltaMode,altKey:true});near(Math.log(fine),.1*Math.log(normal));
}
const normal=V.zoomTransform({...state,pin:null},"viewport",2,{x:100,y:80});
assert.deepEqual(normal,{x:80,y:-144,scale:3.5});
assert.throws(()=>V.imageTransformAtPin({image:{x:32768,y:1},drawing:{x:0,y:0}},1e4));
for(const [a,b]of [[{x:140,y:80},{x:380,y:180}],[{x:380,y:180},{x:140,y:80}]]){
  const visible={x:-20,y:0,width:800,height:400},selection=V.aspectWindow(a,b,visible);
  near(selection.width/selection.height,2);near(selection.x+selection.width/2,260);near(selection.y+selection.height/2,130);
  const original={x:90,y:-32,scale:1.75},next=V.windowZoomTransform(original,selection,visible),draw={x:(260-original.x)/original.scale,y:(130-original.y)/original.scale};
  near(next.x+next.scale*draw.x,380);near(next.y+next.scale*draw.y,200);near(next.scale/original.scale,800/240);
}
assert.throws(()=>V.windowZoomTransform(state.viewport,{x:0,y:0,width:0,height:1},{x:0,y:0,width:100,height:100}));
console.log("2D registration: validation, both affine anchors, exact percentages and 0.1 Alt log-step passed.");
