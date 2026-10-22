'use strict';
const assert=require('node:assert/strict'),plots=require('../web/load_plots.js');
const legacy={mode:'fe',visible:['fuel','aerodynamic']},old=JSON.stringify(legacy),state=plots.validateState(legacy);
assert.deepEqual(state,{mode:'fe',visible:['aerodynamic','fuel'],theme:'dark'});assert.equal(JSON.stringify(legacy),old);
const light={...state,theme:'light'};assert.deepEqual(plots.validateState(JSON.parse(JSON.stringify(light))),light);
assert.equal(plots.validateState().theme,'dark');for(const bad of[{...light,theme:'white'},{...light,theme:null},{...light,mode:'fake'},{...light,visible:['fuel','fuel']},{...light,extra:true}])assert.throws(()=>plots.validateState(bad));
assert(plots.plotHeight(300)>=340);assert(plots.plotHeight(1200)>plots.plotHeight(300));assert(plots.plotHeight(3000)<=520);
for(const p of Object.values(plots.THEMES)){for(const component of plots.COMPONENTS)assert(/^#[0-9a-f]{6}$/i.test(p.colors[component.key]));assert(p.colors.elliptical);}
const data={distribution:{y_m:[.25,.75],cl_chord_m:[2,-1],elliptical_cl_chord_m:[1,0],strip_width_m:[.5,.5]}},before=JSON.stringify(data);
assert.deepEqual(plots.samples(data,plots.SPECS[0]).map(p=>[p.x,p.y]),[[0,2],[.5,2],[.5,-1],[1,-1]]);assert.equal(JSON.stringify(data),before);
console.log('PASS load-plot legacy/light display state, responsive heights, theme colors and signed strip data');

// Study deserialization uses the same validator; preserve the new theme through
// the complete saved-view schema, including legacy files without the theme.
const workspace=require('../web/workspace.js'),view=workspace.newModelView();
view.loadPlots=light;workspace.validateView(view);assert.equal(workspace.completeView(JSON.parse(JSON.stringify(view))).loadPlots.theme,'light');
view.loadPlots={mode:'fe',visible:['total']};workspace.validateView(view);assert.equal(view.loadPlots.theme,'dark');
console.log('PASS complete Study view preserves light mode and accepts legacy plot state');
