'use strict';
const assert=require('node:assert/strict'),E=require('../web/rf_sizing_estimate.js'),S=require('../web/stress_report_data.js'),C=require('../web/euler_column_data.js');
let passed=0;const test=(name,fn)=>{fn();passed++;console.log('PASS '+name);},near=(a,b,t=1e-10)=>assert(Math.abs(a-b)<=t*Math.max(Math.abs(b),1e-250),`${a} != ${b}`);
const mat={id:1,type:'MAT1',E_Pa:70e9,nu:.3},shell=t=>({type:'PSHELL',thickness_m:t,material_id:1,material:mat}),signature=t=>JSON.stringify([['properties.t_skin_upper',t],['loads.speed',100]]);
const elem=(p,pid=10,nodes=[0,1,2,3],kind='quad')=>({nodes:Int32Array.from(nodes),group:{pid,kind,name:'Upper',properties:p}});
const force=(fx=600e6*.002,mx=0)=>({fx,fy:0,fxy:0,mx,my:0,mxy:0});
const shellRecord=(fx=600e6*.002,mx=0)=>({forces:force(fx,mx),stress:{z1:{normal_x:fx/.002+6*mx/.002**2,normal_y:0,shear_xy:0,von_mises:Math.abs(fx/.002+6*mx/.002**2)},z2:{normal_x:fx/.002-6*mx/.002**2,normal_y:0,shear_xy:0,von_mises:Math.abs(fx/.002-6*mx/.002**2)}}});
const base=()=>{const signatureValue=signature(.002),r={analysis:'SOL101_STATIC',matches:true,available:true,status:'complete',static:{},signature:signatureValue,meshIdentity:'old',elementResults:{1:shellRecord()}};return{generated:true,sourceUnits:false,studyEpoch:1,signature:signatureValue,definitionSignature:signatureValue,meshIdentity:'old',layoutToken:'physical',topologySignature:'same',elements:new Map([[1,elem(shell(.002))]]),cases:new Map([[1,r]]),allowables:[{material_id:1,mode:'stress',stress:300e6}],expectedCases:[{id:1,solution:101,enabled:true}],panels:[],componentGroups:[]};};
const current=(b,t=.006)=>({...b,signature:signature(t),definitionSignature:signature(t),meshIdentity:'new',elements:new Map([[1,elem(shell(t))]]),cases:new Map(),modelDirty:false});
const estimate=(b,c)=>{const p=E.project(b,c);assert(p.estimated,p.reason);assert(E.isEstimateContext(p.context));return p;};
const rec=(c,id=1)=>c.cases.get(1).elementResults.get(id)??c.cases.get(1).elementResults.get(String(id));

