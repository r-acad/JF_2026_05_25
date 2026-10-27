'use strict';
// Exercise actual reaction selection/render control code with different active
// buckling and STATSUB constraint sets. Native payloads already scope reactions.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
const controls=new Map(),glyphs=[];
const input=id=>{if(!controls.has(id))controls.set(id,{checked:true,disabled:false,textContent:'',value:'1',row:{},closest(){return this.row;}});return controls.get(id);};
const state={baseline:new Float32Array(9),data:{spc:{nodes:[2]}},activeMode:-1,sensitivityMap:null,diag:1,
  results:{matches:true,available:true,static:{},analysis:'SOL105',modeKind:'buckling',reactions:{nodes:Int32Array.from([0,1]),forces:Float32Array.from([1,2,3,4,5,6]),moments:Float32Array.from([0,0,0,0,7,0])}},layers:new Map(),deformable:[]};
const ctx={state,document:{getElementById:input},Number,Set,Array,Math,EXTRA_STYLE:{SUPPORT_FORCES:{label:'Forces',color:'blue'},SUPPORT_MOMENTS:{label:'Moments',color:'blue'}},
  currentPositions:()=>state.baseline,resultAnalysisLabel:()=> 'SOL101 preload',eng:String,
  loadComponentMeshes:(name,rows)=>{glyphs.push({name,rows});return[{metadata:{glyphs:rows},dispose(){}}];},
  addLayer:(name,label,color,count,meshes)=>state.layers.set(name,{meshes,visible:true}),
  setLayerVisible:(name,on)=>{state.layers.get(name).visible=on;}};
vm.createContext(ctx);vm.runInContext(source.slice(source.indexOf('function supportReactionData()'),source.indexOf('function addAeroMoments(')),ctx);
ctx.rebuildSupportForces();assert.equal(glyphs[0].rows.length,2);assert.deepEqual(Array.from(glyphs[0].rows,r=>r.node_index),[0,1]);
assert(!input('results-show-support-forces').disabled);assert(!input('results-show-support-force-values').row.hidden);
// Both locations expose the separate label toggle, even while arrows are off.
input('show-support-force-values').checked=true;
input('show-support-forces').checked=false;state.layers.get('SUPPORT_FORCES').visible=false;ctx.syncSupportForceControls();
for(const id of ['show-support-force-values','results-show-support-force-values']){assert(input(id).checked);assert(input(id).disabled);assert.equal(input(id).row.hidden,false);assert.match(input(id).row.title,/Enable Display constraint forces/);}
assert(!input('show-support-moments').disabled);assert(!input('show-support-moment-values').disabled);assert(state.layers.get('SUPPORT_MOMENTS').visible);
input('show-support-forces').checked=true;state.layers.get('SUPPORT_FORCES').visible=true;ctx.syncSupportForceControls();
for(const id of ['show-support-force-values','results-show-support-force-values']){assert(input(id).checked);assert(!input(id).disabled);assert.match(input(id).title,/Fx, Fy, Fz \(N\)/);assert(!input(id).title.includes('Mx'));}
for(const id of ['show-support-moment-values','results-show-support-moment-values']){assert(input(id).checked);assert(!input(id).disabled);assert.match(input(id).title,/Mx, My, Mz/);assert(!input(id).title.includes('Fx'));}
input('show-support-moments').checked=false;state.layers.get('SUPPORT_MOMENTS').visible=false;ctx.syncSupportForceControls();assert(input('show-support-moment-values').disabled);assert(!input('show-support-force-values').disabled);
// Missing current-case markers must not erase an authenticated static result.
delete state.data.spc;ctx.rebuildSupportForces();assert(!input('results-show-support-forces').disabled);
state.activeMode=0;ctx.rebuildSupportForces();assert(input('results-show-support-forces').disabled);assert(!state.layers.has('SUPPORT_FORCES'));assert(!state.layers.has('SUPPORT_MOMENTS'));assert(input('results-show-support-moments').disabled);
assert.match(input('results-support-force-note').textContent,/static preload/);
for(const id of ['show-support-force-values','results-show-support-force-values']){assert(input(id).disabled);assert.equal(input(id).row.hidden,false);assert.match(input(id).row.title,/static preload/);}
state.activeMode=-1;ctx.rebuildSupportForces();assert(!input('show-support-forces').disabled);assert(state.layers.has('SUPPORT_FORCES'));
state.sensitivityMap={};ctx.rebuildSupportForces();assert(input('show-support-forces').disabled);state.sensitivityMap=null;
state.results.reactions=null;state.results.reactionNote='SPCFORCES was suppressed for this static subcase.';ctx.rebuildSupportForces();assert(input('show-support-forces').disabled);assert.match(input('results-support-force-note').textContent,/suppressed/);
state.results.reactions={nodes:Int32Array.of(0),forces:Float32Array.of(1,2,3)};ctx.rebuildSupportForces();assert(!input('show-support-forces').disabled);assert(input('show-support-moments').disabled);assert(!state.layers.has('SUPPORT_MOMENTS'));assert.match(input('show-support-moments').title,/not recovered/);
state.results.reactions.moments=Float32Array.of(4,5,6);
for(const analysis of ['SOL101','SOL106']){state.results.analysis=analysis;ctx.rebuildSupportForces();assert(!input('show-support-forces').disabled&&!input('show-support-moments').disabled);assert(state.layers.has('SUPPORT_FORCES')&&state.layers.has('SUPPORT_MOMENTS'));}
console.log('Passed 14 independent force/moment static and preload display groups.');
