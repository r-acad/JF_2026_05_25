"use strict";
const assert=require("node:assert/strict"),P=require("../web/planform_view.js"),S=require("../web/spar_view.js");
const p={"planform.area":4,"planform.aspect_ratio":4,"planform.taper_ratio":.65,"planform.sweep":8,"planform.sweep_ref_xc":.25,"planform.twist_axis_xc":.25,"planform.root_ref_x":12,"planform.root_ref_y":4,"planform.root_ref_z":3,"planform.dihedral":5,"planform.twist_tip":0,"box.end_eta":1,"box.front_spar_xc":.2,"box.rear_spar_xc":.7,"box.rib_pitch":.5,"box.stringer_angle":7,"ribs.masters":[],"leading_edge.enabled":true,"leading_edge.start_rib":1,"leading_edge.end_rib":0,"leading_edge.disabled_bays":"2","movable_surfaces.items":[{name:'Flap',kind:'flap',edge:'trailing',eta_start:.25,eta_end:.8,hinge_start:.8,hinge_end:.75,deflection:10,color:'#dd55ff'}]};
let assertions=0;const near=(a,b)=>{assert(Math.abs(a-b)<1e-10,`${a} != ${b}`);assertions++;};
for(const key of [...P.POINT_KEYS,...S.POINT_KEYS]){
 const rows=[{eta:1,dxc:.02,incoming_angle_deg:12},{eta:.4,dxc:.01,incoming_angle_deg:10},{eta:0,dxc:0}],params={...p,[key]:rows},data=(S.POINT_KEYS.includes(key)?S:P).derive(params);assert(data.valid,data.error);assertions++;
 const v=data.edgeVertices[key];near(v.at(-1).dxc,.02);for(let i=1;i<v.length;i++){near(Math.atan2(v[i].position[0]-v[i-1].position[0],v[i].position[1]-v[i-1].position[1])*180/Math.PI,v[i].incoming_angle_deg);}
 assert.deepEqual(rows,params[key]);assertions++;
 const canonical=P.constrainPointRows(P.normalizePointRows(rows,key,params),key,params);assert.deepEqual(P.constrainPointRows(canonical,key,params),canonical);assertions++;
 const changed=(S.POINT_KEYS.includes(key)?S:P).derive({...params,'planform.sweep':9,'planform.taper_ratio':.7});for(let i=1;i<changed.edgeVertices[key].length;i++){const a=changed.edgeVertices[key][i-1],b=changed.edgeVertices[key][i];near(Math.atan2(b.position[0]-a.position[0],b.position[1]-a.position[1])*180/Math.PI,b.incoming_angle_deg);}
 assert.throws(()=>P.normalizePointRows([{eta:0,dxc:0,incoming_angle_deg:0}],key,p));assertions++;
 assert.throws(()=>P.normalizePointRows([{eta:.4,dxc:0,incoming_angle_deg:90}],key,p));assertions++;
 assert.throws(()=>P.normalizePointRows([{eta:.4,dxc:0,incoming_angle_deg:'4'}],key,p));assertions++;
}
assert.deepEqual(P.normalizePointRows([],P.POINT_KEYS[0],p),[]);assertions++;
const rear=P.endpointRows([],S.POINT_KEYS[1],p);assert.deepEqual(rear,[{eta:0,dxc:0,stringer_angle:7},{eta:1,dxc:0,stringer_angle:7}]);assertions++;
const legacy=P.endpointRows([{eta:.5,dxc:.03,stringer_angle:2}],S.POINT_KEYS[1],p);near(legacy.at(-1).stringer_angle,2);
const context=S.contextGeometry(p);assert(context.ribs.length>2);assert(context.ribs.some(r=>r.noseActive));assertions+=2;assert.equal(context.movables.length,1);assertions++;
const svg=S.contextDrawing(context,{transform:{map:p=>[p[1]*10,p[0]*10]}});for(const name of ['sf-front','sf-rear','plan-context-rib','plan-context-leading','plan-context-hinge']){assert(svg.includes(name));assertions++;}
const onlyMovable=S.contextDrawing(context,{transform:{map:p=>p},includeSpars:false,includeRibs:false,includeLeadingEdge:false});assert(!onlyMovable.includes('class="plan-context-leading"'));assert(!onlyMovable.includes('class="plan-context-rib"'));assert(onlyMovable.includes('plan-context-hinge'));assertions+=3;
console.log(`Point angle controls: ${assertions} assertions passed`);
