/* FE Utils overlays use native model XYZ coordinates; they never edit the FEM. */
(function(root){
  'use strict';
  function create({BABYLON:B,scene,read}){
    let owned=[],picked=[],partCache=null,selectionCache=null,selectionGlow=null,last=null,nodeLookup=null;
    const stats={updates:0,identicalReuses:0,partBuilds:0,partReuses:0,selectionBuilds:0,selectionReuses:0};
    const dispose=items=>{for(const m of items)m.dispose(false,true);};
    const clear=()=>{selectionGlow?.dispose();selectionGlow=null;dispose(owned);dispose(picked);owned=[];picked=[];partCache=null;selectionCache=null;last=null;nodeLookup=null;};
    const digest=ids=>{let hash=2166136261;for(const id of ids||[])hash=Math.imul(hash^Number(id),16777619);return (ids?.length||0)+':'+(hash>>>0);};
    const vector=p=>new B.Vector3(Number(p[1]),Number(p[2]),Number(p[0]));
    const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
    const unit=a=>{const n=Math.hypot(...a);return a.map(x=>x/n);};
    function keep(m,collection=owned){m.isPickable=false;m.metadata={wingViewHelper:true,feEditOverlay:true};collection.push(m);return m;}
    function lines(name,paths,color,{foreground=false,collection=owned}={}){if(!paths.length)return;const m=keep(B.MeshBuilder.CreateLineSystem(name,{lines:paths},scene),collection);m.color=B.Color3.FromHexString(color);m.renderingGroupId=2;if(foreground){m.material.depthFunction=B.Constants.ALWAYS;m.material.disableDepthWrite=true;}return m;}
    function plane(p,index){
      const n=unit(p.normal),axis=[0,0,0];axis[n.map(Math.abs).indexOf(Math.min(...n.map(Math.abs)))]=1;
      const u=unit(cross(n,axis)),v=cross(n,u),h=p.side_length/2;
      const corners=[[-1,-1],[1,-1],[1,1],[-1,1]].map(([a,b])=>p.point.map((x,i)=>x+h*(a*u[i]+b*v[i])));
      const points=corners.map(vector);lines('fe-cut-plane-'+index,[[...points,points[0]],[vector(p.point),vector(p.point.map((x,i)=>x+n[i]*h*.4))]],index?'#ffb43b':'#00dce8');
      const mesh=keep(new B.Mesh('fe-cut-plane-fill-'+index,scene)),vd=new B.VertexData();vd.positions=points.flatMap(p=>[p.x,p.y,p.z]);vd.indices=[0,1,2,0,2,3];vd.normals=[];B.VertexData.ComputeNormals(vd.positions,vd.indices,vd.normals);vd.applyToMesh(mesh);
      const material=new B.StandardMaterial('fe-cut-plane-material-'+index,scene);material.diffuseColor=B.Color3.FromHexString(index?'#ffb43b':'#00dce8');material.emissiveColor=material.diffuseColor.scale(.4);material.alpha=.13;material.transparencyMode=B.Material.MATERIAL_ALPHABLEND;material.backFaceCulling=false;material.disableDepthWrite=true;mesh.material=material;
    }
    function show(spec){
      if(!spec||spec.clear){clear();return;}
      const state=read();
      const positions=state.baseline,partsKey=spec.show_parts?(spec.parts||[]).map(p=>p.id+':'+digest(p.element_ids)).join('|'):'',selectedIds=spec.selected_element_ids||spec.element_ids||[],selectionKey=digest(selectedIds);
      const planeKey=JSON.stringify([spec.show_plane,spec.plane,spec.second_plane]),groupsKey=(spec.candidate_groups||[]).map(group=>digest(group.nodes)+':'+group.retained_node).join('|')+';ambiguous='+digest(spec.ambiguous_node_ids);
      if(last&&last.positions===positions&&last.partsKey===partsKey&&last.selectionKey===selectionKey&&last.planeKey===planeKey&&last.groupsKey===groupsKey&&last.cut===spec.cut_segments&&last.secondCut===spec.second_cut_segments){stats.identicalReuses++;return;}
      stats.updates++;
      const keepParts=!!partCache&&partCache.positions===positions&&partCache.key===partsKey,keepSelection=!!selectionCache&&selectionCache.positions===positions&&selectionCache.key===selectionKey;
      const retained=new Set([...(keepParts?partCache.meshes:[]),...(keepSelection?selectionCache.meshes:[])]);
      if(!keepSelection){selectionGlow?.dispose();selectionGlow=null;selectionCache=null;}
      for(const mesh of owned)if(!retained.has(mesh))mesh.dispose(false,true);
      owned=[...retained];if(!keepParts)partCache=null;
      last={positions,partsKey,selectionKey,planeKey,groupsKey,cut:spec.cut_segments,secondCut:spec.second_cut_segments};
      if(spec.show_plane!==false&&spec.plane?.side_length>0&&spec.plane.normal?.some(x=>x!==0)){plane(spec.plane,0);if(spec.second_plane)plane(spec.second_plane,1);}
      const segments=value=>(value||[]).filter(s=>s?.length===2&&s.every(p=>p?.length===3&&p.every(Number.isFinite))).map(s=>s.map(vector));
      if(!positions)return;
      const point=i=>new B.Vector3(positions[3*i],positions[3*i+1],positions[3*i+2]);
      if(keepParts&&partsKey)stats.partReuses++;
      if(!keepParts&&spec.show_parts&&spec.parts?.length){
        const firstOwned=owned.length;stats.partBuilds++;
        const colors=['#20cddd','#f37db9','#b4db39','#ffb04b','#ac9bff'];
        for(const [index,part]of spec.parts.entries()){
          const paths=[],vertices=[],indices=[],color=colors[index%colors.length];
          for(const id of part.element_ids||[]){
            const e=state.elements.get(Number(id));if(!e)continue;const nodes=Array.from(e.nodes),ps=nodes.map(point);
            if(nodes.length>1)paths.push(nodes.length>2?[...ps,ps[0]]:ps);
            if(['tria','quad'].includes(e.group?.kind)){
              const start=vertices.length/3;vertices.push(...ps.flatMap(p=>[p.x,p.y,p.z]));indices.push(start,start+1,start+2);if(nodes.length===4)indices.push(start,start+2,start+3);
            }
          }
          lines('fe-part-edges-'+part.id,paths,color,{foreground:true});
          if(vertices.length){
            const mesh=keep(new B.Mesh('fe-part-fill-'+part.id,scene)),data=new B.VertexData();data.positions=vertices;data.indices=indices;data.normals=[];B.VertexData.ComputeNormals(vertices,indices,data.normals);data.applyToMesh(mesh);
            const material=new B.StandardMaterial('fe-part-material-'+part.id,scene);material.diffuseColor=B.Color3.FromHexString(color);material.emissiveColor=material.diffuseColor.scale(.6);material.alpha=.24;material.backFaceCulling=false;material.disableDepthWrite=true;material.zOffset=-2;mesh.material=material;
          }
        }
        partCache={positions,key:partsKey,meshes:owned.slice(firstOwned)};
      }
      if(keepSelection&&selectedIds.length)stats.selectionReuses++;
      if(!keepSelection&&selectedIds.length){
        const firstOwned=owned.length,paths=[],vertices=[],indices=[];stats.selectionBuilds++;
        for(const id of selectedIds){const e=state.elements.get(Number(id));if(!e)continue;const nodes=Array.from(e.nodes);if(nodes.length<2)continue;const ps=nodes.map(point);paths.push(nodes.length>2?[...ps,ps[0]]:ps);if(['quad','tria'].includes(e.group?.kind)){const offset=vertices.length/3;for(const p of ps)vertices.push(p.x,p.y,p.z);indices.push(offset,offset+1,offset+2);if(nodes.length===4)indices.push(offset,offset+2,offset+3);}}
        lines('fe-selected-elements',paths,'#ffe034',{foreground:true});
        if(vertices.length){const mesh=keep(new B.Mesh('fe-selected-part-fill',scene)),data=new B.VertexData();data.positions=vertices;data.indices=indices;data.normals=[];B.VertexData.ComputeNormals(vertices,indices,data.normals);data.applyToMesh(mesh);const material=new B.StandardMaterial('fe-selected-part-material',scene);material.diffuseColor=B.Color3.FromHexString('#ffc632');material.emissiveColor=B.Color3.FromHexString('#ffb51e').scale(.2);material.alpha=.2;material.backFaceCulling=false;material.disableDepthWrite=true;material.zOffset=-3;mesh.material=material;}
        selectionCache={positions,key:selectionKey,meshes:owned.slice(firstOwned)};
        if(typeof B.GlowLayer==='function'&&selectionCache.meshes.length){selectionGlow=new B.GlowLayer('fe-part-selection-glow',scene,{mainTextureRatio:.35,blurKernelSize:16});selectionGlow.intensity=.55;selectionGlow.customEmissiveColorSelector=(mesh,_submesh,_material,result)=>mesh.name==='fe-selected-part-fill'?result.set(.25,.08,.005,.3):result.set(.9,.4,.01,1);for(const mesh of selectionCache.meshes)selectionGlow.addIncludedOnlyMesh(mesh);}
      }
      let nodeIndex=null;
      if(spec.candidate_groups?.length||spec.ambiguous_node_ids?.length){if(!nodeLookup||nodeLookup.positions!==positions||nodeLookup.ids!==state.nodeIds)nodeLookup={positions,ids:state.nodeIds,map:new Map(Array.from(state.nodeIds||[],(id,i)=>[Number(id),i]))};nodeIndex=nodeLookup.map;}
      const radius=Math.max((state.diag||1)*.004,1e-8);let dots=0;
      for(const group of spec.candidate_groups||[]){const selected=[],ids=[group.retained_node,...(group.nodes||[]).filter(id=>Number(id)!==Number(group.retained_node))];for(const id of ids){const i=nodeIndex.get(Number(id));if(i===undefined)continue;const p=point(i);selected.push(p);if(dots++>=2000)continue;const retained=Number(id)===Number(group.retained_node),m=keep(B.MeshBuilder.CreateSphere('fe-equivalence-node-'+id,{diameter:radius*(retained?2.6:1.5),segments:12},scene));m.position=p;m.renderingGroupId=3;const mat=new B.StandardMaterial('fe-equivalence-color-'+id,scene);mat.emissiveColor=B.Color3.FromHexString(retained?'#00e6b8':'#ff6c37');mat.disableLighting=true;mat.depthFunction=B.Constants.ALWAYS;mat.disableDepthWrite=true;m.material=mat;}
        if(selected.length>1)lines('fe-equivalence-group',[selected],'#ff6c37');}
      for(const id of spec.ambiguous_node_ids||[]){const i=nodeIndex?.get(Number(id));if(i===undefined||dots++>=2000)continue;const mesh=keep(B.MeshBuilder.CreateSphere('fe-ambiguous-node-'+id,{diameter:radius*3,segments:12},scene));mesh.position=point(i);mesh.renderingGroupId=3;const material=new B.StandardMaterial('fe-ambiguous-node-color-'+id,scene);material.emissiveColor=B.Color3.FromHexString('#f255d6');material.disableLighting=true;material.depthFunction=B.Constants.ALWAYS;material.disableDepthWrite=true;mesh.material=material;}
      // The cut contour must remain visible over the coincident part edges.
      const cut=lines('fe-cut-intersection',segments(spec.cut_segments),'#ffdb30',{foreground:true});if(cut)cut.renderingGroupId=3;
      const secondCut=lines('fe-cut-intersection-second',segments(spec.second_cut_segments),'#ff64bc',{foreground:true});if(secondCut)secondCut.renderingGroupId=3;
    }
    function showPickedNodes(nodes){
      dispose(picked);picked=[];const state=read(),diameter=Math.max((state.diag||1)*.008,1e-8);
      const points=[];
      for(const [i,node]of nodes.entries()){
        const p=vector(node.xyz);points.push(p);
        const m=keep(B.MeshBuilder.CreateSphere('fe-picked-grid-'+node.id,{diameter,segments:12},scene),picked);m.position=p;m.renderingGroupId=2;
        const material=new B.StandardMaterial('fe-picked-grid-material-'+node.id,scene);material.emissiveColor=B.Color3.FromHexString(i?'#ff9e39':'#3ce0ff');material.diffuseColor=material.emissiveColor;material.alpha=.4;material.disableDepthWrite=true;m.material=material;
      }
      if(points.length===2)lines('fe-picked-translation-vector',[points],'#ffdb30',{foreground:true,collection:picked});
    }
    return {show,showPickedNodes,clear,dispose:clear,stats:()=>({...stats,overlayMeshes:owned.length,pickedMeshes:picked.length,glowingMeshes:selectionCache?.meshes.length||0})};
  }
  root.WingFEEditViewport={create};
})(globalThis);
