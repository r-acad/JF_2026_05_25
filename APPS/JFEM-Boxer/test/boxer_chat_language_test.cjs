'use strict';
// Plain-language reading used by the Commands mode of the Boxer chat. No browser,
// server or AI is involved: node APPS/JFEM-Boxer/test/boxer_chat_language_test.cjs
const assert=require('node:assert/strict'),path=require('node:path');
const L=require(path.join(__dirname,'../web/boxer_chat_language.js'));

// Labels, aliases and units as the running application publishes them.
const inputs=[
  {id:'p-planform.area',label:'Base lifting surface area',aliases:['wing area','planform area','lifting surface area'],context:'Planform',type:'number',unit:'m²',value:16,enabled:true},
  {id:'p-planform.aspect_ratio',label:'Base aspect ratio',aliases:['aspect ratio','wing aspect ratio'],context:'Planform',type:'number',value:8,enabled:true},
  {id:'p-planform.taper_ratio',label:'Base taper ratio',aliases:['taper ratio','taper','wing taper'],context:'Planform',type:'number',value:.45,enabled:true},
  {id:'p-planform.sweep',label:'Sweep',aliases:['sweep','sweep angle','wing sweep'],context:'Planform',type:'number',unit:'deg',value:15,enabled:true},
  {id:'p-planform.sweep_ref_xc',label:'Sweep reference',context:'Planform',type:'number',unit:'x/c',value:.25,enabled:true},
  {id:'p-planform.dihedral',label:'Dihedral',aliases:['dihedral','dihedral angle'],context:'Planform',type:'number',unit:'deg',value:5,enabled:true},
  {id:'p-planform.twist_tip',label:'Tip twist',context:'Loft',type:'number',unit:'deg',value:-3,enabled:true},
  {id:'p-box.rib_pitch',label:'Root outgoing rib pitch',aliases:['rib pitch','rib spacing'],context:'Ribs',type:'number',unit:'mm',value:600,enabled:true},
  {id:'p-box.stringer_pitch',label:'Default stringer pitch',aliases:['stringer pitch','stringer spacing'],context:'Stringer layout',type:'number',unit:'mm',value:150,enabled:true},
  {id:'p-properties.t_skin_upper',label:'Minimum upper skin thickness',aliases:['upper skin thickness','minimum upper skin thickness'],context:'Skin',type:'number',unit:'mm',value:1.5,enabled:true},
  {id:'p-properties.t_skin_lower',label:'Minimum lower skin thickness',aliases:['lower skin thickness','minimum lower skin thickness'],context:'Skin',type:'number',unit:'mm',value:1.5,enabled:true},
  {id:'p-properties.t_spar_web',label:'Minimum spar web thickness',aliases:['spar web thickness'],context:'Spars',type:'number',unit:'mm',value:1.5,enabled:true},
  {id:'p-material.E',label:'Young modulus',aliases:['young modulus','youngs modulus'],context:'Materials',type:'number',unit:'GPa',value:71,enabled:true},
  {id:'p-material.name',label:'Material 1 name',context:'Materials',type:'text',value:'AL2024',enabled:true},
  {id:'p-output.title',label:'Model title',context:'Analysis',type:'text',value:'Lifting surface torsion box',enabled:true},
  {id:'p-output.solution',label:'Solution',context:'Analysis',type:'select',value:'103',enabled:true,
    options:[{value:'101',label:'SOL 101 · linear static'},{value:'103',label:'SOL 103 · normal modes'},{value:'105',label:'SOL 105 · linear buckling'},{value:'106',label:'SOL 106 · nonlinear static'}]},
  {id:'p-output.n_modes',label:'Modes or buckling roots',aliases:['number of modes','requested modes'],context:'Analysis',type:'number',value:10,enabled:true},
  {id:'p-fuel.fill_efficiency',label:'Fuel fill efficiency',context:'Fuel tank',type:'number',value:.85,enabled:true},
  {id:'wake',label:'Wake filaments',context:'Display',type:'checkbox',value:true,enabled:true},
  {id:'labels',label:'Show element labels',context:'Display',type:'checkbox',value:false,enabled:true},
  {id:'parameter:supports.definitions',label:'Support definitions',context:'Constraints',type:'structured',enabled:true,editable:false}];
