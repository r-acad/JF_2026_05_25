'use strict';
const assert=require('node:assert/strict'),section=require('../web/section_editor.js'),geometry=require('../web/sections.js'),editor=require('../web/rf_property_editor.js'),panels=require('../web/panel_table_data.js'),colors=require('../web/property_table_colors.js');
const b=0,h=.07085,tf=0,tw=.0061;
for(const model of ['shell','beam']){
 const result=section.section('T',[b,h,tf,tw],{blade:true,shell:model==='shell'});
 assert(result.valid);assert.equal(result.kind,'BLADE');assert.equal(result.area,h*tw);assert.equal(result.centroidDepth,h/2);
 const values={flange_width:b,height:h,flange_thickness:tf,web_thickness:tw,material:1};
 assert.doesNotThrow(()=>panels.validateSection(values,'stringers',{'stringers.model':model}));
 assert(colors.dormant('stringers',values,'flange_thickness'));
 assert.throws(()=>panels.validateSection({...values,web_thickness:0},'stringers',{'stringers.model':model}),/positive/);
 assert.throws(()=>panels.validateSection({...values,flange_width:.03},'stringers',{'stringers.model':model}),/positive/);
}
// The same real rectangle is extruded above and below the skin, with no
// visual flange, offset double counting or massless widening for visibility.
const definition={type:'PBARL',shape:'BAR',dimensions_m:[tw,h],offset_y_m:-h/2,polygon_yz_m:[[h/2,-tw/2],[h/2,tw/2],[-h/2,tw/2],[-h/2,-tw/2]]};
const mesh=geometry.geometry(new Float32Array([0,0,0,0,1,0,0,0,-.3,0,1,-.3]),new Int32Array([0,1,2,3]),new Float32Array([0,0,1,0,0,-1]),definition);
assert(mesh.positions.every(Number.isFinite));
function bounds(e,c){const values=[];for(let i=e*mesh.verticesPerElement;i<(e+1)*mesh.verticesPerElement;i++)values.push(mesh.positions[3*i+c]);return[Math.min(...values),Math.max(...values)];}
const close=(a,b)=>assert(Math.abs(a-b)<3e-8,`${a} != ${b}`);
const upper=bounds(0,2),lower=bounds(1,2),width=bounds(0,0);close(upper[0],-h);close(upper[1],0);close(lower[0],-.3);close(lower[1],-.3+h);close(width[1]-width[0],tw);
const key='upper:1:1:1',context={parameters:{'material.name':'Aluminium','materials.library':[],'materials.bars':[],'materials.shells':[],'properties.panels':[],'properties.components':[],'properties.ribs':[],'properties.spar_bays':[],'properties.stringer_flange_width':b,'properties.stringer_height':h,'properties.stringer_flange_thickness':tf,'properties.stringer_web_thickness':tw,'stringers.model':'beam'},panels:[{id:1,key,skin:'upper',rib_bay:1,stringer:1,segment:1,shell_pid:5000001,stringer_pid:7000001,label:'Upper R1–R2'}],groups:[{pid:7000001}],ribs:[{},{}],layout_token:'blade'};
const descriptor=editor.resolve(context,7000001);assert(descriptor.editable);
const update=editor.prepare(context,7000001,{height:'80',web_thickness:'7',flange_thickness:'-99'});
assert.equal(update.rows[0].stringer.height,.08);assert.equal(update.rows[0].stringer.web_thickness,.007);assert.equal(update.rows[0].stringer.flange_thickness,undefined);
assert.throws(()=>editor.prepare(context,7000001,{height:'60'}),/minimum gauge/);
console.log('PASS Blade-only shell/beam forms, physical 3D rectangle and RF property editing retain geometry and minimum gauges.');
