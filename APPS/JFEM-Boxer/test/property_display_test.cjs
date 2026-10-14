'use strict';
const assert=require('node:assert/strict'),P=require('../web/property_display.js');let checks=0;
const eq=(a,b)=>{assert.deepEqual(a,b);checks++;},near=(a,b)=>{assert(Math.abs(a-b)<1e-10*Math.max(1,Math.abs(b)));checks++;};
const aluminum={id:1,name:'Aluminium',E_Pa:71e9,nu:.33,rho_kg_m3:2780},steel={id:2,name:'Steel',E_Pa:210e9,nu:.3,rho_kg_m3:7850},foam={id:3,name:'Foam',E_Pa:1e8,nu:.3,rho_kg_m3:80};
const groups=[{pid:1,kind:'quad',eids:[101,109],properties:{type:'PSHELL',thickness_m:.002,areal_mass_kg_m2:5.56,material:aluminum}},
 {pid:5000001,kind:'tria',eids:[120],properties:{type:'PCOMP',thickness_m:.0092,face_thickness_m:.0006,core_thickness_m:.008,areal_mass_kg_m2:10.06,plies:[{material:steel},{material:foam},{material:steel}]}},
 {pid:7000001,kind:'bar',eids:[401],properties:{type:'PBARL',material:steel,section:{type:'PBARL',shape:'T',dimensions_m:[.03,.04,.002,.002],area_m2:.000136,I1_m4:2e-8,I2_m4:4e-9,J_m4:7e-11}}},
 {pid:13,kind:'bar',eids:[402],properties:{type:'PBAR',material:aluminum,section:{type:'PBAR',shape:'BAR',dimensions_m:[.02,.02],area_m2:.001,I1_m4:1e-8,I2_m4:1e-8,J_m4:1.4e-7}}},
 {kind:'rbe3',eids:[999],properties:{thickness_m:1}}];
const data={groups},field=(id,role='single')=>P.build(data,{field:id,materialRole:role});
eq([...field('shell_thickness').byId],[[101,2],[109,2],[120,9.2]]);eq(field('shell_thickness').total,5);
near(field('face_thickness').byId.get(120),.6);near(field('core_thickness').byId.get(120),8);near(field('areal_mass').byId.get(120),10.06);near(field('mean_density').byId.get(120),10.06/.0092);
near(field('beam_area').byId.get(401),136);near(field('beam_area').byId.get(402),1000);near(field('beam_I1').byId.get(401),20000);near(field('beam_I2').byId.get(401),4000);near(field('beam_J').byId.get(401),70);
for(const [id,n]of [['beam_height',40],['beam_width',30],['beam_flange',2],['beam_web',2]])near(field(id).byId.get(401),n);
eq(field('beam_web').byId.has(402),false);eq(field('E').byId.has(120),false);near(field('E').byId.get(101),71);near(field('E','face').byId.get(120),210);near(field('E','core').byId.get(120),.1);eq(field('E','core').byId.size,1);near(field('nu','face').byId.get(120),.3);near(field('rho','core').byId.get(120),80);
const m=field('material');eq(m.categories.length,3);assert(m.categories.some(c=>c.label==='Faces: MAT1 2 · Steel; core: MAT1 3 · Foam'));checks++;eq(m.byId.get(101),m.byId.get(402));assert.notEqual(m.byId.get(120),m.byId.get(401));checks++;
eq(field('section_type').categories.map(c=>c.key),['PBAR:BAR','PBARL:T']);
const bytes=new Uint8Array(9);new DataView(bytes.buffer).setInt32(1,239,true);new DataView(bytes.buffer).setInt32(5,300,true);eq(P.ids(bytes.subarray(1)),[239,300]);
const missing=P.build({groups:[{kind:'quad',pid:8,eids:[33],properties:{}}]},{field:'E'});eq([missing.count,missing.min,missing.max],[0,0,0]);
for(const value of [{field:'junk'},{materialRole:'average'},{enabled:1},{field:'E',extra:true},[]]){assert.throws(()=>P.validateState(value));checks++;}
eq(P.validateState(null),P.defaults);eq(P.build({groups:[]},{field:'material'}).categories,[]);console.log('Generated property display: '+checks+' assertions passed');