const actions=[
  {id:'create_fem',label:'Create FEM',context:'Boxer',enabled:true,curated:true},
  {id:'btn-create-fem',label:'Create FEM',context:'Mesh',enabled:true},
  {id:'run_analysis',label:'Run in JFEM',aliases:['run analysis','analyze FEM','solve model','run solver'],context:'Boxer',enabled:true,curated:true},
  {id:'new_study',label:'New Study',context:'Boxer',enabled:true,curated:true},
  {id:'open_study',label:'Open Study',context:'Boxer',enabled:true,curated:true},
  {id:'save_study',label:'Save Study',context:'Boxer',enabled:true,curated:true},
  {id:'fit_view',label:'Fit 3D view',context:'Boxer',enabled:true,curated:true},
  {id:'tab-planform',label:'Planform',context:'Geometry',enabled:true},
  {id:'tab-material',label:'Materials',context:'Model',enabled:true},
  {id:'tab-stress',label:'Stress Report',context:'Results',enabled:true},
  {id:'tab-ribs-geometry',label:'Ribs',context:'Geometry',enabled:true},
  {id:'tab-ribs-model',label:'Ribs',context:'Model',enabled:true}];
const resolve=(text,list)=>L.decide(L.rank(text,list));
const id=item=>item?.entry.id;

// 1. Requests that set a value: [phrase, expected input, expected value].
const assignments=[
  ['make the aspect ratio = 15','p-planform.aspect_ratio',15],
  ['set aspect ratio to 15','p-planform.aspect_ratio',15],
  ['Set the Aspect Ratio to 15.','p-planform.aspect_ratio',15],
  ['change aspect ratio to 15','p-planform.aspect_ratio',15],
  ['put the aspect ratio at 15','p-planform.aspect_ratio',15],
  ['use an aspect ratio of 15','p-planform.aspect_ratio',15],
  ['use 15 for the aspect ratio','p-planform.aspect_ratio',15],
  ['aspect ratio = 15','p-planform.aspect_ratio',15],
  ['aspect ratio=15','p-planform.aspect_ratio',15],
  ['aspect ratio: 15','p-planform.aspect_ratio',15],
  ['aspect ratio 15','p-planform.aspect_ratio',15],
  ['aspect ratio to 15','p-planform.aspect_ratio',15],
  ['AR = 15','p-planform.aspect_ratio',15],
  ['please make the aspect ratio 15','p-planform.aspect_ratio',15],
  ['can you set the aspect ratio to 15?','p-planform.aspect_ratio',15],
  ['I want the aspect ratio to be 15','p-planform.aspect_ratio',15],
  ['I would like to change the aspect ratio to 15 please','p-planform.aspect_ratio',15],
  ['the aspect ratio should be 15','p-planform.aspect_ratio',15],
  ['let the aspect ratio be 15','p-planform.aspect_ratio',15],
  ['change the aspect ratio from 8 to 15','p-planform.aspect_ratio',15],
  ['increase the aspect ratio to 15','p-planform.aspect_ratio',15],
  ['make the asect ratio = 15','p-planform.aspect_ratio',15],
  ['set apsect ratio to 15','p-planform.aspect_ratio',15],
  ['set aspect ratios to 15','p-planform.aspect_ratio',15],
  ['set wing aspect ratio to 9,5','p-planform.aspect_ratio',9.5],
  ['set taper to 0,3','p-planform.taper_ratio',.3],
  ['set taper ratio to .3','p-planform.taper_ratio',.3],
  ['set the taper to 30%','p-planform.taper_ratio',.3],
  ['set wing area to 40','p-planform.area',40],
  ['wing area = 40 m2','p-planform.area',40],
  ['set the wing area to 40 m²','p-planform.area',40],
  ['set sweep to 25 deg','p-planform.sweep',25],
  ['set sweep angle to 25°','p-planform.sweep',25],
  ['make the sweep 25 degrees','p-planform.sweep',25],
  ['set dihedral to 0.1 rad','p-planform.dihedral',5.72957795131],
  ['set rib spacing to 0.5 m','p-box.rib_pitch',500],
  ['set the ribs pitch to 500 mm','p-box.rib_pitch',500],
  ['set rib pitch to 20 in','p-box.rib_pitch',508],
  ['set stringer spacing to 12 cm','p-box.stringer_pitch',120],
  ['set upper skin thickness to 2 mm','p-properties.t_skin_upper',2],
  ['set upper skin thickness to 0.003 m','p-properties.t_skin_upper',3],
  ['put 2,5 mm as upper skin thickness','p-properties.t_skin_upper',2.5],
  ['set min upper skin thickness to 2 millimetres','p-properties.t_skin_upper',2],
  ['set top skin gauge to 2','p-properties.t_skin_upper',2],
  ['set lower skin thickness to 2.5mm','p-properties.t_skin_lower',2.5],
  ['set the spar web thickness to 3','p-properties.t_spar_web',3],
  ['set youngs modulus to 70 GPa','p-material.E',70],
  ['set young modulus to 70000 MPa','p-material.E',70],
  ['set number of modes to 12','p-output.n_modes',12],
  ['set modes to 12','p-output.n_modes',12],
  ['set solution to 105','p-output.solution','105'],
  ['change the solution to linear buckling','p-output.solution','105'],
  ['use SOL 101','p-output.solution','101'],
  ['set model title to Wing box A and B','p-output.title','Wing box A and B'],
  ['set model title to "Trial 2,500"','p-output.title','Trial 2,500'],
  ['set material 1 name to AL7075','p-material.name','AL7075'],
  ['set wake filaments to off','wake',false],
  ['set tip twist to -2.5','p-planform.twist_tip',-2.5],
  ['set fuel fill efficiency to 1e-1','p-fuel.fill_efficiency',.1]];
