'use strict';
const assert=require('node:assert/strict'),G=require('../web/geometry_display.js'),W=require('../web/workspace.js');
const value={FUEL_TANK:{color:'#12aBcD',style:'metallic',opacity:.4},AIRFOIL_2:{color:'#334455',style:'wireframe',opacity:1,visible:false},REFERENCE_0:{color:'#aa4499',style:'solid',opacity:1}};
const normalized=G.normalize(value);assert.deepEqual(normalized,value);normalized.FUEL_TANK.color='#000000';assert.equal(value.FUEL_TANK.color,'#12aBcD');
for(const invalid of [null,[],{FUEL_TANK:{color:'red',style:'solid',opacity:1}}, {FUEL_TANK:{color:'#abcdef',style:'wrong',opacity:1}},{FUEL_TANK:{color:'#abcdef',style:'solid',opacity:NaN}},{FUEL_TANK:{color:'#abcdef',style:'solid',opacity:1.1}},{AIRFOIL_0:{color:'#abcdef',style:'wireframe',opacity:1,visible:'false'}},{UPPER_SKIN:{color:'#abcdef',style:'solid',opacity:1}}])assert.throws(()=>G.normalize(invalid));
const base={controls:{},layers:{},camera:{target:[0,0,0],alpha:0,beta:1,radius:10},workspace:{activeTab:'displaygeometry',width:360,collapsed:false},activeCase:1};
const restored=W.completeView({...base,geometryAppearance:value},null);assert.deepEqual(restored.geometryAppearance,value);assert.deepEqual(W.completeView(base,null).geometryAppearance,{});assert.deepEqual(W.newModelView(null).geometryAppearance,{});
assert.throws(()=>W.validateView({...base,geometryAppearance:{AIRFOIL_0:{color:'bad',style:'wireframe',opacity:1}}}));
console.log('Geometry appearance validation: roundtrip, legacy defaults, new-model reset and invalid-data guards passed.');
