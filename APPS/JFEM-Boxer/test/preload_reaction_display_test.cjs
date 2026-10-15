'use strict';
// Exercise actual reaction selection/render control code with different active
// buckling and STATSUB constraint sets. Native payloads already scope reactions.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
const controls=new Map(),glyphs=[];
const input=id=>{if(!controls.has(id))controls.set(id,{checked:true,disabled:false,textContent:'',value:'1',row:{},closest(){return this.row;}});return controls.get(id);};
const state={baseline:new Float32Array(9),data:{spc:{nodes:[2]}},activeMode:-1,sensitivityMap:null,diag:1,
  results:{matches:true,available:true,static:{},analysis:'SOL105',modeKind:'buckling',reactions:{nodes:Int32Array.from([0,1]),forces:Float32Array.from([1,2,3,4,5,6]),moments:Float32Array.from([0,0,0,0,7,0])}},layers:new Map(),deformable:[]};
const ctx={state,document:{getElementById:input},Number,Set,Array,Math,EXTRA_STYLE:{SUPPORT_FORCES:{label:'Reactions',color:'blue'}},
  currentPositions:()=>state.baseline,resultAnalysisLabel:()=> 'SOL101 preload',eng:String,
  loadComponentMeshes:(name,rows)=>{glyphs.push({name,rows});return[{metadata:{glyphs:rows},dispose(){}}];},
  addLayer:(name,label,color,count,meshes)=>state.layers.set(name,{meshes,visible:true}),
  setLayerVisible:(name,on)=>{state.layers.get(name).visible=on;}};
vm.createContext(ctx);vm.runInContext(source.slice(source.indexOf('function supportReactionData()'),source.indexOf('function addAeroMoments(')),ctx);
ctx.rebuildSupportForces();assert.equal(glyphs[0].rows.length,2);assert.deepEqual(Array.from(glyphs[0].rows,r=>r.node_index),[0,1]);
assert(!input('results-show-support-forces').disabled);assert(!input('results-show-support-force-values').row.hidden);
// Missing current-case markers must not erase an authenticated static result.
delete state.data.spc;ctx.rebuildSupportForces();assert(!input('results-show-support-forces').disabled);
state.activeMode=0;ctx.rebuildSupportForces();assert(input('results-show-support-forces').disabled);assert(!state.layers.has('SUPPORT_FORCES'));
assert.match(input('results-support-force-note').textContent,/static preload/);
state.activeMode=-1;ctx.rebuildSupportForces();assert(!input('show-support-forces').disabled);assert(state.layers.has('SUPPORT_FORCES'));
state.sensitivityMap={};ctx.rebuildSupportForces();assert(input('show-support-forces').disabled);state.sensitivityMap=null;
state.results.reactions=null;state.results.reactionNote='SPCFORCES was suppressed for this static subcase.';ctx.rebuildSupportForces();assert(input('show-support-forces').disabled);assert.match(input('results-support-force-note').textContent,/suppressed/);
console.log('Passed 6 preload reaction display groups.');