test('Fixed membrane force gives RF .5 -> 1.5 after tripling the thickness; source records remain immutable',()=>{
 const b=base(),before=JSON.stringify([...b.cases]),p=estimate(b,current(b));near(S.build(b).rows[0].reserveFactor,.5);near(S.build(p.context).rows[0].reserveFactor,1.5);assert.equal(rec(p.context).forces,b.cases.get(1).elementResults[1].forces);assert.equal(JSON.stringify([...b.cases]),before);assert.deepEqual(p.changedPropertyIds,[10]);assert.match(p.message,/load redistribution/);
});
test('Pure bending surface stress scales with inverse thickness squared, not inverse area',()=>{
 const b=base();b.cases.get(1).elementResults[1]=shellRecord(0,100);const p=estimate(b,current(b,.004));near(rec(p.context).stress.z1.normal_x,6*100/.004**2);near(S.build(p.context).rows[0].reserveFactor,4*S.build(b).rows[0].reserveFactor);
});
test('Biaxial membrane, bending and shear keep their signs before von Mises recovery',()=>{
 const a=shell(.002),p=shell(.004),r={forces:{fx:40,fy:-20,fxy:30,mx:2,my:-1,mxy:3}},x=E.shellRecovery(a,p,r),s=[40/.004+12/.004**2,-20/.004-6/.004**2,30/.004+18/.004**2];near(x.stress.z1.von_mises,Math.sqrt(s[0]**2-s[0]*s[1]+s[1]**2+3*s[2]**2));assert(x.stress.z2.shear_xy<0);
});
test('Successive edits always project from the original solved force field',()=>{
 const b=base();const c=current(b,.003),a=estimate(b,c),d=estimate(b,current(b,.006));near(S.build(a.context).rows[0].reserveFactor,.75);near(S.build(d.context).rows[0].reserveFactor,1.5);near(b.cases.get(1).elementResults[1].stress.z1.von_mises,600e6);
});
test('The envelope can switch governing case after resizing because membrane and bending scale differently',()=>{
 const b=base();b.cases.get(1).elementResults[1]=shellRecord(60e3,0);const second={...b.cases.get(1),elementResults:{1:shellRecord(0,40)}};b.cases.set(2,second);b.expectedCases.push({id:2,solution:101,enabled:true});assert.match(S.build(b).rows[0].envelopeCaseKey,/^2:/);const p=estimate(b,current(b,.01));assert.match(S.build(p.context).rows[0].envelopeCaseKey,/^1:/);
});
test('Projection cache retains reference identity across table and field refreshes',()=>{
 const b=base(),c=current(b),first=estimate(b,c),second=estimate(b,{...c,allowables:c.allowables.map(x=>({...x})),expectedCases:c.expectedCases.map(x=>({...x}))});assert.equal(first,second);assert.equal(first.context,second.context);const third=estimate(b,{...c,allowables:[{...c.allowables[0],stress:600e6}]});assert.notEqual(first,third);near(S.build(third.context).rows[0].reserveFactor,3);
});
test('Certified spreads are allowed; changing identity, recovery, geometry or source markers invalidates them',()=>{
 const b=base(),p=estimate(b,current(b)).context;assert(E.isEstimateContext({...p,method:'mean',caseId:'all'}));for(const change of [{studyEpoch:2},{signature:'bad'},{meshIdentity:'bad'},{elements:new Map(p.elements)},{cases:new Map(p.cases)},{generated:false},{sourceUnits:true},{pendingDrafts:true},{running:true},{modelDirty:true},{estimateCertificate:{}}])assert(!E.isEstimateContext({...p,...change}));assert(!E.isEstimateContext({estimated:true}));
});
test('Geometry, loads, constraints, analysis changes and imported studies cannot reuse solved force ownership',()=>{
 const b=base(),c=current(b);for(const key of ['planform.sweep','loads.speed','constraints.root','output.solution']){const rows=JSON.parse(c.signature).filter(row=>row[0]!==key);rows.push([key,999]);const changed={...c,signature:JSON.stringify(rows),definitionSignature:JSON.stringify(rows)};assert(!E.project(b,changed).estimated,key);}
 for(const patch of [{studyEpoch:2},{layoutToken:'other'},{generated:false},{sourceUnits:true},{signature:'not json',definitionSignature:'not json'}])assert(!E.project(b,{...c,...patch}).estimated);
});
test('Pending mesh regeneration/drafts or analysis withholds the estimate instead of labeling stale sections as updated',()=>{
 const b=base(),c=current(b);for(const patch of [{signature:b.signature},{modelDirty:true},{pendingDrafts:true},{running:true}])assert(!E.project(b,{...c,...patch}).estimated);assert(E.definitionCompatible(b,{...c,modelDirty:true}));
});
test('Element membership, property identity and connectivity must match the solved mesh exactly',()=>{
 const b=base(),c=current(b);for(const elements of [new Map(),new Map([[1,elem(shell(.006),11)]]),new Map([[1,elem(shell(.006),10,[0,1,3,2])]]),new Map([[2,elem(shell(.006))]])])assert(!E.project(b,{...c,elements}).estimated);
});
test('Moving shell geometry or GRID identity is refused even if node-index connectivity is unchanged',()=>{
 const b=base();b.nodeIds=Int32Array.from([1,2,3,4]);b.nodePositions=Float64Array.from([0,0,0,1,0,0,1,1,0,0,1,0]);const c=current(b),p=estimate(b,c);assert(E.isEstimateContext(p.context));
 const moved=Float64Array.from(b.nodePositions);moved[8]=.001;assert.match(E.project(b,{...c,nodePositions:moved}).reason,/moves FE nodes/);assert(!E.project(b,{...c,nodePositions:undefined}).estimated);assert(!E.project(b,{...c,nodeIds:Int32Array.from([1,2,3,99])}).estimated);assert(!E.isEstimateContext({...p.context,nodePositions:Float64Array.from(b.nodePositions)}));
 const withMass={...b,nodeIds:Int32Array.from([1,2,3,4,5]),nodePositions:Float64Array.from([...b.nodePositions,.5,.5,0])},massMoved=Float64Array.from(withMass.nodePositions);massMoved[12]=.6;assert(E.project(withMass,{...current(withMass),nodePositions:massMoved}).estimated,'A mass-only reference-node move does not change the structural recovery geometry.');
 assert(E.project(withMass,{...current(withMass),nodeIds:Int32Array.from([1,2,3,4,99]),nodePositions:massMoved}).estimated,'Nonstructural GRID IDs do not own a structural stress sample.');
});
test('Missing force recovery, unknown units and unsupported section checks remain unavailable',()=>{
 const native=E.shellRecovery(shell(.002),shell(.004),{...shellRecord(),stress_units:'Pa; fiber_dist in m',force_units:{fx:'N/m',fy:'N/m',fxy:'N/m',mx:'N m/m',my:'N m/m',mxy:'N m/m'}});assert(!native.reason,native.reason);
 for(const patch of [{forces:{fx:1,fy:0,fxy:0}},{force_units:{fx:'kN/m'}},{stress_units:'MPa'}]){const b=base();Object.assign(b.cases.get(1).elementResults[1],patch);const p=estimate(b,current(b)),r=S.build(p.context).rows[0];assert.equal(r.reserveFactor,null);assert(p.diagnostics.length);assert.match(r.reserveFactorReason,/Sizing estimate unavailable/);}
});
test('Failed, partial or wrong-provenance baseline cases are never upgraded to valid solved cases',()=>{
 for(const patch of [{matches:false},{signature:'other'},{meshIdentity:'other'},{status:'failed'},{analysis:'SOL106_NONLINEAR',convergence:{converged:false,full_load:false,partial:true}}]){const b=base();Object.assign(b.cases.get(1),patch);const p=estimate(b,current(b));assert.equal(S.build(p.context).rows[0].reserveFactor,null);}
});

