/* Authored loft display, independent of FE nodes, properties and results. */
(function(root,factory){const api=factory(root);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingGeometryPreview=api;})(globalThis,function(root){
 'use strict';
 const key=k=>/^(planform|airfoil|loft|movable_surfaces)\./.test(k);
 const select=p=>Object.fromEntries(Object.entries(p||{}).filter(([k])=>key(k)));
 const signature=p=>{const canonical=v=>Array.isArray(v)?v.map(canonical):v&&typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])])):v;return JSON.stringify(canonical(select(p)));};
 const neutral=surface=>Math.abs(Math.sin(Number(surface.definition?.deflection||0)*Math.PI/360))<1e-10;
 function create({state,read,request,onStatus=()=>{},onFirst=()=>{},restore=()=>{}}){
  let timer=null,revision=0,epoch=0,cache=null,stamp='',mesh=null,node=null,movables=null,sections=[],controlGuides=[],active=false,disposed=false,observer=null,everShown=false;
  let desired=null,pending=null,inFlight=false,lastStarted=null,appliedRevision=0;
  const now=()=>root.performance?.now?.()??Date.now(),minimumRequestInterval=100;
  const typed=(v,T)=>v instanceof T?v:ArrayBuffer.isView(v)?new T(v.buffer.slice(v.byteOffset,v.byteOffset+v.byteLength)):new T(v),floats=v=>typed(v,Float32Array),ints=v=>typed(v,Int32Array);
  function clearMeshes(){movables?.dispose();movables=null;for(const item of [...sections,...controlGuides])item.dispose(false,true);sections=[];controlGuides=[];if(node)node.dispose(false,true);mesh=node=null;active=false;restore();}
  function reset(){++revision;++epoch;clearTimeout(timer);timer=null;desired=pending=null;cache=null;stamp='';everShown=false;lastStarted=null;appliedRevision=revision;clearMeshes();onStatus('');}
  function sync(){
   if(!active||!node)return;if(state.importedDeck||state.diskResults){clearMeshes();onStatus('');return;}const shown=true;node.setEnabled(shown);
   if(shown)for(const name of ['AERO_SURFACE','AIRFOIL_SECTIONS'])for(const m of state.layers.get(name)?.meshes||[])m.setEnabled(false);
   for(const s of sections)s.setEnabled(shown&&!!state.layers.get('AIRFOIL_SECTIONS')?.visible);
   // The form already owns movable previews when there is a generated root.
   movables?.setVisible(shown&&!state.data);
   for(const guide of controlGuides)guide.setEnabled(shown&&!state.data);
  }
  function display(){
   if(!cache||!state.scene||state.importedDeck||state.diskResults){clearMeshes();return;}
   if(state.data?.model_params&&(state.geometryModelSignature||signature(state.data.model_params))===stamp){clearMeshes();onStatus('Geometry current');return;}
   clearMeshes();const B=root.BABYLON,scene=state.scene,xyz=floats(cache.aero.xyz),conn=ints(cache.aero.conn),positions=new Float32Array(xyz.length),indices=[];
   for(let i=0;i<xyz.length;i+=3){positions[i]=xyz[i+1];positions[i+1]=xyz[i+2];positions[i+2]=xyz[i];}
   for(let i=0;i<conn.length;i+=4)indices.push(conn[i],conn[i+1],conn[i+2],conn[i],conn[i+2],conn[i+3]);
   node=new B.TransformNode('live-geometry-root',scene);mesh=new B.Mesh('live-geometry-loft',scene);mesh.parent=node;const data=new B.VertexData();data.positions=positions;data.indices=indices;const normals=[];B.VertexData.ComputeNormals(positions,indices,normals,{useRightHandedSystem:!!scene.useRightHandedSystem});data.normals=normals;data.applyToMesh(mesh);
   mesh.sideOrientation=scene.useRightHandedSystem?B.Material.CounterClockWiseSideOrientation:B.Material.ClockWiseSideOrientation;
   const material=new B.StandardMaterial('live-geometry-material',scene);material.diffuseColor=B.Color3.FromHexString('#64c8df');material.emissiveColor=new B.Color3(.035,.1,.12);
   // Before a FEM exists this closed loft is the model itself. An alpha-blended
   // mesh interleaves upper/lower triangles in draw order, making bands near
   // the thin trailing edge. Use ordinary opaque depth testing for that view;
   // translucency is only needed to see a retained FEM beneath edited geometry.
   material.alpha=state.data?.22:1;material.transparencyMode=state.data?B.Material.MATERIAL_ALPHABLEND:B.Material.MATERIAL_OPAQUE;
   material.backFaceCulling=false;material.twoSidedLighting=true;material.separateCullingPass=!!state.data&&!state.transparency?.enabled;material.disableDepthWrite=false;mesh.material=material;mesh.isPickable=false;mesh.metadata={wingViewHelper:true,geometryPreview:true};
   for(const section of cache.aero.sections||[]){const points=floats(section.xyz),line=B.MeshBuilder.CreateLines('live-airfoil-'+section.eta,{points:Array.from({length:points.length/3},(_,i)=>new B.Vector3(points[3*i+1],points[3*i+2],points[3*i]))},scene);line.parent=node;line.color=B.Color3.FromHexString('#d5ebfb');line.isPickable=false;sections.push(line);}
   // A neutral control occupies the same loft, sampled on a different grid.
   // Overlaying its filled triangles creates alternating intersections. Mark
   // its neutral footprint/hinge as a colored guide instead. These explicit
   // construction lines remain readable on the closed opaque body; deflected
   // surfaces keep normal depth testing and their real translucent geometry.
   const surfaces=cache.movables?.surfaces||[];
   if(!state.data)for(const surface of surfaces.filter(neutral)){
    const outline=surface.outline||[];if(outline.length<2)continue;
    const map=p=>new B.Vector3(p[1],p[2],p[0]),lines=[[...outline,outline[0]].map(map)];
    if(surface.hinge?.length>1)lines.push(surface.hinge.map(map));
    const guide=B.MeshBuilder.CreateLineSystem('live-control-guide-'+surface.definition.name,{lines},scene);
    guide.parent=node;guide.color=B.Color3.FromHexString(surface.definition.color||'#29b6d1');guide.isPickable=false;guide.renderingGroupId=2;
    guide.material.depthFunction=B.Constants.ALWAYS;guide.material.disableDepthWrite=true;
    guide.metadata={wingViewHelper:true,geometryPreview:true,neutralControlGuide:true,controlName:surface.definition.name};controlGuides.push(guide);
   }
   movables=root.WingMovableSurfaces?.createDisplay({BABYLON:B,scene,parent:node,data:{...cache.movables,surfaces:surfaces.filter(surface=>!neutral(surface))},visible:!state.data,hingesVisible:true,style:'translucent'});
   active=true;if(!observer)observer=scene.onBeforeRenderObservable.add(sync);sync();onStatus(state.data?'Geometry current - FEM unchanged':'Geometry current · no FEM generated');if(!everShown&&!state.data){everShown=true;onFirst();}
  }
  function pump(){
   clearTimeout(timer);timer=null;if(disposed||inFlight||!pending)return;
   const wait=Math.max(0,pending.due-now(),lastStarted===null?0:minimumRequestInterval-(now()-lastStarted));
   if(wait>0){timer=setTimeout(pump,wait);return;}
   const target=pending,generation=epoch;pending=null;inFlight=true;lastStarted=now();
   Promise.resolve().then(()=>request(target.parameters)).then(data=>{
    if(disposed||generation!==epoch||!desired||target.revision<appliedRevision)return;
    // Show valid intermediate geometry during a continuous drag, then service
    // only its newest pending draft. A returned old Study can never replace it.
    cache=data;stamp=target.signature;appliedRevision=target.revision;display();
    if(desired.signature!==stamp)onStatus('Updating geometry…');
   }).catch(error=>{if(!disposed&&generation===epoch&&desired?.signature===target.signature&&target.revision>=appliedRevision)onStatus('Geometry preview retained · '+error.message);})
    .finally(()=>{inFlight=false;pump();});
  }
  function schedule(delay=180){
   clearTimeout(timer);timer=null;const sequence=++revision;if(disposed)return;
   let params;try{params=read();if(!params){reset();return;}}catch(error){desired=pending=null;onStatus('Geometry waiting for valid input: '+error.message);return;}
   const next=signature(params);desired={signature:next,revision:sequence};
   if(next===stamp&&cache){pending=null;appliedRevision=sequence;displayIfNeeded();onStatus(state.data?'Geometry current - FEM unchanged':'Geometry current · no FEM generated');return;}
   pending={signature:next,revision:sequence,parameters:JSON.parse(JSON.stringify(select(params))),due:now()+Math.max(0,delay)};
   onStatus('Updating geometry…');pump();
  }
  function displayIfNeeded(){if(state.importedDeck||state.diskResults){clearMeshes();return;}const matches=state.data?.model_params&&(state.geometryModelSignature||signature(state.data.model_params))===stamp;if(matches&&active){clearMeshes();onStatus('Geometry current');}else if(!matches&&!active)display();}
  return{request:schedule,reset,reconcile(){displayIfNeeded();schedule();},get active(){return active;},get bbox(){return active&&!state.importedDeck&&!state.diskResults?cache?.bbox:null;},get signature(){return stamp;},get data(){return cache;},destroy(){disposed=true;reset();if(observer)state.scene?.onBeforeRenderObservable.remove(observer);}};
 }
 return{key,select,signature,create};
});
