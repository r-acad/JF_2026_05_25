/* Fuel inertia glyphs. Axes are radii of gyration about the fuel RBE3 node,
 * not the dimensions of a solid containing the physical fuel volume. */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingMassProperties=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 const COLOR="#70d9ed",CG_COLOR="#f6b758";
 const dot=(a,b)=>a.reduce((s,v,i)=>s+v*b[i],0),norm=a=>Math.hypot(...a),cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]],unit=a=>{const n=norm(a);return a.map(x=>x/n);};
 const vector=(a,label)=>{if(!Array.isArray(a)||a.length!==3||!a.every(Number.isFinite))throw Error(label+" must contain three finite components.");return a.slice();};
 function tensor(value){
  if(!Array.isArray(value)||value.length!==3)throw Error("Inertia must be a 3 by 3 tensor.");
  const a=value.map(r=>vector(r,"Inertia row")),scale=Math.max(...a.flat().map(Math.abs),Number.MIN_VALUE);
  for(let i=0;i<3;i++)for(let j=i+1;j<3;j++){if(Math.abs(a[i][j]-a[j][i])>1e-10*scale)throw Error("Inertia tensor must be symmetric.");a[i][j]=a[j][i]=(a[i][j]+a[j][i])/2;}
  return a;
 }
 function referenceTensor(bay){
  const mass=Number(bay.mass_kg);if(!Number.isFinite(mass)||mass<0)throw Error("Fuel mass must be finite and nonnegative.");
  const ref=vector(bay.reference_m,"Fuel node"),cg=vector(bay.center_of_gravity_m,"Fuel CG"),r=cg.map((x,i)=>x-ref[i]),a=tensor(bay.inertia_kg_m2),r2=dot(r,r);
  principalAxes(a); // A positive offset term must not hide an invalid CG tensor.
  for(let i=0;i<3;i++)for(let j=0;j<3;j++)a[i][j]+=mass*((i===j?r2:0)-r[i]*r[j]);
  if(!a.flat().every(Number.isFinite))throw Error("Fuel reference inertia overflowed.");
  return a;
 }
 function canonicalSign(v){const i=v.reduce((best,x,index)=>Math.abs(x)>Math.abs(v[best])?index:best,0);return v[i]<0?v.map(x=>-x):v;}
 function principalAxes(value){
  const original=tensor(value),scale=Math.max(...original.flat().map(Math.abs));
  if(scale===0)return{moments:[0,0,0],axes:[[1,0,0],[0,1,0],[0,0,1]],degenerate:true};
  const a=original.map(row=>row.map(x=>x/scale)),v=[[1,0,0],[0,1,0],[0,0,1]];
  for(let iteration=0;iteration<40;iteration++){
   let p=0,q=1;for(const[i,j]of[[0,2],[1,2]])if(Math.abs(a[i][j])>Math.abs(a[p][q])){p=i;q=j;}
   if(Math.abs(a[p][q])<1e-14)break;
   const tau=(a[q][q]-a[p][p])/(2*a[p][q]),t=(tau>=0?1:-1)/(Math.abs(tau)+Math.hypot(1,tau)),c=1/Math.hypot(1,t),s=t*c,ap=a[p][p],aq=a[q][q],off=a[p][q];
   a[p][p]=ap-t*off;a[q][q]=aq+t*off;a[p][q]=a[q][p]=0;
   for(let k=0;k<3;k++){if(k!==p&&k!==q){const x=a[k][p],y=a[k][q];a[k][p]=a[p][k]=c*x-s*y;a[k][q]=a[q][k]=s*x+c*y;}const x=v[k][p],y=v[k][q];v[k][p]=c*x-s*y;v[k][q]=s*x+c*y;}
  }
  const order=[0,1,2].sort((i,j)=>a[i][i]-a[j][j]||i-j),moments=order.map(i=>a[i][i]*scale),axes=order.map(i=>unit(v.map(row=>row[i])));
  if(moments[0]<-1e-10*scale)throw Error("Inertia tensor is not positive semidefinite.");
  for(let i=0;i<3;i++)moments[i]=Math.max(0,moments[i]);
  // Equal eigenspaces have no preferred axes. Project BASIC x/y/z into each
  // such space to avoid arbitrary flips for spherical/axisymmetric inertia.
  let degenerate=false;
  for(let first=0;first<3;){let end=first+1;while(end<3&&Math.abs(moments[end]-moments[first])<=1e-9*scale)end++;
   if(end-first>1){degenerate=true;const basis=axes.slice(first,end),chosen=[];
    for(const global of[[1,0,0],[0,1,0],[0,0,1]]){let projected=[0,0,0];for(const e of basis){const weight=dot(global,e);projected=projected.map((x,i)=>x+weight*e[i]);}for(const e of chosen){const weight=dot(projected,e);projected=projected.map((x,i)=>x-weight*e[i]);}if(norm(projected)>1e-8)chosen.push(unit(projected));if(chosen.length===basis.length)break;}
    for(let i=first;i<end;i++)axes[i]=chosen[i-first];
   }first=end;
  }
  axes[0]=canonicalSign(axes[0]);axes[1]=canonicalSign(axes[1]);axes[2]=unit(cross(axes[0],axes[1]));
  return{moments,axes,degenerate};
 }
 function format(value){return Math.abs(value)>=100?value.toFixed(2):Number(value.toPrecision(4)).toString();}
 function ellipsoidData(bay,{scale=1}={}){
  if(!Number.isFinite(scale)||scale<=0)throw Error("Mass glyph scale must be positive and finite.");
  const mass=Number(bay.mass_kg),reference=vector(bay.reference_m,"Fuel node"),cg=vector(bay.center_of_gravity_m,"Fuel CG"),inertia=referenceTensor(bay),principal=principalAxes(inertia);
  const radii=mass>0?principal.moments.map(x=>Math.sqrt(x/mass)): [0,0,0];
  if(!radii.every(Number.isFinite)||!radii.every(x=>Number.isFinite(x*scale)))throw Error("Mass glyph radius overflowed.");
  return{bay:Number(bay.index??bay.start_rib),mass,reference,cg,inertia,principalMoments:principal.moments,axes:principal.axes,radii,scaledRadii:radii.map(x=>x*scale),degenerate:principal.degenerate,
   label:"Bay "+(bay.index??bay.start_rib)+" · "+format(mass)+" kg\nI₁ / I₂ / I₃: "+principal.moments.map(format).join(" / ")+" kg·m²\nAbout fuel node · radii √(I/m) × "+format(scale)};
 }
 const toView=p=>[p[1],p[2],p[0]];
 function create({BABYLON:B=globalThis.BABYLON,scene,parent=null,data=null}={}){
  const meshes=[],entries=new Map(),errors=[];let disposed=false,enabled=false,currentFuel=data?.fuel?.mass_state||{bays:[]},options={scale:1,showCG:true,markerRadius:.015};
  const point=p=>B.Vector3.FromArray(toView(p));
  function register(mesh){mesh.parent=parent;mesh.isPickable=false;mesh.metadata={wingViewHelper:true,fuelMassGlyph:true};mesh.setEnabled(false);meshes.push(mesh);return mesh;}
  function entry(id){if(entries.has(id))return entries.get(id);
   const ellipse=register(B.MeshBuilder.CreateSphere("fuel-mass-ellipsoid-"+id,{diameter:2,segments:24},scene));
   const ellipseMaterial=new B.StandardMaterial("fuel-mass-ellipsoid-material-"+id,scene);
   ellipseMaterial.diffuseColor=B.Color3.FromHexString(COLOR);ellipseMaterial.emissiveColor=B.Color3.FromHexString("#153c48");ellipseMaterial.specularColor=new B.Color3(.18,.24,.27);
   ellipseMaterial.alpha=.24;ellipseMaterial.transparencyMode=B.Material.MATERIAL_ALPHABLEND;ellipseMaterial.backFaceCulling=false;ellipseMaterial.separateCullingPass=true;ellipseMaterial.disableDepthWrite=true;ellipseMaterial.needDepthPrePass=false;ellipse.material=ellipseMaterial;
   const lines=[],colors=[];for(let axis=0;axis<3;axis++){const a=[0,0,0],b=[0,0,0];a[axis]=-1.12;b[axis]=1.12;lines.push([B.Vector3.FromArray(a),B.Vector3.FromArray(b)]);colors.push([0,1].map(()=>B.Color4.FromHexString(["#ff8585ff","#82e2a3ff","#90b9ffff"][axis])));}
   const axes=register(B.MeshBuilder.CreateLineSystem("fuel-mass-principal-axes-"+id,{lines,colors},scene));
   const loops=[],loopColors=[];for(let normal=0;normal<3;normal++){const loop=[];for(let i=0;i<=96;i++){const p=[0,0,0],angle=2*Math.PI*i/96;p[(normal+1)%3]=Math.cos(angle);p[(normal+2)%3]=Math.sin(angle);loop.push(B.Vector3.FromArray(p));}loops.push(loop);loopColors.push(loop.map(()=>B.Color4.FromHexString(["#ff8585ff","#82e2a3ff","#90b9ffff"][normal])));}
   const rings=register(B.MeshBuilder.CreateLineSystem("fuel-mass-principal-ellipses-"+id,{lines:loops,colors:loopColors},scene));rings.renderingGroupId=2;rings.material.disableDepthWrite=true;
   const ref=register(B.MeshBuilder.CreateSphere("fuel-mass-reference-"+id,{diameter:2,segments:8},scene)),cg=register(B.MeshBuilder.CreateSphere("fuel-mass-cg-"+id,{diameter:2,segments:8},scene));
   const material=new B.StandardMaterial("fuel-mass-reference-material-"+id,scene);material.disableLighting=true;material.emissiveColor=B.Color3.FromHexString(COLOR);ref.material=material;
   const cgMaterial=new B.StandardMaterial("fuel-mass-cg-material-"+id,scene);cgMaterial.disableLighting=true;cgMaterial.emissiveColor=B.Color3.FromHexString(CG_COLOR);cg.material=cgMaterial;
   const link=register(B.MeshBuilder.CreateLines("fuel-mass-offset-"+id,{points:[B.Vector3.Zero(),B.Vector3.Zero()],updatable:true},scene));link.color=B.Color3.FromHexString(CG_COLOR);
   const result={ellipse,axes,rings,ref,cg,link,material,cgMaterial,ellipseMaterial};entries.set(id,result);return result;
  }
  function update(settings={}){
   if(disposed)return{meshes,errors,bays:[]};if(settings.fuel)currentFuel=settings.fuel;if("enabled"in settings)enabled=!!settings.enabled;
   for(const key of["scale","showCG","markerRadius"])if(key in settings)options[key]=settings[key];
   if(!Number.isFinite(options.markerRadius)||options.markerRadius<=0)throw Error("Mass marker radius must be positive and finite.");
   for(const mesh of meshes)mesh.setEnabled(false);errors.length=0;const bays=[];
   for(const bay of currentFuel?.bays||[]){let glyph;try{glyph=ellipsoidData(bay,options);}catch(error){errors.push({bay:bay.index??bay.start_rib,message:error.message});continue;}bays.push(glyph);const e=entry(glyph.bay),active=enabled&&glyph.mass>0;
    const origin=point(glyph.reference),axes=glyph.axes.map(axis=>point(axis));e.ellipse.position.copyFrom(origin);e.ellipse.scaling.copyFromFloats(...glyph.scaledRadii);e.ellipse.rotationQuaternion=B.Quaternion.RotationQuaternionFromAxis(...axes);e.ellipse.setEnabled(active);e.axes.position.copyFrom(origin);e.axes.scaling.copyFrom(e.ellipse.scaling);e.axes.rotationQuaternion=e.ellipse.rotationQuaternion.clone();e.axes.setEnabled(active);
    e.rings.position.copyFrom(origin);e.rings.scaling.copyFrom(e.ellipse.scaling);e.rings.rotationQuaternion=e.ellipse.rotationQuaternion.clone();e.rings.setEnabled(active);
    e.ref.position.copyFrom(origin);e.ref.scaling.setAll(options.markerRadius);e.ref.setEnabled(active);
    e.cg.position.copyFrom(point(glyph.cg));e.cg.scaling.setAll(options.markerRadius*1.25);e.cg.setEnabled(active&&options.showCG);
    e.link.updateVerticesData(B.VertexBuffer.PositionKind,new Float32Array([...toView(glyph.reference),...toView(glyph.cg)]),true);e.link.setEnabled(active&&options.showCG&&norm(glyph.cg.map((x,i)=>x-glyph.reference[i]))>1e-12);
    for(const mesh of[e.ellipse,e.axes,e.rings,e.ref,e.cg,e.link])mesh.metadata={wingViewHelper:true,fuelMassGlyph:true,fuel_bay:glyph.bay,reference_node:bay.reference_node,reference_grid:bay.reference_grid,mass_kg:glyph.mass,principal_inertia_kg_m2:glyph.principalMoments,principal_axes_xyz:glyph.axes,radii_of_gyration_m:glyph.radii,reference_m:glyph.reference,center_of_gravity_m:glyph.cg,inertia_origin:"fuel_reference_node",...(mesh===e.ellipse||mesh===e.ref||mesh===e.cg?{svgPrimitive:"sphere"}:{}),...(mesh===e.rings?{principal_planes:[[1,2],[2,0],[0,1]]}:{})};
   }return{meshes,errors:errors.slice(),bays};
  }
  function setEnabled(value){return update({enabled:!!value});}
  function dispose(){if(disposed)return;disposed=true;for(const e of entries.values()){e.ellipse.dispose(false,false);e.axes.dispose(false,true);e.rings.dispose(false,true);e.link.dispose(false,true);for(const mesh of[e.ref,e.cg])mesh.dispose(false,false);e.material.dispose();e.cgMaterial.dispose();e.ellipseMaterial.dispose();}meshes.length=0;entries.clear();errors.length=0;}
  update();return{meshes,errors,update,setEnabled,dispose,get count(){return entries.size;}};
 }
 const detailsStates=new WeakMap();
 function renderDetails(host,snapshot={}){
  if(!host)return;const bays=snapshot.bays||[],signature=JSON.stringify(bays.map(b=>[b.bay,b.mass,b.principalMoments,b.radii]));if(detailsStates.get(host)===signature)return;detailsStates.set(host,signature);
  const doc=host.ownerDocument,open=host.querySelector("details")?.open||false,create=(tag,text)=>{const e=doc.createElement(tag);if(text!==undefined)e.textContent=text;return e;};host.replaceChildren();if(!bays.length)return;
  const details=create("details"),summary=create("summary","Fuel mass and inertia by bay");details.className="mass-glyph-details";details.open=open;details.append(summary,create("p","Principal inertias are about each fuel reference node, in kg m². Radii are √(I/m) in metres before the display scale."));
  const table=create("table"),head=create("thead"),heading=create("tr");for(const text of["Bay","Mass (kg)","I₁ / I₂ / I₃","r₁ / r₂ / r₃"]){const th=create("th",text);th.scope="col";heading.append(th);}head.append(heading);table.append(head);const body=create("tbody");for(const bay of bays){const row=create("tr");row.dataset.fuelBay=String(bay.bay);const id=create("th",String(bay.bay));id.scope="row";row.append(id,create("td",format(bay.mass)));for(const values of[bay.principalMoments,bay.radii]){const cell=create("td");for(const value of values)cell.append(create("span",format(value)));row.append(cell);}body.append(row);}table.append(body);details.append(table);host.append(details);
 }
 return{COLOR,CG_COLOR,referenceTensor,principalAxes,ellipsoidData,toView,create,renderDetails};
});