function tProperty(d){const[b,h,tf,tw]=d,hw=h-tf,A=b*tf+hw*tw,yc=(hw*tw*hw/2+b*tf*(hw+tf/2))/A;return{type:'PBARL',material:mat,section:{shape:'T',dimensions_m:d,area_m2:A,I1_m4:tw*hw**3/12+hw*tw*(yc-hw/2)**2+b*tf**3/12+b*tf*(hw+tf/2-yc)**2,I2_m4:hw*tw**3/12+tf*b**3/12,J_m4:(hw*tw**3+b*tf**3)/3}};}
const beamRecord=f=>({forces:{axial:-10000,shear_1:0,shear_2:0,torque:0,moment_a1:0,moment_a2:0,moment_b1:0,moment_b2:0,...f}});
test('Native T-section stress envelope uses updated area, inertia and all end moments',()=>{
 const a=tProperty([.05,.06,.003,.002]),b=tProperty([.1,.12,.006,.004]),r=beamRecord(),x=E.beamRecovery(a,r),y=E.beamRecovery(b,r);near(x.stress.von_mises,10000/a.section.area_m2);near(y.stress.von_mises,x.stress.von_mises/4);near(y.stress.axial,x.stress.axial/4);
 const bend=beamRecord({axial:0,moment_a1:1,moment_b1:3,moment_a2:-4,moment_b2:2}),old=E.beamRecovery(a,bend),next=E.beamRecovery(b,bend);near(next.stress.von_mises,old.stress.von_mises/8);assert(next.stress.von_mises_recovery.normal_bound>0);
});
test('Beam torsion and transverse shear are retained, never replaced with an axial-stress proxy',()=>{
 const p=tProperty([.05,.06,.003,.002]);for(const forces of [{axial:0,torque:100},{axial:0,shear_1:100},{axial:0,shear_2:100}]){const r=E.beamRecovery(p,beamRecord(forces));assert(r.stress.von_mises>0);assert.equal(r.stress.axial,0);}
 const incomplete=beamRecord();delete incomplete.forces.torque;assert.equal(E.beamRecovery(p,incomplete).stress.von_mises_recovery.status,'unavailable');const thick=E.beamRecovery(tProperty([.05,.06,.009,.002]),beamRecord());assert.equal(thick.stress.von_mises_recovery.status,'unavailable');assert(Number.isFinite(thick.stress.axial));
 assert.match(E.beamRecovery({...p,section:{...p.section,I12_m4:1e-8}},beamRecord()).reason,/zero product/);
});
test('Stringer blade RF changes both its local plate capacity and the fixed-force axial stress',()=>{
 const b=base(),p=tProperty([.05,.06,.003,.002]),q=tProperty([.05,.06,.003,.004]),f=beamRecord();b.elements=new Map([[1,elem(p,10,[0,1],'bar')]]);b.cases.get(1).elementResults[1]={...f,...E.beamRecovery(p,f)};
 const blade=property=>({key:'upper:bay1:stringer1',skin:'upper',rib_bay:1,stringer:1,pid:10,bars:[{eid:1,pid:10,material_type:'MAT1',material_id:1,young_pa:mat.E_Pa,poisson:mat.nu,web_height_m:.057,web_thickness_m:property.section.dimensions_m[3]}]});b.stringerBlades=[blade(p)];const c={...current(b),elements:new Map([[1,elem(q,10,[0,1],'bar')]]),stringerBlades:[blade(q)]},out=estimate(b,c);const before=S.build({...b,failureMode:'stringer_blade'}).rows[0].reserveFactor,after=S.build({...out.context,failureMode:'stringer_blade'}).rows[0].reserveFactor;near(after/before,4*q.section.area_m2/p.section.area_m2);
});

