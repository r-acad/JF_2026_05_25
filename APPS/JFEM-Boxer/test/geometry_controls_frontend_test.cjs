const assert=require('node:assert/strict'),S=require('../web/spar_view.js'),R=require('../web/rib_layout.js');
const p={'planform.area':20,'planform.aspect_ratio':5,'planform.taper_ratio':.7,'planform.sweep':2,'planform.sweep_ref_xc':.25,'planform.dihedral':0,'planform.twist_tip':0,'planform.twist_axis_xc':.25,'planform.root_ref_x':0,'planform.root_ref_y':0,'planform.root_ref_z':0,'box.front_spar_xc':.2,'box.rear_spar_xc':.65,'box.end_eta':1,'box.stringer_angle':7};
const near=(a,b)=>assert(Math.abs(a-b)<1e-9,`${a} != ${b}`);
const legacy=S.derive(p);assert(legacy.valid,legacy.error);assert.deepEqual(legacy.stringerSegments,S.derive({...p,'box.stringer_angle_reference':'rear_spar'}).stringerSegments);
const globalY=S.derive({...p,'box.stringer_angle_reference':'global_y'});assert(globalY.valid,globalY.error);near(globalY.stringerSegments[0].absoluteAngle,7);
const front=S.derive({...p,'box.stringer_angle_reference':'front_spar','box.front_spar_points':[{eta:.6,dxc:.015}],'box.rear_spar_points':[{eta:.4,dxc:0,stringer_angle:4},{eta:.8,dxc:0,stringer_angle:-3}]});assert(front.valid,front.error);
assert.deepEqual(front.stringerSegments.map(s=>s.endEta),[.4,.6,.8,1]);
for(const s of front.stringerSegments){const a=S.sample(front,0,s.startEta),b=S.sample(front,0,s.endEta),datum=Math.atan2(b.position[0]-a.position[0],b.position[1]-a.position[1])*180/Math.PI;near(s.absoluteAngle,datum+(s.endEta<=.4?4:-3));}
const master=eta=>({eta,mode:'flight_direction',angle:90,pitch:.5});
near(R.nextMasterEta([],1),.5);near(R.nextMasterEta([master(.8),master(.2),master(.3)],1),.9);
let rows=[master(.9998)],last=.9998;for(let i=0;i<24;i++){const next=R.nextMasterEta(rows,1);if(next===null)break;assert(next>last&&next<1);rows.push(master(next));last=next;}
assert.equal(R.nextMasterEta([master(1-1.1e-10)],1),null);
assert.throws(()=>R.nextMasterEta([master(.5),master(.5)],1));
console.log('Stringer direction previews and appended master-rib positions passed');
