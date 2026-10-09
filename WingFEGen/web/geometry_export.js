/* Geometry interchange without renderer coordinate conventions or remote code.
 * Internal export coordinates are always right-handed FE XYZ in metres.
 */
(function(root,factory){
 const api=factory(typeof module==="object"&&module.exports?require("./sections.js"):root.WingSections,
   typeof module==="object"&&module.exports?require("./support_glyphs.js"):root.WingSupportGlyphs,
   typeof module==="object"&&module.exports?require("./load_glyphs.js"):root.WingLoadGlyphs);
 if(typeof module==="object"&&module.exports)module.exports=api;else root.WingGeometryExport=api;
})(typeof globalThis!=="undefined"?globalThis:this,function(Sections,SupportGlyphs,LoadGlyphs){
 "use strict";
 const pause=()=>new Promise(resolve=>setTimeout(resolve,0));
 const sub=(a,b)=>a.map((v,i)=>v-b[i]),add=(a,b)=>a.map((v,i)=>v+b[i]),mul=(a,s)=>a.map(v=>v*s);
 const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
 const unit=a=>{const n=Math.hypot(...a);return n>1e-20?mul(a,1/n):[0,0,0];};
 const point=(xyz,i)=>Array.from(xyz.subarray(3*i,3*i+3));
 const typed=(value,Type)=>value instanceof Type?value:new Type(value.buffer.slice(value.byteOffset,value.byteOffset+value.byteLength));
 const f32=value=>typed(value,Float32Array),i32=value=>typed(value,Int32Array);
 const rgba=hex=>Array.isArray(hex)?hex:[1,3,5].map(i=>parseInt((hex||"#9aa6b2").slice(i,i+2),16)/255).concat(1);
 const colors={NODES:"#ecf4ff",SPC:"#ff4d6d",RBE3:"#b57ce0",RBE3_NODES:"#dcb3ff",FUEL_RBE3:"#43d5ac",FUEL_RBE3_NODES:"#91f5d5",RIB_STIFFENERS:"#a9e4ef",AERO_SURFACE:"#8fa0b3",FUEL_TANK:"#50dfa3",VLM:"#e9b04d",AERO_LOADS:"#5df1ca",AERO_MOMENTS:"#eeb4ff"};
 // New payloads separate forces from their routed pure couples. Treat the
 // moment list as authoritative so it can never duplicate source moments.
 function loadStations(loads){
  if(!loads)return [];
  const routed=Array.isArray(loads.moment_stations),records=[];
  if(Array.isArray(loads.force_stations))for(const station of loads.force_stations)records.push({...station,
   source:station.target_kind==='external_rbe3'?'aerodynamic':'combined inertia',routed_force:true,
   force:Array.from(station.force||[0,0,0]),moment:[0,0,0],follower_forces:station.target_kind==='external_rbe3'&&station.follower_forces===true});
  else for(const [key,source]of[["stations","aerodynamic"],["fuel_stations","fuel inertia"],["structure_stations","structural inertia"]])
   for(const station of loads[key]||[])records.push({...station,source,force:Array.from(station.force||[0,0,0]),moment:routed?[0,0,0]:Array.from(station.moment||[0,0,0]),
    follower_forces:key!=="stations"?false:typeof station.follower_forces==="boolean"?station.follower_forces:typeof loads.follower_forces==="boolean"?loads.follower_forces:undefined});
  if(routed)for(const station of loads.moment_stations)records.push({...station,source:"combined moments",routed_moment:true,follower_forces:false,force:[0,0,0],moment:Array.from(station.moment||[0,0,0]),
   source_moments_Nm:station.source_moments_Nm?Object.fromEntries(Object.entries(station.source_moments_Nm).map(([key,value])=>[key,Array.from(value)])):undefined});
  return records;
 }
 function loadsByNode(stations){
  const map=new Map();
  for(const station of stations||[]){
   const node=Number(station.node_index);let combined=map.get(node);
   if(!combined){combined={node_index:node,gid:station.gid,force:[0,0,0],moment:[0,0,0]};map.set(node,combined);}
   for(let axis=0;axis<3;axis++){combined.force[axis]+=Number(station.force?.[axis]||0);combined.moment[axis]+=Number(station.moment?.[axis]||0);}
   if(station.source_moments_Nm){combined.source_moments_Nm??={};for(const [source,vector]of Object.entries(station.source_moments_Nm)){combined.source_moments_Nm[source]??=[0,0,0];for(let axis=0;axis<3;axis++)combined.source_moments_Nm[source][axis]+=Number(vector[axis]||0);}}
   if(station.source_forces_N){combined.source_forces_N??={};for(const [source,vector]of Object.entries(station.source_forces_N)){combined.source_forces_N[source]??=[0,0,0];for(let axis=0;axis<3;axis++)combined.source_forces_N[source][axis]+=Number(vector[axis]||0);}}
   if(station.target_kind)combined.target_kind=station.target_kind;
  }
  return map;
 }
 const baseGroup=name=>name.replace(/_KINKS$/,"").replace(/_P\d+$/,"");
 function builder(parts,name,color,extras={}){
  let vertices=[],ranges=[],piece=0;
  function flush(){if(!vertices.length)return;parts.push({name:piece?name+" "+piece:name,positions:Float32Array.from(vertices),color:rgba(color),extras:{component:name,...extras,entities:ranges}});vertices=[];ranges=[];piece++;}
  return{entity(id,coords,metadata){if(vertices.length+coords.length>589824)flush();const first=vertices.length/9;for(const v of coords){if(!Number.isFinite(v))throw Error(name+" contains non-finite coordinates");vertices.push(v);}ranges.push({id,first_triangle:first,triangle_count:coords.length/9,...metadata});},finish:flush};
 }
 function triangles(xyz,nodes){const p=Array.from(nodes,n=>point(xyz,n));return p.length===3?p.flat():[...p[0],...p[1],...p[2],...p[0],...p[2],...p[3]];}
 function cylinder(a,b,r,sides=8){
  const axis=unit(sub(b,a));if(Math.hypot(...axis)===0||!(r>0))return[];
  const u=unit(cross(axis,Math.abs(axis[2])<.9?[0,0,1]:[0,1,0])),v=cross(axis,u),ring=[];
  for(let k=0;k<sides;k++)ring.push(add(mul(u,r*Math.cos(2*Math.PI*k/sides)),mul(v,r*Math.sin(2*Math.PI*k/sides))));
  const out=[];for(let k=0;k<sides;k++){const j=(k+1)%sides,ak=add(a,ring[k]),aj=add(a,ring[j]),bk=add(b,ring[k]),bj=add(b,ring[j]);out.push(...ak,...aj,...bj,...ak,...bj,...bk,...a,...aj,...ak,...b,...bk,...bj);}return out;
 }
 function marker(p,r){
  const axes=[[r,0,0],[-r,0,0],[0,r,0],[0,-r,0],[0,0,r],[0,0,-r]].map(a=>add(p,a)),out=[];
  for(const [a,b,c]of[[0,2,4],[2,1,4],[1,3,4],[3,0,4],[2,0,5],[1,2,5],[3,1,5],[0,3,5]])out.push(...axes[a],...axes[b],...axes[c]);return out;
 }
 function loadGlyphTriangles(origin,glyph,r){const out=[];for(let i=0;i<glyph.vertices.length;i+=2)out.push(...cylinder(add(origin,glyph.vertices[i]),add(origin,glyph.vertices[i+1]),r,6));return out;}
 function loadGlyphMetadata(glyph){return{axis:glyph.axis,component:glyph.component,component_value:glyph.value,component_vector:glyph.vector,arrow_scale_m_per_N:glyph.scale,arc_radius_m:glyph.radius};}

 async function collect(snapshot,options={},progress=()=>{}){
  const data=snapshot.data;if(!data?.nodes)throw Error("Create a model before exporting geometry.");
  const parts=[],visible=options.scope==="visible",shown=name=>!visible||(snapshot.visibility?.[name]??snapshot.visibility?.[baseGroup(name)])!==false;
  const cases=data.load_cases?.length?data.load_cases:[{id:1,label:"Load case 1",loads:data.loads,fuel:data.fuel?.mass_state}];
  const selectedCases=visible?cases.filter(c=>Number(c.id)===Number(snapshot.activeCase)):cases;
  const fuelMasses=selectedCases.flatMap(c=>(c.fuel?.bays||[]).map(bay=>({...bay,entity_type:"CONM2",case_id:c.id,case_label:c.label,in_deck:bay.mass_kg>0})));
  const base=f32(data.nodes.xyz),xyz=options.displayed&&snapshot.positions?snapshot.positions:base,ids=i32(data.nodes.ids);
  const diag=snapshot.diag||1,r=Number(options.lineRadius??diag*.0003),nodeR=Math.max(snapshot.nodeRadius||0,r),markerR=Math.max(snapshot.markerRadius||0,2*r);
  if(!(r>0&&Number.isFinite(r)))throw Error("Export line radius must be positive.");
  let processed=0;const total=(data.groups||[]).reduce((n,g)=>n+g.count,0)+data.nodes.count+1;
  async function tick(){if(++processed%128===0){progress(Math.min(.65,.65*processed/total),"Triangulating model entities");await pause();}}
  progress(0,"Triangulating model entities");await pause();
  for(const g of data.groups||[]){
   if(!shown(g.name))continue;
   const conn=i32(g.conn),eids=g.eids?i32(g.eids):Int32Array.from({length:g.count},(_,e)=>g.eid_first+e),stride=g.n_per_elem||(g.kind==="tria"?3:g.kind==="quad"?4:2);
   const baseName=g.base_group||baseGroup(g.name);
   const build=builder(parts,g.name,snapshot.colors?.[g.name]||snapshot.colors?.[baseName]||colors[baseName]||"#9aa6b2",{entity_type:g.kind==="bar"?"CBAR":stride===3?"CTRIA3":"CQUAD4",property_id:g.pid,base_group:baseName,properties:g.properties});
   const orientations=g.orient?f32(g.orient):g.axes?.y?f32(g.axes.y):null;
   for(let e=0;e<g.count;e++){
    const nodes=conn.subarray(stride*e,stride*(e+1));let coords;
    if(g.kind==="bar"&&g.properties?.section?.polygon_yz_m&&orientations){
     const geom=Sections.geometry(base,nodes,orientations.subarray(3*e,3*e+3),g.properties.section);
     if(options.displayed&&snapshot.positions)Sections.update(geom,xyz,snapshot.rotations,snapshot.rotationScale||0);
     coords=geom.positions;
    }else if(g.kind==="bar")coords=cylinder(point(xyz,nodes[0]),point(xyz,nodes[1]),Math.sqrt((g.properties?.area_m2||Math.PI*r*r)/Math.PI));
    else coords=triangles(xyz,nodes);
    build.entity(eids[e],coords,{grid_ids:Array.from(nodes,n=>ids[n])});await tick();
   }build.finish();
  }
  const markers=async(name,nodes,radius)=>{if(!shown(name))return;const build=builder(parts,name,colors[name],{entity_type:name==="SPC"?"SPC":"GRID",components:name==="SPC"?data.spc.components:undefined});for(const n of nodes){build.entity(ids[n],marker(point(xyz,n),radius),name==="FUEL_RBE3_NODES"?{fuel_mass_cases:fuelMasses.filter(record=>record.reference_node===n)}:undefined);await tick();}build.finish();};
  await markers("NODES",Array.from({length:data.nodes.n_structural??data.nodes.count},(_,n)=>n),nodeR);
  await markers("RBE3_NODES",data.rbe3?.refs?i32(data.rbe3.refs):[],markerR);
  await markers("FUEL_RBE3_NODES",data.fuel_rbe3?.refs?i32(data.fuel_rbe3.refs):[],markerR);
  if(shown("SPC")&&data.spc?.count){
   const glyphs=SupportGlyphs.layout(data,markerR);
   for(let dof=1;dof<=6;dof++){
    const records=glyphs.records.filter(record=>record.dof===dof);if(!records.length)continue;
    const build=builder(parts,"SPC DOF "+dof,records[0].color,{entity_type:"SPC",components:String(dof),shape:records[0].shape,axis:records[0].axis});
    for(const record of records){const origin=point(xyz,record.node);build.entity(ids[record.node],SupportGlyphs.triangles(record,origin,markerR),{grid_id:ids[record.node],dof,center_offset_m:record.centerOffset,...(dof<=3?{apex_m:origin,points_along:"+"+record.axis}:{})});await tick();}build.finish();
   }
  }
  if(snapshot.reactions&&shown("SUPPORT_FORCES")){
   const reactions=snapshot.reactions,supports=new Set(data.spc?.nodes?i32(data.spc.nodes):[]),records=[];let peak=0,momentPeak=0;
   for(let i=0;i<reactions.nodes.length;i++){const node=reactions.nodes[i];if(!supports.has(node))continue;const force=Array.from(reactions.forces.subarray(3*i,3*i+3)),moment=reactions.moments?Array.from(reactions.moments.subarray(3*i,3*i+3)):[0,0,0];records.push({node,force,moment});peak=Math.max(peak,Math.hypot(...force));momentPeak=Math.max(momentPeak,...moment.map(Math.abs));}
   for(const kind of ["force","moment"]){
    const builds=LoadGlyphs.AXES.map((axis,k)=>builder(parts,"SUPPORT_"+(kind==="force"?"FORCES_":"MOMENTS_")+axis,LoadGlyphs.COLORS[k],{entity_type:"support_reaction",kind,axis,case_id:snapshot.activeCase,analysis:snapshot.analysis}));
    for(const record of records){for(const glyph of LoadGlyphs.components(record[kind],{kind,diag,scale:peak>0?.09*diag*(snapshot.supportForceMultiplier||1)/peak:0,peak:momentPeak,multiplier:snapshot.supportForceMultiplier||1}))builds[glyph.component].entity(ids[record.node],loadGlyphTriangles(point(xyz,record.node),glyph,r),{force_N:record.force,moment_Nm:record.moment,...loadGlyphMetadata(glyph)});await tick();}builds.forEach(build=>build.finish());
   }
  }
  for(const [name,attachments]of[["RBE3",data.rbe3],["FUEL_RBE3",data.fuel_rbe3]])if(shown(name)&&attachments?.elements){
   const lookup=new Map(Array.from(ids,(id,n)=>[id,n])),build=builder(parts,name,colors[name],{entity_type:"RBE3"});
   for(const sp of attachments.elements){const coords=[];for(const gid of sp.connected_grids){const n=lookup.get(gid);if(n!==undefined)coords.push(...cylinder(point(xyz,sp.ref),point(xyz,n),r));}build.entity(sp.eid,coords,{...sp});await tick();}build.finish();
  }
  async function surface(name,surface,stride,color,extra,positions){
   if(!surface?.count||!shown(name))return;const coords=positions||f32(surface.xyz),conn=i32(surface.conn),build=builder(parts,name,color,extra);
   for(let e=0;e<surface.count;e++){build.entity(e+1,triangles(coords,conn.subarray(stride*e,stride*(e+1))));await tick();}build.finish();
  }
  await surface("AERO_SURFACE",data.aero,4,[...rgba(colors.AERO_SURFACE).slice(0,3),.12],{entity_type:"aerodynamic_loft"},options.displayed?snapshot.aeroPositions:null);
  if(data.fuel?.surface){const s=data.fuel.surface;await surface("FUEL_TANK",{...s,count:i32(s.conn).length/3},3,[...rgba(colors.FUEL_TANK).slice(0,3),.42],{entity_type:"fuel_envelope",state:"undeformed",volume_m3:data.fuel.volume_m3});}
  let peakPanelForce=0;for(const c of cases){const forces=c.loads?.vlm?.forces?f32(c.loads.vlm.forces):null;if(forces)for(let i=0;i<forces.length;i+=3)peakPanelForce=Math.max(peakPanelForce,Math.hypot(...forces.subarray(i,i+3)));}
  for(const loadCase of cases){
   if(visible&&Number(loadCase.id)!==Number(snapshot.activeCase))continue;
   const loads=loadCase.loads;if(!loads)continue;const label="CASE "+loadCase.id+" ",caseMeta={case_id:loadCase.id,case_label:loadCase.label};
   if(loads.vlm&&(!visible||shown("VLM_MESH")||shown("VLM_PRESSURE"))){
    const v=loads.vlm,conn=i32(v.conn),positions=f32(v.xyz),build=builder(parts,label+"VLM",[...rgba(colors.VLM).slice(0,3),.6],{...caseMeta,entity_type:"vortex_lattice",pressure_Pa:v.pressure?Array.from(f32(v.pressure)):undefined,Cp:v.cp?Array.from(f32(v.cp)):undefined});
    for(let e=0;e<v.count;e++){build.entity(e+1,triangles(positions,conn.subarray(4*e,4*e+4)));await tick();}build.finish();
   }
   if(loads.vlm?.forces&&loads.vlm.centers&&shown("VLM_FORCES")){
    const forces=f32(loads.vlm.forces),centers=f32(loads.vlm.centers),scale=peakPanelForce>0?.1*diag*(snapshot.vlmForceMultiplier||1)/peakPanelForce:0;
    const builds=LoadGlyphs.AXES.map((axis,k)=>builder(parts,label+"VLM_FORCES_"+axis,LoadGlyphs.COLORS[k],{...caseMeta,entity_type:"panel_force",axis,arrow_scale_m_per_N:scale}));
    for(let e=0;e<loads.vlm.count;e++){const force=point(forces,e);for(const glyph of LoadGlyphs.components(force,{diag,scale}))builds[glyph.component].entity(e+1,loadGlyphTriangles(point(centers,e),glyph,r),{force_N:force,...loadGlyphMetadata(glyph)});await tick();}builds.forEach(build=>build.finish());
   }
   const displayedLoads=options.displayed&&Number(loadCase.id)===Number(snapshot.activeCase)&&Array.isArray(snapshot.appliedLoadStations);
   const stations=displayedLoads?snapshot.appliedLoadStations:loadStations(loads);let peak=0,momentPeak=0;for(const station of stations){peak=Math.max(peak,Math.hypot(...station.force));momentPeak=Math.max(momentPeak,...(station.moment||[0,0,0]).map(Math.abs));}
   for(const [layer,type]of[["AERO_LOADS","force"],["AERO_MOMENTS","moment"]]){
    if(!shown(layer))continue;
    const builds=LoadGlyphs.AXES.map((axis,k)=>builder(parts,label+layer+"_"+axis,LoadGlyphs.COLORS[k],{...caseMeta,entity_type:"applied_"+type,axis,glyph_radius_m:r,load_basis:displayedLoads?"selected displayed result":"prescribed undeformed loads",moment_routing_note:loads.moment_routing_note}));
    for(const station of stations){const origin=point(xyz,station.node_index),vector=station[type]||[0,0,0];for(const glyph of LoadGlyphs.components(vector,{kind:type,diag,scale:peak>0?.09*diag/peak:0,peak:momentPeak}))builds[glyph.component].entity(station.gid,loadGlyphTriangles(origin,glyph,r),{vector,unit:type==="force"?"N":"N m",source:station.source,target_kind:station.target_kind,target_rbe3_eid:station.target_rbe3_eid,massless:station.massless,source_forces_N:type==="force"?station.source_forces_N:undefined,fuel_bay:station.fuel_bay,application_point_m:origin,routed_moment:station.routed_moment===true,source_moments_Nm:type==="moment"?station.source_moments_Nm:undefined,follower_forces:type==="moment"?false:station.follower_forces,...loadGlyphMetadata(glyph)});await tick();}builds.forEach(build=>build.finish());
   }
  }
  if(options.references!==false)for(const ref of snapshot.references||[]){if(visible&&!ref.visible)continue;const build=builder(parts,"REFERENCE "+ref.name,ref.color||"#b8c7d4",{entity_type:"imported_reference",source_name:ref.name});for(const mesh of ref.meshes){for(let start=0;start<mesh.positions.length;start+=589824){build.entity(mesh.name,mesh.positions.subarray(start,start+589824));progress(.65,"Triangulating imported references");await pause();}}build.finish();}
  if(!parts.length)throw Error("No geometry matches these export options.");
  progress(.7,"Geometry ready");return{parts,metadata:{generator:"WingFEGen",title:data.title||"Wing model",units:"m",coordinates:"FE global XYZ: x aft, y span, z up",scope:visible?"visible entities / selected case":"all generated entities / all cases",state:options.displayed?"displayed deformation":"undeformed",deformation:options.displayed?snapshot.deformation:undefined,line_radius_m:r,markers:"nodes: octahedra; supports: axis-colored translation cones with apex at the node pointing along +global axis; rotation box outlines offset by half the marker radius",shells:"zero-thickness triangulated midsurfaces",fuel_masses:fuelMasses,fuel_mass_geometry:"CONM2 is a point mass: native per-case properties are metadata; markers locate reference GRIDs without implying a mass shape.",references:options.references!==false,excluded:"Camera helpers, labels, selection halos, duplicate wireframes and comparison ghosts"}};
 }
 function normal(p,k){const n=unit(cross([p[k+3]-p[k],p[k+4]-p[k+1],p[k+5]-p[k+2]],[p[k+6]-p[k],p[k+7]-p[k+1],p[k+8]-p[k+2]]));return n.some(v=>v!==0)?n:[0,0,1];}
 async function stl(geometry,progress=()=>{}){
  const count=geometry.parts.reduce((n,p)=>n+p.positions.length/9,0);if(count>0xffffffff)throw Error("STL triangle count exceeds the format limit.");
  const header=new Uint8Array(84);header.set(new TextEncoder().encode("WingFEGen binary STL; FE XYZ; metres; "+geometry.metadata.state).subarray(0,80));new DataView(header.buffer).setUint32(80,count,true);
  const buffers=[header];let done=0;
  for(const part of geometry.parts){const p=part.positions,buffer=new ArrayBuffer(p.length/9*50),view=new DataView(buffer);for(let k=0;k<p.length;k+=9){const offset=k/9*50,n=normal(p,k);for(let c=0;c<3;c++)view.setFloat32(offset+4*c,n[c],true);for(let c=0;c<9;c++)view.setFloat32(offset+12+4*c,p[k+c],true);if(k%36864===0){progress(.7+.29*(done+k/9)/count,"Writing binary STL");await pause();}}buffers.push(buffer);done+=p.length/9;}
  return new Blob(buffers,{type:"model/stl"});
 }
 async function glb(geometry,progress=()=>{}){
  const json={asset:{version:"2.0",generator:"WingFEGen",extras:geometry.metadata},scene:0,scenes:[{nodes:[0]}],
   nodes:[{name:geometry.metadata.title,children:[],matrix:[1,0,0,0,0,0,-1,0,0,1,0,0,0,0,0,1],extras:{source_coordinates:"FE XYZ, metres; root rotation maps to standard glTF Y up"}}],meshes:[],materials:[],accessors:[],bufferViews:[],buffers:[{byteLength:0}]};
  const buffers=[],materials=new Map();let bytes=0,done=0;const count=geometry.parts.reduce((n,p)=>n+p.positions.length,0);
  function accessor(array,min,max){const view=json.bufferViews.length;json.bufferViews.push({buffer:0,byteOffset:bytes,byteLength:array.byteLength,target:34962});buffers.push(array);bytes+=array.byteLength;const a=json.accessors.length;json.accessors.push({bufferView:view,componentType:5126,count:array.length/3,type:"VEC3",...(min?{min,max}:{})});return a;}
  function indices(count){const array=Uint32Array.from({length:count},(_,i)=>i),view=json.bufferViews.length;json.bufferViews.push({buffer:0,byteOffset:bytes,byteLength:array.byteLength,target:34963});buffers.push(array);bytes+=array.byteLength;const a=json.accessors.length;json.accessors.push({bufferView:view,componentType:5125,count,type:"SCALAR",min:[0],max:[count-1]});return a;}
  for(const part of geometry.parts){
   const p=part.positions,normals=new Float32Array(p.length),min=[Infinity,Infinity,Infinity],max=[-Infinity,-Infinity,-Infinity];
   for(let k=0;k<p.length;k+=9){const n=normal(p,k);for(let j=0;j<9;j++){normals[k+j]=n[j%3];min[j%3]=Math.min(min[j%3],p[k+j]);max[j%3]=Math.max(max[j%3],p[k+j]);}if(k%36864===0){progress(.7+.27*(done+k)/count,"Writing GLB geometry");await pause();}}
   const key=part.color.join(",");if(!materials.has(key)){materials.set(key,json.materials.length);json.materials.push({name:part.name,pbrMetallicRoughness:{baseColorFactor:part.color,metallicFactor:0,roughnessFactor:.75},doubleSided:true,...(part.color[3]<1?{alphaMode:"BLEND"}:{})});}
   const position=accessor(p,min,max),normalAccessor=accessor(normals),mesh=json.meshes.length;
   json.meshes.push({name:part.name,primitives:[{attributes:{POSITION:position,NORMAL:normalAccessor},indices:indices(p.length/3),material:materials.get(key),mode:4}],extras:part.extras});
   json.nodes[0].children.push(json.nodes.length);json.nodes.push({name:part.name,mesh});done+=p.length;
  }
  json.buffers[0].byteLength=bytes;const encoded=new TextEncoder().encode(JSON.stringify(json)),jsonLength=(encoded.length+3)&~3,total=12+8+jsonLength+8+bytes;
  if(total>0xffffffff)throw Error("GLB exceeds the 4 GB format limit.");
  const header=new Uint8Array(20),view=new DataView(header.buffer);view.setUint32(0,0x46546c67,true);view.setUint32(4,2,true);view.setUint32(8,total,true);view.setUint32(12,jsonLength,true);view.setUint32(16,0x4e4f534a,true);
  const text=new Uint8Array(jsonLength).fill(32);text.set(encoded);const binaryHeader=new Uint8Array(8),binaryView=new DataView(binaryHeader.buffer);binaryView.setUint32(0,bytes,true);binaryView.setUint32(4,0x004e4942,true);
  progress(.99,"Preparing download");return new Blob([header,text,binaryHeader,...buffers],{type:"model/gltf-binary"});
 }
 async function referenceSnapshot(entries,visibleOnly=false,progress=()=>{}){
  const sources=(entries||[]).filter(entry=>!visibleOnly||entry.visible).map(entry=>({
   name:entry.name,visible:entry.visible,color:[...(entry.material?.diffuseColor?.asArray()||[.72,.78,.83]),entry.opacity??.45],
   meshes:entry.meshes.filter(mesh=>mesh.getVerticesData("position")&&mesh.getIndices()?.length).map(mesh=>{
    mesh.computeWorldMatrix(true);const matrix=mesh.getWorldMatrix().clone();
    return{name:mesh.name,positions:mesh.getVerticesData("position").slice(),indices:mesh.getIndices().slice(),matrix:Array.from(matrix.m),mirror:matrix.determinant()<0};
   })
  }));
  const result=[];for(const source of sources){const meshes=[];for(const mesh of source.meshes){
   const p=mesh.positions,index=mesh.indices,m=mesh.matrix,out=new Float32Array(index.length*3);
   for(let n=0;n<index.length;n++){const k=mesh.mirror?n-n%3+[0,2,1][n%3]:n,i=3*index[k],x=p[i],y=p[i+1],z=p[i+2];
    const view=[m[0]*x+m[4]*y+m[8]*z+m[12],m[1]*x+m[5]*y+m[9]*z+m[13],m[2]*x+m[6]*y+m[10]*z+m[14]];
    out.set([view[2],view[0],view[1]],3*n);
    if(n%12288===0){progress(0,"Copying imported reference geometry");await pause();}
   }meshes.push({name:mesh.name,positions:out});
  }result.push({...source,meshes});}return result;
 }
 return{collect,stl,glb,cylinder,marker,referenceSnapshot,loadStations,loadsByNode};
});