const I=[[1,0,0],[0,1,0],[0,0,1]],bending=t=>{const d=70e9*t**3/(12*(1-.3**2));return[[d,.3*d,0],[.3*d,d,0],[0,0,.35*d]];};
const plate=t=>({key:'upper:bay1:strip1',skin:'upper',rib_bay:1,strip_index:1,property_ids:[10],length_m:1,width_m:1,fixity_coefficient:1,elements:[{eid:1,pid:10,area_m2:1,thickness_m:t,material_ids:[1],stress_transform:I,bending_matrix_Nm:bending(t)}]});
test('Skin-panel RF uses regenerated bending stiffness and unchanged signed membrane force',()=>{
 const b=base();b.cases.get(1).elementResults[1]=shellRecord(-1000);b.skinBucklingPanels=[plate(.002)];const c=current(b,.004);c.skinBucklingPanels=[plate(.004)];const p=estimate(b,c),old=S.build({...b,failureMode:'skin_buckling'}).rows[0],next=S.build({...p.context,failureMode:'skin_buckling'}).rows[0];near(next.reserveFactor/old.reserveFactor,8);near(next.skinBuckling.averageStressX,old.skinBuckling.averageStressX/2);
});
test('Regenerated shared-skin contributions update every associated Euler column; internal demand is not rescaled',()=>{
 const rectangle=(w,t,y=0)=>({area_m2:w*t,centroid_y_m:y,centroid_z_m:0,iyy_m4:w*t**3/12,izz_m4:t*w**3/12,iyz_m4:0,young_pa:mat.E_Pa,material_id:1}),column=(key,t,y)=>({key,pid:10,length_m:1,stations:[{id:1,parts:[rectangle(.1,t,y),rectangle(.002,.06,0)],force_terms:[{eid:1,pid:10,kind:'shell_membrane',width_m:.1,coefficients:[1,0,0]}]}]});
 const b=base();b.cases.get(1).elementResults[1]=shellRecord(-1000);b.eulerColumns=[column('left',.002,-.05),column('right',.002,.05)];const c=current(b,.004);c.eulerColumns=[column('left',.004,-.05),column('right',.004,.05)];const p=estimate(b,c),a=S.build({...b,failureMode:'euler_column'}),d=S.build({...p.context,failureMode:'euler_column'});for(let i=0;i<2;i++){assert(d.rows[i].reserveFactor>a.rows[i].reserveFactor);near(d.rows[i].euler.compressionDemand,100);near(d.rows[i].euler.weakestEI,C.section(c.eulerColumns[i].stations[0].parts).weakestEI);}
});
test('An unsupported physical buckling scope remains unassessed after a property edit',()=>{
 const b=base();b.skinBucklingPanels=[{...plate(.002),reason:'Unsupported boundary topology.'}];const c=current(b,.004);c.skinBucklingPanels=[{...plate(.004),reason:'Unsupported boundary topology.'}];const p=estimate(b,c),row=S.build({...p.context,failureMode:'skin_buckling'}).rows[0];assert.equal(row.reserveFactor,null);assert.match(row.reserveFactorReason,/Unsupported boundary/);
});

