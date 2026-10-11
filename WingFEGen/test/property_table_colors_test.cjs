'use strict';
const assert=require('node:assert/strict'),colors=require('../web/property_table_colors.js'),panels=require('../web/panel_table_data.js'),components=require('../web/component_table_data.js');
const parameters={'material.name':'Aluminium','materials.library':[{id:2,name:'Steel'},{id:3,name:'Core'}],
 'properties.t_skin_upper':.002,'properties.t_skin_lower':.02,'properties.t_spar_web':.003,'properties.t_rib_web':.002,'properties.spar_cap_side':.02,
 'properties.stringer_flange_width':.03,'properties.stringer_height':.04,'properties.stringer_flange_thickness':.002,'properties.stringer_web_thickness':.002,
 'properties.rib_stiffener_flange_width':.03,'properties.rib_stiffener_height':.04,'properties.rib_stiffener_flange_thickness':.002,'properties.rib_stiffener_web_thickness':.002,'properties.rib_stiffeners_enabled':true,
 'leading_edge.enabled':true,'leading_edge.t_skin':.0015,'leading_edge.t_rib':.002,'leading_edge.start_rib':1,'leading_edge.end_rib':4,'leading_edge.disabled_bays':'2'};
const make=(id,skin='upper')=>({id,key:skin+':bay'+id+':stringer1:segment1',skin,stringer:1,rib_bay:id,segment:1});
const source={parameters,panels:[make(1),make(2),make(3),make(1,'lower')],layout_token:'layout'};
let s=panels.compact(source);s.parameters['properties.panels']=[{key:s.panels[1].key,layout_token:'layout',skin:{thickness:.006}},{key:s.panels[2].key,layout_token:'layout',skin:{kind:'sandwich',thickness:99}}];
const scale=(api,s,kind,field,skin='upper')=>colors.build(api,s,kind,api.matrix(s,skin),api.FIELDS[kind].find(f=>f.name===field));
let range=scale(panels,s,'skins','thickness');assert.deepEqual([range.min,range.max,range.count,range.inactive],[.002,.006,2,1]);assert.equal(range.unit,'mm');
s.parameters[panels.PARAMETER]=panels.update(s,'skins',s.panels[1].key,'thickness','4');range=scale(panels,s,'skins','thickness');assert.equal(range.max,.004);
s.parameters[panels.PARAMETER]=panels.update(s,'skins',s.panels[1].key,'thickness','');range=scale(panels,s,'skins','thickness');assert.deepEqual([range.min,range.max],[.002,.002]);assert.equal(colors.valueColor(.002,range),colors.valueColor(.002,range));assert(!colors.gradient(range).includes('NaN'));
range=scale(panels,s,'skins','thickness','lower');assert.deepEqual([range.min,range.max],[.02,.02]);
range=scale(panels,s,'skins','material');assert.equal(range.numeric,false);assert.equal(range.min,null);assert.deepEqual(range.categories,[{value:1,label:'Aluminium (ID 1)'}]);
s.parameters[panels.PARAMETER]=panels.update(s,'skins',s.panels[1].key,'material','2');range=scale(panels,s,'skins','material');assert.equal(range.categories.length,2);assert.notEqual(colors.valueColor(1,range),colors.valueColor(2,range));
for(const kind of ['sparwebs','sparcaps','ribwebs','ribstiffeners','leskins','leribs']){s=components.compact({parameters,ribs:[{},{},{},{}],layout_token:'layout'},kind);const field=components.FIELDS[kind][0];range=scale(components,s,kind,field.name);assert(range.count>0);assert.equal(range.min,range.max);s.parameters[components.PARAMETER]=components.update(s,kind,s.panels[0].key,field.name,'60');range=scale(components,s,kind,field.name);assert.equal(range.max,.06);assert(range.min<range.max);}
s=components.compact({parameters,ribs:[{},{}],layout_token:'layout'},'ribstiffeners');s.parameters[components.PARAMETER]=[{key:'rib_stiffener:1',enabled:false,height:100}];range=scale(components,s,'ribstiffeners','height');assert.deepEqual([range.min,range.max,range.count,range.inactive],[.04,.04,1,1]);range=scale(components,s,'ribstiffeners','enabled');assert.equal(range.categories.length,2);
function luminance(rgb){const a=(rgb.startsWith('#')?rgb.slice(1).match(/../g).map(x=>parseInt(x,16)):rgb.match(/\d+/g).map(Number)).map(x=>{x/=255;return x<=.04045?x/12.92:((x+.055)/1.055)**2.4;});return a[0]*.2126+a[1]*.7152+a[2]*.0722;}
for(const palette of Object.keys(colors.PALETTES))for(let i=0;i<=100;i++){const bg=colors.valueColor(i,{numeric:true,min:0,max:100},palette),fg=colors.foreground(bg),l1=luminance(bg),l2=luminance(fg);assert((Math.max(l1,l2)+.05)/(Math.min(l1,l2)+.05)>=4.5);}
console.log('Property table scales: active visible bounds, inheritance and edits, categories, all component tables, disabled stiffeners, uniform ranges, and WCAG text contrast passed');
