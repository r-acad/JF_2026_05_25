/* Authored loft display, independent of FE nodes, properties and results. */
(function(root,factory){const api=factory(root);if(typeof module==='object'&&module.exports)module.exports=api;else root.WingGeometryPreview=api;})(globalThis,function(root){
 'use strict';
 const key=k=>/^(planform|airfoil|loft|movable_surfaces)\./.test(k);
 const select=p=>Object.fromEntries(Object.entries(p||{}).filter(([k])=>key(k)));
 const signature=p=>{const canonical=v=>Array.isArray(v)?v.map(canonical):v&&typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])])):v;return JSON.stringify(canonical(select(p)));};
 function create({state,read,request,onStatus=()=>{},onFirst=()=>{},restore=()=>{}}){
  let timer=null,revision=0,cache=null,stamp='',mesh=null,node=null,movables=null,sections=[],active=false,disposed=false,observer=null,everShown=false;
  const typed=(v,T)=>v instanceof T?v:ArrayBuffer.isView(v)?new T(v.buffer.slice(v.byteOffset,v.byteOffset+v.byteLength)):new T(v),floats=v=>typed(v,Float32Array),ints=v=>typed(v,Int32Array);
  function clearMeshes(){movables?.dispose();movables=null;for(const item of sections)item.dispose();sections=[];if(node)node.dispose(false,true);mesh=node=null;active=false;restore();}
  function reset(){++revision;clearTimeout(timer);timer=null;cache=null;stamp='';everShown=false;clearMeshes();onStatus('');}
  function sync(){
   if(!active||!node)return;if(state.importedDeck||state.diskResults){clearMeshes();onStatus('');return;}const shown=true;node.setEnabled(shown);
   if(shown)for(const name of ['AERO_SURFACE','AIRFOIL_SECTIONS'])for(const m of state.layers.get(name)?.meshes||[])m.setEnabled(false);
   for(const s of sections)s.setEnabled(shown&&!!state.layers.get('AIRFOIL_SECTIONS')?.visible);
   // The form already owns movable previews when there is a generated root.
   movables?.setVisible(shown&&!state.data);
  }
  function display(){
   if(!cache||!state.scene||state.importedDeck||state.diskResults){clearMeshes();return;}
   if(state.data?.model_params&&(state.geometryModelSignature||signature(state.data.model_params))===stamp){clearMeshes();onStatus('Geometry current');return;}
   clearMeshes();const B=root.BABYLON,scene=state.scene,xyz=floats(cache.aero.xyz),conn=ints(cache.aero.conn),positions=new Float32Array(xyz.length),indices=[];
   for(let i=0;i<xyz.length;i+=3){positions[i]=xyz[i+1];positions[i+1]=xyz[i+2];positions[i+2]=xyz[i];}
   for(let i=0;i<conn.length;i+=4)indices.push(conn[i],conn[i+1],conn[i+2],conn[i],conn[i+2],conn[i+3]);
   node=new B.TransformNode('live-geometry-root',scene);mesh=new B.Mesh('live-geometry-loft',scene);mesh.parent=node;const data=new B.VertexData();data.positions=positions;data.indices=indices;const normals=[];B.VertexData.ComputeNormals(positions,indices,normals);data.normals=normals;data.applyToMesh(mesh);
   const material=new B.StandardMaterial('live-geometry-material',scene);material.diffuseColor=B.Color3.FromHexString('#64c8df');material.emissiveColor=new B.Color3(.035,.1,.12);material.alpha=state.data?.22:.72;material.backFaceCulling=false;material.twoSidedLighting=true;mesh.material=material;mesh.isPickable=false;mesh.metadata={wingViewHelper:true,geometryPreview:true};
   for(const section of cache.aero.sections||[]){const points=floats(section.xyz),line=B.MeshBuilder.CreateLines('live-airfoil-'+section.eta,{points:Array.from({length:points.length/3},(_,i)=>new B.Vector3(points[3*i+1],points[3*i+2],points[3*i]))},scene);line.parent=node;line.color=B.Color3.FromHexString('#d5ebfb');line.isPickable=false;sections.push(line);}
   movables=root.WingMovableSurfaces?.createDisplay({BABYLON:B,scene,parent:node,data:cache.movables,visible:!state.data,hingesVisible:true,style:'translucent'});
   active=true;if(!observer)observer=scene.onBeforeRenderObservable.add(sync);sync();onStatus(state.data?'Geometry current - FEM unchanged':'Geometry current · no FEM generated');if(!everShown&&!state.data){everShown=true;onFirst();}
  }
  function schedule(delay=180){
   clearTimeout(timer);const epoch=++revision;if(disposed)return;
   let params;try{params=read();if(!params){reset();return;}}catch(error){onStatus('Geometry waiting for valid input: '+error.message);return;}
   const next=signature(params);if(next===stamp&&cache){displayIfNeeded();return;}
   onStatus('Updating geometry…');timer=setTimeout(async()=>{timer=null;try{const data=await request(select(params));if(disposed||epoch!==revision)return;cache=data;stamp=next;display();}catch(error){if(epoch===revision)onStatus('Geometry preview retained · '+error.message);}},delay);
  }
  function displayIfNeeded(){if(state.importedDeck||state.diskResults){clearMeshes();return;}const matches=state.data?.model_params&&(state.geometryModelSignature||signature(state.data.model_params))===stamp;if(matches&&active){clearMeshes();onStatus('Geometry current');}else if(!matches&&!active)display();}
  return{request:schedule,reset,reconcile(){displayIfNeeded();schedule();},get active(){return active;},get bbox(){return active&&!state.importedDeck&&!state.diskResults?cache?.bbox:null;},get signature(){return stamp;},get data(){return cache;},destroy(){disposed=true;reset();if(observer)state.scene?.onBeforeRenderObservable.remove(observer);}};
 }
 return{key,select,signature,create};
});
