/* Manual sizing estimates hold the last solved element force field fixed.
 * Regenerated sections supply all capacities and physical membership. This is
 * local re-recovery, never a substituted equilibrium or nonlinear solution. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingRFSizingEstimate=api;})(globalThis,function(){
 'use strict';
 const finite=n=>typeof n==='number'&&Number.isFinite(n),positive=n=>finite(n)&&n>0;
 const entries=v=>v instanceof Map?[...v]:Array.isArray(v)?v.map((x,i)=>[x?.id??i,x]):Object.entries(v||{});
 const at=(v,k)=>v instanceof Map?v.get(k)??v.get(String(k)):v?.[k];
 const clone=v=>v instanceof Map?new Map([...v].map(([k,x])=>[k,clone(x)])):Array.isArray(v)?v.map(clone):v&&typeof v==='object'?Object.fromEntries(Object.entries(v).map(([k,x])=>[k,clone(x)])):v;
 const json=v=>JSON.stringify(v,(_,x)=>typeof x==='number'&&!finite(x)?String(x):x);
 const fail=reason=>({reason}),near=(a,b,tol=1e-9)=>finite(a)&&finite(b)&&Math.abs(a-b)<=tol*Math.max(Math.abs(a),Math.abs(b),Number.MIN_VALUE);
 const sectionCertificates=new WeakMap(),certificates=new WeakMap(),cache=new WeakMap(),laminateCache=new WeakMap();
 const NOTE='Model and results are not in sync. Estimated reserve factors use the edited sections with the last solved element forces and moments held fixed. They ignore load redistribution, changes in mass loads, aeroelastic loads and nonlinear equilibrium. Rerun the FE analysis to confirm the design.';
 const ALLOWED=/^(properties\.|material\.|materials\.)|^stringers\.(euler_fixity_coefficient|skin_fixity_coefficient)$/;
 const geometryKeys=['elements','nodeIds','nodePositions','panels','componentGroups','eulerColumns','stringerBlades','skinBucklingPanels','componentBuckling'];
 const certifiedKeys=[...geometryKeys,'cases','signature','meshIdentity','studyEpoch','topologySignature','definitionSignature','allowables','componentFixities','eulerFixityCoefficient','skinFixityCoefficient','generated','sourceUnits','expectedCases'];
 function signatureRows(signature){try{const rows=JSON.parse(signature);return Array.isArray(rows)&&rows.every(r=>Array.isArray(r)&&r.length===2&&typeof r[0]==='string')?new Map(rows):null;}catch{return null;}}
 function compatibility(base,current){
  if(!base||!current||base.generated!==true||current.generated!==true||base.sourceUnits||current.sourceUnits)return{compatible:false,reason:'Sizing estimates require a generated SI model.'};
  if(base.studyEpoch!==current.studyEpoch)return{compatible:false,reason:'The current Study differs from the solved Study.'};
  const a=signatureRows(base.signature),b=signatureRows(current.definitionSignature??current.signature);
  if(!a||!b)return{compatible:false,reason:'The solved and edited model definitions cannot be verified.'};
  const changedKeys=[...new Set([...a.keys(),...b.keys()])].filter(key=>json(a.get(key))!==json(b.get(key)));
  const unsupported=changedKeys.filter(key=>!ALLOWED.test(key));
  if(unsupported.length)return{compatible:false,reason:'Sizing estimates are unavailable after changing geometry, loads, constraints or analysis settings: '+unsupported.join(', ')+'.',changedKeys};
  if(base.layoutToken&&current.layoutToken&&base.layoutToken!==current.layoutToken)return{compatible:false,reason:'The rib/stringer layout differs from the solved model.',changedKeys};
  return{compatible:true,changedKeys};
 }
 const definitionCompatible=(base,current)=>compatibility(base,current).compatible;
 function topologyReason(base,current){
  const structural=([,e])=>['quad','tria','shell','bar','solid'].includes(e.group?.kind)&&e.group?.name!=='aero';
  const a=new Map(entries(base.elements).filter(structural).map(([id,e])=>[Number(id),e])),b=new Map(entries(current.elements).filter(structural).map(([id,e])=>[Number(id),e])),nodePairs=new Map();
  if(!a.size||a.size!==b.size)return 'The edited mesh has different element membership; rerun the FE analysis.';
  if((base.nodeIds||current.nodeIds)&&(!base.nodeIds||!current.nodeIds))return 'The solved and edited GRID identity cannot be verified.';
  for(const[id,e]of a){const n=b.get(id);if(!n||e.group?.kind!==n.group?.kind||Number(e.group?.pid)!==Number(n.group?.pid))return 'Element '+id+' changed its physical property or element type; rerun the FE analysis.';
   const oldNodes=e.nodes,newNodes=n.nodes;if(!oldNodes||!newNodes||oldNodes.length!==newNodes.length)return 'Element '+id+' changed connectivity; rerun the FE analysis.';
   for(let i=0;i<oldNodes.length;i++){const oldNode=oldNodes[i],newNode=newNodes[i],oldId=base.nodeIds?base.nodeIds[oldNode]:oldNode,newId=current.nodeIds?current.nodeIds[newNode]:newNode;
    if(!Number.isSafeInteger(oldId)||oldId!==newId||nodePairs.has(oldNode)&&nodePairs.get(oldNode)!==newNode)return 'Element '+id+' changed GRID connectivity; rerun the FE analysis.';nodePairs.set(oldNode,newNode);}
  }
  if(base.nodePositions||current.nodePositions){
   const x=base.nodePositions,y=current.nodePositions;if(!x||!y||!x.length||!y.length)return 'The solved and edited nodal geometry cannot be verified.';
   // Moving a displayed mass/load reference is an expected consequence of
   // resizing. Only the physical shell/bar/solid geometry supporting the
   // retained stress field must remain fixed; mass-load changes are ignored.
   let scale=1;for(const [oldNode,newNode]of nodePairs)for(let axis=0;axis<3;axis++){const i=3*oldNode+axis,j=3*newNode+axis;if(!finite(x[i])||!finite(y[j]))return 'Nonfinite nodal coordinates prevent a sizing estimate.';scale=Math.max(scale,Math.abs(x[i]),Math.abs(y[j]));}
   for(const [oldNode,newNode]of nodePairs)for(let axis=0;axis<3;axis++){const i=3*oldNode+axis,j=3*newNode+axis;if(Math.abs(x[i]-y[j])>64*Number.EPSILON*scale)return 'This edit moves FE nodes (for example shell-stringer height or flange width). Fixed shell resultants cannot preserve the original integrated loads on a changed surface; rerun the FE analysis.';}
  }
  return '';
 }
 const transpose=a=>a[0].map((_,j)=>a.map(row=>row[j]));
 const multiply=(a,b)=>a.map(row=>b[0].map((_,j)=>row.reduce((s,x,k)=>s+x*b[k][j],0)));
 const mv=(a,b)=>a.map(row=>row.reduce((s,x,i)=>s+x*b[i],0));
 const zeros=n=>Array.from({length:n},()=>Array(n).fill(0));
 function solve(a,b){
  const n=b.length,scale=a.map((r,i)=>Math.sqrt(Math.abs(r[i])));if(!scale.every(positive))return null;
  const m=a.map((r,i)=>[...r.map((x,j)=>x/scale[i]/scale[j]),b[i]/scale[i]]);
  for(let k=0;k<n;k++){let p=k;for(let i=k+1;i<n;i++)if(Math.abs(m[i][k])>Math.abs(m[p][k]))p=i;
   if(!finite(m[p][k])||Math.abs(m[p][k])<1e-13)return null;[m[k],m[p]]=[m[p],m[k]];
   for(let i=k+1;i<n;i++){const f=m[i][k]/m[k][k];for(let j=k;j<=n;j++)m[i][j]-=f*m[k][j];}}
  const x=Array(n).fill(0);for(let i=n-1;i>=0;i--)x[i]=(m[i][n]-m[i].slice(i+1,n).reduce((s,v,j)=>s+v*x[i+1+j],0))/m[i][i];
  const answer=x.map((v,i)=>v/scale[i]);return answer.every(finite)?answer:null;
 }
 function materialQ(mat){
  if(!mat)return null;let e1,e2,nu,g;
  if(mat.type==='MAT1'){e1=e2=mat.E_Pa??mat.E??mat.e;nu=mat.nu??mat.NU;g=e1/(2*(1+nu));}
  else if(mat.type==='MAT8'){e1=mat.E1_Pa??mat.E1??mat.e1;e2=mat.E2_Pa??mat.E2??mat.e2;nu=mat.nu12??mat.NU12;g=mat.G12_Pa??mat.G12??mat.g12;}else return null;
  const d=1-nu*nu*e2/e1;if(![e1,e2,g,d].every(positive)||!finite(nu))return null;
  return[[e1/d,nu*e2/d,0],[nu*e2/d,e2/d,0],[0,0,g]];
 }
 function rotation(degrees){const a=degrees*Math.PI/180,c=Math.cos(a),s=Math.sin(a);return[[c*c,s*s,c*s],[s*s,c*c,-c*s],[-2*c*s,2*c*s,c*c-s*s]];}
 function laminate(property){
  if(property&&laminateCache.has(property))return laminateCache.get(property);
  const t=property?.thickness_m;if(!positive(t))return fail('A positive regenerated shell thickness is required.');
  const plies=property.type==='PSHELL'?[{material:property.material,material_id:property.material_id??property.material?.id,thickness_m:t,angle_deg:0}]:property.type==='PCOMP'?property.plies:null;
  if(!Array.isArray(plies)||!plies.length||!near(plies.reduce((s,p)=>s+p.thickness_m,0),t))return fail('The laminate stack does not cover its regenerated thickness.');
  let z=property.type==='PCOMP'?(property.z0_m??-t/2):(property.shell_offset_m??0)-t/2;const ABD=zeros(6),layers=[];
  for(let i=0;i<plies.length;i++){const p=plies[i],Q=materialQ(p.material),angle=p.angle_deg??0,h=p.thickness_m;if(!Q||!positive(h)||!finite(angle)||!finite(z))return fail('The laminate has an unsupported or invalid ply law.');
   const T=rotation(angle),q=multiply(transpose(T),multiply(Q,T)),top=z+h;
   for(let a=0;a<3;a++)for(let b=0;b<3;b++){ABD[a][b]+=q[a][b]*h;ABD[a][b+3]+=q[a][b]*(top*top-z*z)/2;ABD[a+3][b]+=q[a][b]*(top*top-z*z)/2;ABD[a+3][b+3]+=q[a][b]*(top**3-z**3)/3;}
   layers.push({ply:i+1,material_id:p.material_id??p.material?.id,material_type:p.material?.type,angle_deg:angle,z_bottom:z,z_top:top,Q,T});z=top;
  }
  const result={ABD,layers,thickness:t};laminateCache.set(property,result);return result;
 }
 function vm(s){return Math.sqrt(Math.max(0,s[0]*s[0]-s[0]*s[1]+s[1]*s[1]+3*s[2]*s[2]));}
 function faceStress(s,z){const mean=(s[0]+s[1])/2,r=Math.hypot((s[0]-s[1])/2,s[2]);return{normal_x:s[0],normal_y:s[1],shear_xy:s[2],von_mises:vm(s),major:mean+r,minor:mean-r,fiber_dist:z};}
 function unitsReason(record){
  const stress=record?.stress_units;if(stress&&!/^Pa(?:\b|$)/i.test(stress))return 'Sizing recovery requires stresses stored in Pa.';
  const u=record?.force_units;if(u&&typeof u==='object'){for(const key of ['fx','fy','fxy'])if(u[key]&&u[key]!=='N/m')return 'Sizing recovery requires shell membrane resultants in N/m.';for(const key of ['mx','my','mxy'])if(u[key]&&!['N','N m/m'].includes(u[key]))return 'Sizing recovery requires shell moment resultants in N m/m.';}
  return '';
 }
 function shellRecovery(oldProperty,property,record){
  const units=unitsReason(record);if(units)return fail(units);
  const current=laminate(property);if(current.reason)return current;
  // For a homogeneous isotropic shell use the same signed force/moment
  // convention as native recovery (M=-D*kappa). No uniform RF scaling: both
  // membrane 1/t and bending 1/t^2 contributions retain their signs.
  if(oldProperty.type==='PSHELL'&&property.type==='PSHELL'){
   if(oldProperty.material?.type!=='MAT1'||property.material?.type!=='MAT1')return fail('Homogeneous shell stress projection requires isotropic MAT1.');
   const ids=new Set([property.material_id,property.material?.id,...(property.material_ids||[]),...Object.values(property.material_roles||{})].filter(x=>x!=null));if(ids.size>1)return fail('Mixed membrane/bending material roles require a new analysis.');
   if((oldProperty.shell_offset_m??0)!==0||(property.shell_offset_m??0)!==0)return fail('An eccentric PSHELL needs laminate recovery for sizing.');
   const f=record?.forces,N=['fx','fy','fxy'].map(k=>f?.[k]),M=['mx','my','mxy'].map(k=>f?.[k]);if(![...N,...M].every(finite))return fail('Complete shell membrane and bending resultants are required for sizing.');
   const t=property.thickness_m,a=N.map((x,i)=>x/t+6*M[i]/(t*t)),b=N.map((x,i)=>x/t-6*M[i]/(t*t));
   if(![...a,...b].every(finite))return fail('Projected shell stress exceeds the numeric range.');
   return{stress:{z1:faceStress(a,-t/2),z2:faceStress(b,t/2)},strain:{},method:'Fixed membrane and bending resultants, homogeneous isotropic shell'};
  }
  // A complete old ply-face strain field gives the section resultants in its
  // actual laminate axes. This avoids guessing a material-frame rotation
  // from a property number or transforming resultants in unknown axes.
  if(oldProperty.type!=='PCOMP')return fail('Changing a monolithic shell to a laminate needs complete original ply-frame recovery; rerun the FE analysis.');
  const previous=laminate(oldProperty),r=record?.strain;if(previous.reason)return previous;
  if(r?.ply_faces_complete!==true||r.ply_faces_coordinate_system!=='ply material 1/2 axes'||!Array.isArray(r.ply_faces)||r.ply_faces.length!==previous.layers.length)return fail('Complete solved ply-face strains in material axes are required for laminate sizing.');
  const samples=[];
  for(const layer of previous.layers){const p=r.ply_faces.find(p=>p.ply===layer.ply&&Number(p.material_id)===Number(layer.material_id));if(!p||!near(p.z_bottom,layer.z_bottom)||!near(p.z_top,layer.z_top)||!near(p.angle_deg??0,layer.angle_deg))return fail('Solved ply geometry differs from the baseline laminate.');
   for(const side of ['bottom','top']){const values=['e1','e2','g12'].map(k=>p[side]?.[k]);if(!values.every(finite))return fail('A solved ply-face strain sample is missing.');samples.push({z:layer['z_'+side],value:mv(rotation(-layer.angle_deg),values)});}}
  const first=samples[0],last=samples.at(-1),dz=last.z-first.z;if(!positive(dz))return fail('The solved laminate strain thickness is invalid.');
  const curvature=first.value.map((v,i)=>(last.value[i]-v)/dz),membrane=first.value.map((v,i)=>v-first.z*curvature[i]);
  const magnitude=Math.max(...samples.flatMap(s=>s.value.map(Math.abs)),1e-15);
  if(samples.some(s=>s.value.some((v,i)=>Math.abs(v-membrane[i]-s.z*curvature[i])>1e-7*magnitude)))return fail('Solved ply strains do not define one compatible linear section field.');
  const loads=mv(previous.ABD,[...membrane,...curvature]),state=solve(current.ABD,loads);if(!state)return fail('The edited laminate section law is singular or unresolved.');
  const strains=[],stresses=[];
  for(const layer of current.layers){const meta={ply:layer.ply,material_id:layer.material_id,material_type:layer.material_type,angle_deg:layer.angle_deg,z_bottom:layer.z_bottom,z_top:layer.z_top},e={...meta},s={...meta};
   for(const side of ['bottom','top']){const z=layer['z_'+side],eps=mv(layer.T,state.slice(0,3).map((v,i)=>v+z*state[i+3])),sig=mv(layer.Q,eps);if(![...eps,...sig].every(finite))return fail('Projected laminate response exceeds the numeric range.');e[side]={e1:eps[0],e2:eps[1],g12:eps[2]};s[side]={s1:sig[0],s2:sig[1],t12:sig[2],von_mises:vm(sig)};}strains.push(e);stresses.push(s);
  }
  const meta={ply_faces_complete:true,ply_faces_coordinate_system:'ply material 1/2 axes',ply_faces_note:'Manual sizing estimate: fixed original section resultants, full coupled laminate ABD re-recovery.'};
  if(property.type==='PSHELL'){const t=property.thickness_m,q=current.layers[0].Q,a=mv(q,state.slice(0,3).map((v,i)=>v-t/2*state[i+3])),b=mv(q,state.slice(0,3).map((v,i)=>v+t/2*state[i+3]));return{stress:{z1:faceStress(a,-t/2),z2:faceStress(b,t/2)},strain:{},method:'Fixed coupled-laminate resultants on edited isotropic section'};}
  return{stress:{...meta,ply_faces:stresses},strain:{...meta,ply_faces:strains},method:'Fixed laminate section resultants with coupled ABD re-recovery'};
 }
 function beamRecovery(property,record){
  const s=property.section??property,d=s.dimensions_m,f=record?.forces;
  if(s.shape==='BAR')return rectangularRecovery(property,record);
  if(property.material?.type!=='MAT1'||s.shape!=='T'||!Array.isArray(d)||d.length!==4||!d.every(positive))return fail('Fixed-load beam stress recovery currently supports isotropic PBARL T sections.');
  if(/distributed|varying|taper|interior/i.test(record?.stress?.von_mises_recovery?.reason||''))return fail(record.stress.von_mises_recovery.reason);
  const[b,h,tf,tw]=d,hw=h-tf;if(!(b>tw&&hw>0))return fail('The edited T section has overlapping or nonpositive walls.');
  const A=b*tf+hw*tw,yc=(hw*tw*hw/2+b*tf*(hw+tf/2))/A,yf=hw+tf/2,
   I1=tw*hw**3/12+hw*tw*(yc-hw/2)**2+b*tf**3/12+b*tf*(yf-yc)**2,I2=hw*tw**3/12+tf*b**3/12,J=s.torsion_formulation==='saint_venant_2d'?s.J_m4:(hw*tw**3+b*tf**3)/3;
  if(!near(s.area_m2??property.area_m2,A,1e-8)||!near(s.I1_m4??property.I1_m4,I1,1e-8)||!near(s.I2_m4??property.I2_m4,I2,1e-8)||!near(s.J_m4??property.J_m4,J,1e-8))return fail('Regenerated T-section area/inertia does not match its dimensions.');
  const I12=s.I12_m4??property.I12_m4??0;if(!finite(I12)||Math.abs(I12)>1e-12*Math.sqrt(I1*I2))return fail('The symmetric T-section sizing model requires zero product of inertia.');
  if(!finite(f?.axial))return fail('A finite solved beam axial force is required.');
  const axial=f.axial/A,stress={axial};
  if(Math.max(tf/b,tw/hw)>.1*(1+1e-12))return{stress:{...stress,von_mises_recovery:{status:'unavailable',reason:'The thin-wall stress model requires flange thickness/width and web thickness/height no greater than 0.10.'}},strain:{},method:'Fixed beam axial force; equivalent stress unavailable for thick walls'};
  const keys=['axial','shear_1','shear_2','torque','moment_a1','moment_a2','moment_b1','moment_b2'];if(!keys.every(k=>finite(f?.[k])))return{stress:{...stress,von_mises_recovery:{status:'unavailable',reason:'Complete beam forces and both end moments are required for an equivalent-stress sizing estimate.'}},strain:{},method:'Fixed beam axial force; incomplete equivalent-stress recovery'};
  const polygon=[[h-yc,-b/2],[h-yc,b/2],[hw-yc,b/2],[hw-yc,tw/2],[-yc,tw/2],[-yc,-tw/2],[hw-yc,-tw/2],[hw-yc,-b/2]],normal=Math.max(...['a','b'].flatMap(end=>polygon.map(([y,z])=>Math.abs(axial-f['moment_'+end+'1']*y/I1-f['moment_'+end+'2']*z/I2))));
  const cy=Math.max(0,Math.min(hw,yc)),webQ=Math.max(Math.abs(yc*hw-hw*hw/2),Math.abs(yc*cy-cy*cy/2)),webShear=Math.abs(f.shear_1)*webQ/I1+Math.abs(f.shear_2)*tw*tw/(8*I2),flangeShear=Math.abs(f.shear_1)*Math.abs(yf-yc)*b/(2*I1)+Math.abs(f.shear_2)*b*b/(8*I2),torque=Math.abs(f.torque)+Math.abs(f.shear_2)*Math.abs(yf-yc),shear=Math.max(webShear+torque*tw/J,flangeShear+torque*tf/J),equivalent=Math.hypot(normal,Math.sqrt(3)*shear);
  if(![axial,normal,shear,equivalent].every(finite))return fail('Projected beam stress exceeds the numeric range.');
  return{stress:{...stress,von_mises:equivalent,von_mises_recovery:{status:'complete',method:'fixed_load_thin_walled_t_section_envelope',description:'Sizing estimate using the native conservative T-section envelope with fixed solved end forces/moments and updated dimensions; no load redistribution.',normal_bound:normal,combined_shear_bound:shear}},strain:{},method:'Fixed beam resultants, conservative thin-walled T-section envelope'};
 }
 function rectangularRecovery(property,record){
  const s=property.section??property,d=s.dimensions_m,f=record?.forces;
  if(property.material?.type!=='MAT1'||!Array.isArray(d)||d.length!==2||!d.every(positive))return fail('A dimension-defined isotropic solid rectangle is required.');
  if(/distributed|varying|taper|interior/i.test(record?.stress?.von_mises_recovery?.reason||''))return fail(record.stress.von_mises_recovery.reason);
  const[b,h]=d,A=b*h,I1=b*h**3/12,I2=h*b**3/12;
  if(!near(s.area_m2??property.area_m2,A,1e-8)||!near(s.I1_m4??property.I1_m4,I1,1e-8)||!near(s.I2_m4??property.I2_m4,I2,1e-8))return fail('Rectangular area/inertia differs from the physical dimensions.');
  const I12=s.I12_m4??property.I12_m4??0;if(!finite(I12)||Math.abs(I12)>1e-12*Math.sqrt(I1*I2))return fail('Rectangular principal section axes are required.');
  const keys=['axial','shear_1','shear_2','torque','moment_a1','moment_a2','moment_b1','moment_b2'];if(!keys.every(k=>finite(f?.[k])))return fail('Complete rectangular beam resultants are required.');
  const axial=f.axial/A,normal=Math.max(...['a','b'].flatMap(end=>[-h/2,h/2].flatMap(y=>[-b/2,b/2].map(z=>Math.abs(axial-f['moment_'+end+'1']*y/I1-f['moment_'+end+'2']*z/I2))))),transverse=1.5*(Math.abs(f.shear_1)+Math.abs(f.shear_2))/A,torsion=5*Math.abs(f.torque)/(Math.max(b,h)*Math.min(b,h)**2),shear=transverse+torsion,equivalent=Math.hypot(normal,Math.sqrt(3)*shear);
  if(![axial,normal,shear,equivalent].every(finite))return fail('Rectangular stress exceeds the finite range.');
  return{stress:{axial,von_mises:equivalent,von_mises_recovery:{status:'complete',method:'fixed_load_solid_rectangular_section_envelope',normal_bound:normal,transverse_shear_bound:transverse,torsional_shear_bound:torsion,combined_shear_bound:shear,torsion_stress_coefficient:.20}},strain:{},method:'Fixed beam resultants, conservative solid-rectangle equivalent-stress envelope'};
 }
 function recovery(oldProperty,property,record){if(!record)return fail('No solved element recovery is available.');if(!oldProperty||!property)return fail('The old or regenerated property definition is unavailable.');
  if(['PSHELL','PCOMP'].includes(property.type)&&['PSHELL','PCOMP'].includes(oldProperty.type))return shellRecovery(oldProperty,property,record);
  if(['PBARL','PBAR','PBEAM','PBEAML'].includes(property.type))return beamRecovery(property,record);
  return fail('This property has no fixed-load local stress recovery; rerun the FE analysis.');
 }
 // Certificates bind section-only responses to the original FEM and exact edit.
 const sectionKeys=[...geometryKeys,'signature','definitionSignature','meshIdentity','studyEpoch','sectionBaselineSignature'];
 function certifySections(context){const token={};sectionCertificates.set(token,Object.fromEntries(sectionKeys.map(key=>[key,context[key]])));return token;}
 function hasSections(base,current){const stored=sectionCertificates.get(current.sectionUpdateCertificate);return!!stored&&current.sectionBaselineSignature===base.signature&&sectionKeys.every(key=>Object.is(stored[key],current[key]));}
 function isEstimateContext(context){const certificate=context?.estimateCertificate,stored=certificate&&certificates.get(certificate);return!!stored&&context.estimated===true&&!context.modelDirty&&!context.pendingDrafts&&!context.running&&certifiedKeys.every(key=>Object.is(stored[key],context[key]));}
 function project(base,current,options={}){
  const check=compatibility(base,current),reject=reason=>({context:base,estimated:false,reason,message:reason,changedPropertyIds:[],diagnostics:[]});
  if(!check.compatible)return reject(check.reason);
  if(current.pendingDrafts||current.running)return reject(current.running?'An FE analysis is running; sizing estimates resume after completion.':'Apply or cancel the current edit before updating sizing estimates.');
  if((current.modelDirty||current.signature!==(current.definitionSignature??current.signature))&&!hasSections(base,current))return reject('Updating sections for the sizing estimate.');
  const small=json({allowables:current.allowables,componentFixities:current.componentFixities,euler:current.eulerFixityCoefficient,skin:current.skinFixityCoefficient,expected:current.expectedCases,labels:entries(current.caseLabels)}),refs=[current.signature,current.meshIdentity,current.studyEpoch,...geometryKeys.map(key=>current[key]),small],old=cache.get(base);
  if(old&&old.refs.length===refs.length&&old.refs.every((x,i)=>Object.is(x,refs[i])))return old.value;
  const why=topologyReason(base,current);if(why)return reject(why);
  const sourceElements=new Map(entries(base.elements).map(([id,e])=>[Number(id),e])),properties=new Map(),changed=new Set(),compared=new WeakMap();
  for(const[id,element]of entries(current.elements)){const pid=Number(element.group?.pid),oldProperty=sourceElements.get(Number(id))?.group?.properties,property=element.group?.properties;if(!oldProperty||!property)continue;
   let pairs=compared.get(oldProperty);if(!pairs){pairs=new WeakMap();compared.set(oldProperty,pairs);}let differs=pairs.get(property);if(differs===undefined){differs=json(oldProperty)!==json(property);pairs.set(property,differs);}if(differs){changed.add(pid);properties.set(Number(id),{oldProperty,property,pid});}}
  const diagnostics=[],seenReasons=new Set(),seenCases=new Map();
  function recordCase(item){if(!item||typeof item!=='object')return item;if(seenCases.has(item))return seenCases.get(item);
   const out={...item,signature:current.signature,meshIdentity:current.meshIdentity};seenCases.set(item,out);
   // Never upgrade failed, mismatched or partial baseline eligibility. Only
   // the provenance coordinates change for cases verified at the baseline.
   out.matches=item.matches===true&&item.signature===base.signature&&item.meshIdentity===base.meshIdentity;out.estimated=true;
   const source=item.elementResults??item.element_results;
   if(source){const records=new Map(entries(source));for(const[eid,{oldProperty,property,pid}]of properties){const raw=at(source,eid);if(!raw)continue;
     const projected=recovery(oldProperty,property,raw),reason=projected.reason,stress=reason?{von_mises_recovery:{status:'unavailable',reason:'Sizing estimate unavailable: '+reason}}:projected.stress,strain=reason?{}:projected.strain;
     const key=records.has(eid)?eid:records.has(String(eid))?String(eid):eid;records.set(key,{...raw,stress,strain,estimated:true,sizing_method:projected.method||'',sizing_reason:reason||'',stress_units:'Pa'});
     const note=reason||stress?.von_mises_recovery?.status==='unavailable'&&stress.von_mises_recovery.reason;if(note&&!seenReasons.has(pid+':'+note)){seenReasons.add(pid+':'+note);diagnostics.push({pid,reason:note});}
    }out.elementResults=records;delete out.element_results;}
   if(item.variants)out.variants=new Map(entries(item.variants).map(([key,variant])=>[key,recordCase(variant)]));return out;
  }
  const context={...base,...current,modelDirty:false,pendingDrafts:false,running:false,estimated:true,allowables:clone(current.allowables),componentFixities:clone(current.componentFixities),cases:new Map(entries(base.cases).map(([key,item])=>[key,recordCase(item)])),estimateMessage:NOTE,estimateSource:{studyEpoch:base.studyEpoch,signature:base.signature,meshIdentity:base.meshIdentity},estimateCertificate:{}};
  certificates.set(context.estimateCertificate,Object.fromEntries(certifiedKeys.map(key=>[key,context[key]])));
  const value={context,estimated:true,changedPropertyIds:[...changed].sort((a,b)=>a-b),diagnostics,message:NOTE+(diagnostics.length?' Some edited-property stress checks remain unassessed; see assessment details.':'')};cache.set(base,{refs,value});return value;
 }
 return{project,certifySections,compatibility,definitionCompatible,isEstimateContext,NOTE,recovery,shellRecovery,beamRecovery,laminate,materialQ};
});