const ortho={id:8,type:'MAT8',E1_Pa:130e9,E2_Pa:9e9,nu12:.28,G12_Pa:4.5e9};
function laminateProperty(scale=1){return{type:'PCOMP',thickness_m:.002*scale,z0_m:-.001*scale,plies:[{material:ortho,material_id:8,thickness_m:.001*scale,angle_deg:0},{material:ortho,material_id:8,thickness_m:.001*scale,angle_deg:90}]};}
function plyRecord(p,eps,kappa){const law=E.laminate(p),faces=law.layers.map(layer=>{const meta={ply:layer.ply,material_id:layer.material_id,angle_deg:layer.angle_deg,z_bottom:layer.z_bottom,z_top:layer.z_top},c=Math.cos(layer.angle_deg*Math.PI/180),s=Math.sin(layer.angle_deg*Math.PI/180);for(const side of ['bottom','top']){const z=layer['z_'+side],a=eps.map((v,i)=>v+z*kappa[i]);meta[side]={e1:c*c*a[0]+s*s*a[1]+c*s*a[2],e2:s*s*a[0]+c*c*a[1]-c*s*a[2],g12:-2*c*s*a[0]+2*c*s*a[1]+(c*c-s*s)*a[2]};}return meta;});return{strain:{ply_faces:faces,ply_faces_complete:true,ply_faces_coordinate_system:'ply material 1/2 axes'}};}
test('Coupled laminate resizing conserves all six section resultants and re-recovers both faces of every ply',()=>{
 const p=laminateProperty(),q=laminateProperty(2),eps=[.001,-.0002,.0003],k=[.1,-.05,.02],old=plyRecord(p,eps,k),r=E.shellRecovery(p,q,old);assert(!r.reason,r.reason);assert(r.strain.ply_faces_complete);assert.equal(r.strain.ply_faces.length,2);
 const rows=r.strain.ply_faces,first=rows[0],last=rows[1],a=[first.bottom.e1,first.bottom.e2,first.bottom.g12],b=[last.top.e2,last.top.e1,-last.top.g12],kk=a.map((v,i)=>(b[i]-v)/q.thickness_m),ee=a.map((v,i)=>v-first.z_bottom*kk[i]),times=(A,x)=>A.map(row=>row.reduce((s,v,i)=>s+v*x[i],0)),before=times(E.laminate(p).ABD,[...eps,...k]),after=times(E.laminate(q).ABD,[...ee,...kk]);for(let i=0;i<6;i++)near(after[i],before[i],1e-9);
 assert.notEqual(rows[0].top.e1,old.strain.ply_faces[0].top.e1);
});
test('Laminate principal-strain RF uses updated recovered strains and retains heterogeneous-material exclusions',()=>{
 const b=base(),old=laminateProperty(),next=laminateProperty(2);b.elements=new Map([[1,elem(old)]]);b.cases.get(1).elementResults[1]=plyRecord(old,[.004,0,0],[0,0,0]);b.allowables=[{material_id:8,mode:'strain',strain_tension:.005,strain_compression:.004}];const c={...current(b),elements:new Map([[1,elem(next)]])},p=estimate(b,c);const r=S.build({...p.context,failureMode:'principal_strain'}).rows[0];assert(r.reserveFactor>0);assert(r.complete);
 const incomplete=plyRecord(old,[.004,0,0],[0,0,0]);incomplete.strain.ply_faces[0].top.g12=null;assert(E.shellRecovery(old,next,incomplete).reason);
 const bad=plyRecord(old,[.004,0,0],[0,0,0]);bad.strain.ply_faces[0].top.e1+=.1;assert.match(E.shellRecovery(old,next,bad).reason,/compatible linear/);
});
test('Unsupported monolithic-to-laminate conversion remains explicitly unassessed',()=>assert.match(E.shellRecovery(shell(.002),laminateProperty(),shellRecord()).reason,/complete original ply-frame/));
console.log(JSON.stringify({passed,failed:0}));