for(const [phrase,input,value] of assignments){
  const parsed=L.parse(phrase);
  assert.equal(parsed.intent,'assign',phrase+' → '+parsed.intent);
  const found=resolve(parsed.target,inputs);
  assert.equal(id(found.match),input,phrase+' → target “'+parsed.target+'” resolved to '+id(found.match)+' / '+found.candidates.map(id));
  const actual=L.parseValue(parsed.value,found.match.entry);
  if(typeof value==='number')assert(Math.abs(actual-value)<1e-9*Math.max(1,Math.abs(value)),phrase+' → '+actual);
  else assert.equal(actual,value,phrase);
}
console.log('1. '+assignments.length+' ordinary ways of setting a value resolve to the intended input and value, including “make the aspect ratio = 15”.');

// 2. Ambiguous names offer choices; nothing is guessed.
const ambiguous=[['set skin thickness to 2',['p-properties.t_skin_upper','p-properties.t_skin_lower']],
  ['set thickness to 2',['p-properties.t_skin_upper','p-properties.t_skin_lower','p-properties.t_spar_web']],
  ['set pitch to 200',['p-box.rib_pitch','p-box.stringer_pitch']],
  ['set ratio to 2',['p-planform.aspect_ratio','p-planform.taper_ratio']]];
for(const [phrase,expected] of ambiguous){
  const parsed=L.parse(phrase),found=resolve(parsed.target,inputs);
  assert.equal(found.match,null,phrase+' must not be guessed: '+id(found.match));
  for(const input of expected)assert(found.candidates.some(item=>id(item)===input),phrase+' offers '+input+' in '+found.candidates.map(id));
}
const ribs=resolve('Ribs',actions);
assert.equal(ribs.match,null);assert.deepEqual(ribs.candidates.map(id),['tab-ribs-geometry','tab-ribs-model']);
// Two controls with the same name: the one Boxer gave spoken aliases to is the principal input.
const twins=[{id:'case-solution',label:'Solution',context:'Load cases',type:'select',enabled:true},{id:'p-output.solution',label:'Solution',aliases:['solution','analysis type'],context:'Analysis',type:'select',enabled:true}];
assert.equal(id(resolve('solution',twins).match),'p-output.solution');
assert.equal(resolve('solution',twins.map(entry=>({...entry,aliases:undefined}))).match,null);
console.log('2. Names that fit several inputs or two views are offered as choices instead of being guessed.');

// 3. Values that cannot be read say why.
const rejected=[['set aspect ratio to 15 mm','p-planform.aspect_ratio',/shows no unit in Boxer/],
  ['set sweep to 25 mm','p-planform.sweep',/given in “mm”, but Sweep is in deg/],
  ['set aspect ratio to big','p-planform.aspect_ratio',/needs a number/],
  ['set rib pitch to 1,200','p-box.rib_pitch',/can mean 1\.200 or 1200/],
  ['set solution to 999','p-output.solution',/has no choice like “999”\. It accepts: “SOL 101/],
  ['set solution to static','p-output.solution',/matches several choices.*SOL 101.*SOL 106/],
  ['set wake filaments to 3 mm','wake',/on\/off switch/]];
for(const [phrase,input,pattern] of rejected){
  const parsed=L.parse(phrase),found=resolve(parsed.target,inputs);
  assert.equal(id(found.match),input,phrase);
  assert.throws(()=>L.parseValue(parsed.value,found.match.entry),pattern,phrase);
}
assert.equal(L.parseValue('1.200,5',inputs[7]),1200.5);assert.equal(L.parseValue('1,200.5',inputs[7]),1200.5);
assert.equal(L.parseValue('1,200,000',inputs[7]),1200000);assert.equal(L.parseValue('2,50',inputs[7]),2.5);assert.equal(L.parseValue('15.',inputs[1]),15);
console.log('3. Unreadable values, mismatched units, an ambiguous thousands separator and unknown list choices are explained.');

