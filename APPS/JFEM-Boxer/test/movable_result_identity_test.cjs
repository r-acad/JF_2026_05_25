'use strict';
// Legacy studies and normalized solver inputs describe the same effective
// geometry; a genuine spar, hinge, attachment or structural-span edit does not.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const S=require('../web/movable_surfaces.js'),M=require('../web/movable_structure.js');
const source=fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');
const schema=[['movable_surfaces.items','movablesurfaces'],['movable_structure.surfaces','movablestructure'],['movable_structure.attachments','movableattachments']].map(([key,kind])=>({key,kind}));
const legacy={
 'movable_surfaces.items':[{name:'Flap',kind:'flap',edge:'trailing',eta_start:.2,eta_end:.9,hinge_start:.7,hinge_end:.75,deflection:10,color:'#29b6d1'}],
 'movable_structure.surfaces':[{surface:'Flap',enabled:true}],
 'movable_structure.attachments':[{surface:'Flap',eta:.3,rib:2}]
};
const normalized={...legacy,'movable_surfaces.items':S.normalize(legacy['movable_surfaces.items'])};
const n=M.normalize(legacy['movable_structure.surfaces'],legacy['movable_structure.attachments'],normalized['movable_surfaces.items']);
normalized['movable_structure.surfaces']=n.surfaces;normalized['movable_structure.attachments']=n.attachments;
const state={schema},context={state,WingMovableStructure:M,affectsModel:()=>true,document:{getElementById:id=>({value:JSON.stringify(legacy[id.slice(2)]||[])})}};
vm.createContext(context);vm.runInContext(source.slice(source.indexOf('function formSignature('),source.indexOf('function syncLeadingEdgeOrientation(')),context);
const sig=p=>context.formSignature(p),copy=p=>JSON.parse(JSON.stringify(p));let checks=0;
assert.equal(sig(legacy),sig(normalized));checks++;
assert.equal(sig(),sig(normalized));checks++;
for(const [key,field,value]of [
 ['movable_surfaces.items','front_spar_start',.71],['movable_surfaces.items','hinge_start',.69],
 ['movable_surfaces.items','eta_end',.88],['movable_structure.surfaces','end_eta',.8],
 ['movable_surfaces.items','hinge_z_start',.5],['movable_surfaces.items','hinge_z_end',-2],
 ['movable_surfaces.items','kind','aileron'],
 ['movable_structure.attachments','hinge_stiffness',20000],['movable_structure.attachments','actuator',true],
 ['movable_structure.attachments','actuator_stiffness',2e7],['movable_structure.surfaces','max_rib_pitch_ratio',1.75]
]){const changed=copy(normalized);changed[key][0][field]=value;assert.notEqual(sig(changed),sig(normalized),field);checks++;}
const display=copy(normalized);display['movable_surfaces.items'][0].color='#abcdef';display['movable_surfaces.items'][0].deflection=20;assert.equal(sig(display),sig(normalized));checks++;
const deflected=copy(normalized);deflected['movable_structure.surfaces'][0].mesh_deflected=true;const moved=copy(deflected);moved['movable_surfaces.items'][0].deflection=20;assert.notEqual(sig(deflected),sig(moved));checks++;
const explicitMidpoint=copy(normalized);explicitMidpoint['movable_surfaces.items'][0].hinge_z_start=0;explicitMidpoint['movable_surfaces.items'][0].hinge_z_end=0;assert.equal(sig(legacy),sig(explicitMidpoint));checks++;
const ordered=copy(normalized);ordered['movable_structure.attachments'].push({...ordered['movable_structure.attachments'][0],eta:.7,rib:5});const unsorted=copy(ordered);unsorted['movable_structure.attachments'].reverse();assert.equal(sig(ordered),sig(unsorted));checks++;
for(const [key,value]of [['eta',.8],['actuator_stiffness',2e7]]){const editedAttachment=copy(unsorted);editedAttachment['movable_structure.attachments'][0][key]=value;assert.notEqual(sig(ordered),sig(editedAttachment));checks++;}
console.log(JSON.stringify({passed:true,checks}));
