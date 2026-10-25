'use strict';
const assert=require('node:assert/strict'),plots=require('../web/load_plots.js');
const legacy={mode:'fe',visible:['fuel','aerodynamic']},old=JSON.stringify(legacy),state=plots.validateState(legacy);
assert.deepEqual(state,{mode:'fe',visible:['aerodynamic','fuel'],theme:'dark',verticalGrid:true,gridSpacing:null});assert.equal(JSON.stringify(legacy),old);
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

const gridState={...light,verticalGrid:false,gridSpacing:.25};assert.deepEqual(plots.validateState(gridState),gridState);
view.loadPlots=gridState;workspace.validateView(view);assert.deepEqual(workspace.completeView(JSON.parse(JSON.stringify(view))).loadPlots,gridState);
for(const bad of[{...light,verticalGrid:1},{...light,gridSpacing:0},{...light,gridSpacing:-1},{...light,gridSpacing:Infinity},{...light,gridSpacing:NaN},{...light,gridSpacing:'.5'}])assert.throws(()=>plots.validateState(bad));
assert.deepEqual(plots.verticalGridLines(.3,2.8,.5).values,[.5,1,1.5,2,2.5]);
assert.deepEqual(plots.verticalGridLines(-1.1,.1,.25).values,[-1,-.75,-.5,-.25,0]);
const decimal=plots.verticalGridLines(.3,.6,.1);assert.equal(decimal.values.length,4);assert(Math.abs(decimal.values[0]-.3)<1e-14);assert(Math.abs(decimal.values[3]-.6)<1e-14);
for(const [a,b]of[[0,5.7],[10,50],[0,.0001]]){const grid=plots.verticalGridLines(a,b);assert(grid.spacing>0&&grid.values.length>=4&&grid.values.length<=11&&!grid.limited);}
const dense=plots.verticalGridLines(0,10,.0001);assert(dense.limited);assert.deepEqual(dense.values,[]);assert(dense.minimumSpacing>0);assert(plots.verticalGridLines(0,10,dense.minimumSpacing*1.001).values.length<=plots.MAX_GRID_LINES);
assert(plots.verticalGridLines(1e10,1e10+1,1e-9).limited);assert.throws(()=>plots.verticalGridLines(0,1,0));assert.throws(()=>plots.verticalGridLines(0,1,-1));
console.log('PASS persisted vertical grids, global-coordinate alignment, fractional/negative spans, automatic spacing and bounded SVG complexity');

const engineState=plots.validateState({mode:'fe',visible:['engine','total']});
assert.deepEqual(engineState.visible,['engine','total']);
view.loadPlots=engineState;workspace.validateView(view);assert.deepEqual(workspace.completeView(JSON.parse(JSON.stringify(view))).loadPlots,engineState);
const weights=require('../web/weights.js'),massData={totals:{structure_mass_kg:10,structure_weight_N:98.0665,engine_mass_kg:20,engine_weight_N:196.133,
  nonstructural_mass_kg:2,nonstructural_weight_N:19.6133,fuel_mass_kg:3,fuel_weight_N:29.41995,loaded_mass_kg:33,loaded_weight_N:323.61945},components:[]};
const original=JSON.stringify(massData),massRows=weights.totalRows(massData);
assert.equal(massRows.find(r=>r.id==='structure').mass,10);assert.equal(massRows.find(r=>r.id==='engine').mass,20);
assert.equal(massRows.find(r=>r.id==='loaded').mass,33);assert.equal(massRows.find(r=>r.id==='loaded').label,'Structure + engines + fuel');
assert.equal(massRows.filter(r=>r.id==='engine').length,1);assert.equal(JSON.stringify(massData),original);
assert(!weights.totalRows({totals:{...massData.totals,engine_mass_kg:0},components:[]}).some(r=>r.id==='engine'));
console.log('PASS engine curve Study state and separate mass subtotal without double counting');