// 4. Other intents.
const intents=[['Show Study status','status'],['status','status'],['what is the current study status?','status'],['help','help'],['what can I do','help'],
  ['Find skin thickness inputs','search','skin thickness','inputs'],['list inputs for skin','search','skin','inputs'],['which settings are there for ribs','search','ribs','inputs'],
  ['show all actions','search','','actions'],['find the sweep','search','sweep','any'],['where is the rib pitch','search','rib pitch','any'],
  ['change the sweep','search','sweep','inputs'],
  ['what is the aspect ratio?','read','aspect ratio'],["what's the sweep",'read','sweep'],['tell me the wing area','read','wing area'],['get the rib pitch','read','rib pitch'],
  ['hide wake filaments','toggle','wake filaments',false],['show wake filaments','toggle','wake filaments',true],['turn wake filaments off','toggle','wake filaments',false],
  ['turn on the wake filaments','toggle','wake filaments',true],['disable element labels','toggle','element labels',false],
  ['increase the sweep by 5 deg','adjust','sweep'],['reduce upper skin thickness by 10%','adjust','upper skin thickness'],['double the rib pitch','adjust','rib pitch'],['add 2 to the number of modes','adjust','number of modes'],
  ['Create FEM','action','Create FEM'],['open Stress Report','action','open Stress Report'],['go to the materials','action','go to the materials'],['delete the wing','action','delete the wing']];
for(const [phrase,intent,target,extra] of intents){
  const parsed=L.parse(phrase);
  assert.equal(parsed.intent,intent,phrase+' → '+parsed.intent);
  if(target!==undefined)assert.equal(parsed.target,target,phrase);
  if(intent==='search'&&extra)assert.equal(parsed.kind,extra,phrase);
  if(intent==='toggle')assert.equal(parsed.on,extra,phrase);
}
assert.equal(L.parse('change the sweep').needsValue,true);
assert.deepEqual([L.parse('increase the sweep by 5 deg').sign,L.parse('reduce upper skin thickness by 10%').amount,L.parse('double the rib pitch').factor],[1,'10%',2]);
console.log('4. Status, help, search, read, on/off, relative changes and menu actions are told apart.');

// 5. Menu actions by ordinary names, and requests Boxer cannot perform.
const actionCases=[['Create FEM','create_fem'],['create the mesh','create_fem'],['generate fem','create_fem'],['build the FE model','create_fem'],
  ['run analysis','run_analysis'],['run the analysis','run_analysis'],['solve the model','run_analysis'],['analyse fem','run_analysis'],['Run in JFEM','run_analysis'],
  ['open Stress Report','tab-stress'],['show the stress report','tab-stress'],['go to stress reports','tab-stress'],['stres report','tab-stress'],
  ['open materials','tab-material'],['go to the material tab','tab-material'],['planform','tab-planform'],
  ['new study','new_study'],['save study','save_study'],['save the study','save_study'],['fit view','fit_view'],['fit the 3d view','fit_view']];
for(const [phrase,action] of actionCases){
  // The panel tries the whole phrase first, then the phrase without its leading verb.
  const parsed=L.parse(phrase);
  let found=resolve(parsed.target,actions);
  if(!found.match&&parsed.query)found=resolve(parsed.query,actions);
  assert.equal(id(found.match),action,phrase+' → '+id(found.match)+' / '+found.candidates.map(id));
}
for(const phrase of ['delete the wing','email the report to my boss','what is the weather','undo','make me a coffee','asdfgh','set flux capacitor to 88']){
  const parsed=L.parse(phrase),name=parsed.query||parsed.target;
  const hit=[resolve(parsed.target,actions),resolve(name,actions),resolve(parsed.target,inputs),resolve(name,inputs)];
  assert(hit.every(found=>!found.match),phrase+' must not run anything: '+hit.map(found=>id(found.match)));
  assert(L.describe(parsed).length>10,phrase);
}
assert.equal(L.describe(L.parse('make the aspect ratio = 15')),'set “aspect ratio” to “15”');
assert.equal(L.describe(L.parse('delete the wing')),'run the menu action “delete the wing”');
assert.equal(L.describe(L.parse('hide wake filaments')),'turn “wake filaments” off');
console.log('5. '+actionCases.length+' ways of naming a menu action resolve; requests Boxer cannot perform match nothing and are restated.');

// 6. Several requests in one sentence.
const several=L.parseAll('set wing area to 40 and aspect ratio to 9; open Stress Report');
assert.deepEqual(several.map(item=>[item.intent,item.target,item.value]),[['assign','wing area','40'],['assign','aspect ratio','9'],['action','open Stress Report',undefined]]);
assert.equal(L.parseAll('set model title to "Wing and tail"').length,1);
assert.equal(L.parseAll('make the aspect ratio = 15').length,1);
assert.deepEqual(L.parseAll('Create FEM then run analysis').map(item=>item.target),['Create FEM','run analysis']);
assert.deepEqual(L.words('Minimum upper-skin thicknesses (mm)'),['minimum','upper','skin','thickness','mm']);
assert(L.similar('asect','aspect')>=.7&&L.similar('ratio','radio')>=.7&&L.similar('rib','rim')===0&&L.similar('case2','case3')===0);
console.log('6. Sentences with several requests are split; quoted text and single requests are left whole.');
