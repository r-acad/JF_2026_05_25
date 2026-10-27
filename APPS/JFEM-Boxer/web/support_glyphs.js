/* Per-DOF SPC markers. FE XYZ is mapped to viewport YZX at the boundary only.
 * Six geometry batches at most; deformation and size updates reuse all buffers.
 */
(function(root,factory){
  const api=factory();
  if(typeof module==="object"&&module.exports)module.exports=api;else root.WingSupportGlyphs=api;
})(typeof globalThis!=="undefined"?globalThis:this,function(){
  "use strict";
  const AXES=["x","y","z"],COLORS=["#df3248","#079548","#2454e8"],VIEW_AXIS=[2,0,1],templates=new Map();
  const toView=p=>[p[1],p[2],p[0]];
  // A closed shaft, shoulder and conical head for a signed reaction force.
  // Coordinates remain local FE XYZ; the application maps them at its boundary.
  function forceArrow(glyph,{diameter=0,diag=1,sides=16}={}){
    if(glyph?.kind!=="force"||!Number.isFinite(diameter)||diameter<0||!Number.isFinite(diag)||diag<=0||!Number.isInteger(sides)||sides<8||sides>64)throw Error("Invalid solid reaction-arrow dimensions.");
    const tip=glyph.vertices?.[1],length=tip?.length===3?Math.hypot(...tip):0;if(!(length>0)||!tip.every(Number.isFinite))throw Error("A solid reaction arrow requires a finite nonzero force vector.");
    const axis=tip.map(v=>v/length),cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]],normalize=v=>{const n=Math.hypot(...v);return v.map(x=>x/n);};
    const u=normalize(cross(axis,Math.abs(axis[2])<.9?[0,0,1]:[0,1,0])),v=cross(axis,u),stem=diameter>0?diameter:Math.min(.0015*diag,.08*length),radius=stem/2;
    const headLength=Math.min(.35*length,Math.max(3*stem,.014*diag)),neck=length-headLength,headRadius=1.8*radius,positions=[];
    const ring=(z,r,t)=>axis.map((n,j)=>n*z+r*(u[j]*Math.cos(t)+v[j]*Math.sin(t))),triangle=(a,b,c)=>positions.push(...a,...b,...c),origin=[0,0,0];
    for(let i=0;i<sides;i++){
      const t=2*Math.PI*i/sides,next=2*Math.PI*((i+1)%sides)/sides,a=ring(0,radius,t),b=ring(0,radius,next),c=ring(neck,radius,t),d=ring(neck,radius,next),e=ring(neck,headRadius,t),f=ring(neck,headRadius,next);
      triangle(tip,e,f); // Vertex 0 is the exact signed tip, used by labels.
      triangle(a,b,d);triangle(a,d,c);triangle(origin,b,a);
      triangle(c,d,f);triangle(c,f,e);
    }
    return{positions:Float32Array.from(positions),indices:Uint32Array.from({length:positions.length/3},(_,i)=>i),labelVertex:0,stemDiameter:stem,length};
  }
  function radiusValue(value){if(typeof value!=="number"||!Number.isFinite(value)||value<0)throw Error("Constraint marker radius must be a finite non-negative number.");return value;}
  function integers(value){
    if(value==null)return[];
    if(Array.isArray(value)||value instanceof Int32Array)return value;
    if(value instanceof ArrayBuffer)return new Int32Array(value.slice(0));
    if(ArrayBuffer.isView(value)&&value.BYTES_PER_ELEMENT===1){if(value.byteLength%4)throw Error("Invalid constraint index buffer.");return new Int32Array(value.buffer.slice(value.byteOffset,value.byteOffset+value.byteLength));}
    if(ArrayBuffer.isView(value))return Array.from(value);
    throw Error("Invalid constraint index list.");
  }
  function components(value){return Array.from(new Set(String(value??"").split("").filter(c=>/^[1-6]$/.test(c)))).sort();}
  const basicAxes=[[1,0,0],[0,1,0],[0,0,1]];
  const transformed=(axes,vector,component)=>vector.reduce((sum,value,k)=>sum+value*axes[k][component],0);
  function frameAxes(value){
    if(value==null)return basicAxes;
    if(!Array.isArray(value)||value.length!==3||value.some(axis=>!Array.isArray(axis)||axis.length!==3||!axis.every(Number.isFinite)))throw Error('Invalid GRID displacement axes for constraint display.');
    return value;
  }
  function layout(data,radius=.01){
    radius=radiusValue(radius);
    const spc=data?.spc||{},ids=integers(data?.nodes?.ids),listed=integers(spc.nodes),assignments=new Map(),frames=new Map(),unresolved=new Set(),perNode=new Map(),records=[];
    const count=data?.nodes?.count??ids.length;
    for(const row of spc.assignments||[]){if(Number.isInteger(row?.node)){const existing=assignments.get(row.node)||[];assignments.set(row.node,[...existing,...components(row.components)]);if(row.axes===null&&Number(row.coordinate_id)!==0)unresolved.add(row.node);else frames.set(row.node,frameAxes(row.axes));}}
    const candidates=listed.length?Array.from(listed):Array.from(assignments.keys());
    for(let i=0;i<candidates.length;i++){
      const node=candidates[i];if(!Number.isInteger(node)||node<0||(count>0&&node>=count)||unresolved.has(node))continue;
      // New payloads carry exact per-node masks. Assignment metadata is the
      // next fallback; old payloads use one common mask for every root node.
      const mask=spc.node_components?.[i]??(assignments.has(node)?assignments.get(node).join(""):spc.components??"123");
      const previous=perNode.get(node)||new Set();for(const dof of components(mask))previous.add(Number(dof));perNode.set(node,previous);
    }
    const byDof={1:0,2:0,3:0,4:0,5:0,6:0},nodes=[];
    for(const [node,dofs]of perNode){if(!dofs.size)continue;nodes.push(node);for(const dof of [...dofs].sort()){
      const axis=(dof-1)%3,axes=frames.get(node)||basicAxes,centerOffset=axes[axis].map(value=>value*(dof<=3?-1:.5)*radius);byDof[dof]++;
      records.push({node,grid:ids[node]??null,dof,type:dof<=3?"translation":"rotation",shape:dof<=3?"cone":"box-outline",axis:AXES[axis],color:COLORS[axis],centerOffset,axes});
    }}
    return{nodes,records,counts:{byDof,translations:byDof[1]+byDof[2]+byDof[3],rotations:byDof[4]+byDof[5]+byDof[6],total:records.length,nodes:nodes.length}};
  }
  function template(shape){
    if(templates.has(shape))return templates.get(shape);
    const positions=[],normals=[],indices=[];
    if(shape==="cone"){
      // Canonical +Z cone: apex at the node, base 2r behind it. Rotating this
      // template into each global axis never translates the supported node.
      const sides=16;
      function face(a,b,c){const u=b.map((x,i)=>x-a[i]),v=c.map((x,i)=>x-a[i]),normal=[u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]],length=Math.hypot(...normal),start=positions.length/3;for(const point of[a,b,c]){positions.push(...point);normals.push(...normal.map(x=>x/length));}indices.push(start,start+1,start+2);}
      for(let side=0;side<sides;side++){const angle=2*Math.PI*side/sides,next=2*Math.PI*(side+1)/sides,a=[Math.cos(angle),Math.sin(angle),-2],b=[Math.cos(next),Math.sin(next),-2];face([0,0,0],a,b);face([0,0,-2],b,a);}
    }else if(shape==="box-outline"){
      // Twelve solid edge rods form a cube with outer side 2r. Its open faces
      // keep the corresponding translational cone and node apex visible.
      function box(center,half){
        for(let axis=0;axis<3;axis++)for(const sign of[-1,1]){
          const u=(axis+1)%3,v=(axis+2)%3,start=positions.length/3,n=[0,0,0];n[axis]=sign;
          for(const [su,sv]of[[-1,-1],[1,-1],[1,1],[-1,1]]){const p=center.slice();p[axis]+=sign*half[axis];p[u]+=su*half[u];p[v]+=sv*half[v];positions.push(...p);normals.push(...n);}
          if(sign>0)indices.push(start,start+1,start+2,start,start+2,start+3);else indices.push(start,start+2,start+1,start,start+3,start+2);
        }
      }
      const thickness=.07;
      for(let axis=0;axis<3;axis++)for(const a of[-1,1])for(const b of[-1,1]){const center=[0,0,0],half=[thickness,thickness,thickness];half[axis]=1;center[(axis+1)%3]=a*(1-thickness);center[(axis+2)%3]=b*(1-thickness);box(center,half);}
    }else throw Error("Unknown constraint marker shape.");
    const result={positions:Float32Array.from(positions),normals:Float32Array.from(normals),indices:Uint32Array.from(indices)};templates.set(shape,result);return result;
  }
  const unitAxis=(shape,axis,component)=>shape==="cone"?(component-axis+2)%3:component;
  const localCoordinate=(unit,shape,axis,vertex,component)=>unit.positions[3*vertex+unitAxis(shape,axis,component)]+(shape==="cone"?0:component===axis?.5:0);
  function triangles(record,origin,radius=.01){
    radius=radiusValue(radius);if(!origin||origin.length!==3||!Array.from(origin).every(Number.isFinite))throw Error("Constraint marker origin must contain three finite coordinates.");
    const shape=record.shape||(+record.dof<=3?"cone":"box-outline"),unit=template(shape),axis=(+record.dof-1)%3,out=new Float32Array(unit.indices.length*3);
    const axes=frameAxes(record.axes);
    for(let i=0;i<unit.indices.length;i++){const local=[0,1,2].map(j=>localCoordinate(unit,shape,axis,unit.indices[i],j));for(let j=0;j<3;j++)out[3*i+j]=origin[j]+radius*transformed(axes,local,j);}
    return out;
  }
  function glowController({BABYLON:B=globalThis.BABYLON,scene,meshes,name='SPC'}){
    const included=new Set(meshes);let glow=null,disposed=false;
    function setEnabled(enabled){
      if(disposed)return;
      if(enabled&&!glow&&meshes.length){
        glow=new B.GlowLayer(name+'-constraint-glow',scene,{mainTextureRatio:.5,blurKernelSize:24});glow.intensity=.65;
        // Keep non-emitting geometry in the depth pass: an included-only list
        // would make the halo shine through opaque skins and reference meshes.
        glow.customEmissiveColorSelector=(mesh,subMesh,material,result)=>{
          if(!included.has(mesh)){result.set(0,0,0,1);return;}
          const color=mesh.metadata?.color?B.Color3.FromHexString(mesh.metadata.color):material.diffuseColor||material.emissiveColor||B.Color3.White();
          result.set(color.r,color.g,color.b,1);
        };
      }
      if(glow)glow.isEnabled=!!enabled;
    }
    function dispose(){if(disposed)return;disposed=true;glow?.dispose();glow=null;included.clear();}
    return{setEnabled,dispose,get glow(){return glow;}};
  }
  function create({BABYLON:B=globalThis.BABYLON,scene,data,positions,radius=.01,name="SPC"}){
    radius=radiusValue(radius);if(!positions||positions.length%3)throw Error("Constraint marker positions require viewport YZX triples.");
    const current=layout(data,radius),meshes=[],batches=[];let disposed=false,currentPositions=positions,currentRadius=radius;
    for(let dof=1;dof<=6;dof++){
      const records=current.records.filter(record=>record.dof===dof);if(!records.length)continue;
      const unit=template(records[0].shape),n=unit.positions.length/3,map=new Int32Array(n*records.length),local=new Float32Array(n*records.length*3),buf=new Float32Array(local.length),normals=new Float32Array(local.length),indices=new Uint32Array(unit.indices.length*records.length);
      const axis=(dof-1)%3;
      for(let k=0;k<records.length;k++){
        map.fill(records[k].node,k*n,(k+1)*n);
        for(let i=0;i<n;i++){
          const v=[0,1,2].map(j=>localCoordinate(unit,records[0].shape,axis,i,j)),normal=[0,1,2].map(j=>unit.normals[3*i+unitAxis(records[0].shape,axis,j)]);
          for(let j=0;j<3;j++){const viewAxis=VIEW_AXIS[j],offset=3*(k*n+i)+viewAxis;local[offset]=transformed(records[k].axes,v,j);normals[offset]=transformed(records[k].axes,normal,j);}
        }
        for(let i=0;i<unit.indices.length;i++)indices[k*unit.indices.length+i]=k*n+unit.indices[i];
      }
      const mesh=new B.Mesh(name+"-DOF"+dof,scene),material=new B.StandardMaterial(name+"-DOF"+dof+"-material",scene);
      material.diffuseColor=B.Color3.FromHexString(COLORS[axis]);material.emissiveColor=material.diffuseColor.scale(.12);material.specularColor=B.Color3.Black();material.maxSimultaneousLights=6;material.alpha=1;material.backFaceCulling=false;material.transparencyMode=B.Material.MATERIAL_OPAQUE;material.depthFunction=scene.getEngine().useReverseDepthBuffer?B.Constants.GEQUAL:B.Constants.LEQUAL;material.disableDepthWrite=false;
      mesh.material=material;mesh.isPickable=false;mesh.renderingGroupId=2;
      mesh.metadata={supportGlyphs:true,component:"SPC",dof,axis:AXES[axis],shape:records[0].shape,color:COLORS[axis],records};
      const vertexData=new B.VertexData();vertexData.positions=buf;vertexData.normals=normals;vertexData.indices=indices;vertexData.applyToMesh(mesh,true);
      meshes.push(mesh);batches.push({mesh,material,map,local,buf});
    }
    function update(options={}){
      if(disposed)throw Error("Constraint glyph renderer has been disposed.");
      const nextPositions=options.positions??currentPositions,nextRadius=radiusValue(options.radius??currentRadius);
      if(!nextPositions||nextPositions.length%3)throw Error("Constraint marker positions require viewport YZX triples.");
      for(const node of current.nodes)if(3*node+2>=nextPositions.length||![nextPositions[3*node],nextPositions[3*node+1],nextPositions[3*node+2]].every(Number.isFinite))throw Error("A constrained node has invalid viewport coordinates.");
      currentPositions=nextPositions;currentRadius=nextRadius;
      for(const record of current.records)record.centerOffset=record.axes[(record.dof-1)%3].map(value=>value*(record.dof<=3?-1:.5)*nextRadius);
      for(const batch of batches){for(let i=0;i<batch.map.length;i++)for(let j=0;j<3;j++)batch.buf[3*i+j]=nextPositions[3*batch.map[i]+j]+nextRadius*batch.local[3*i+j];batch.mesh.updateVerticesData(B.VertexBuffer.PositionKind,batch.buf,true,false);}
      return current;
    }
    const highlight=glowController({BABYLON:B,scene,meshes,name});
    function setGlow(enabled){highlight.setEnabled(enabled);}
    function dispose(){if(disposed)return;disposed=true;highlight.dispose();for(const batch of batches){if(!batch.mesh.isDisposed())batch.mesh.dispose();batch.material.dispose();}meshes.length=0;batches.length=0;}
    try{update();}catch(error){dispose();throw error;}
    return{meshes,nodes:current.nodes,records:current.records,counts:current.counts,update,setGlow,dispose,get glow(){return highlight.glow;},get radius(){return currentRadius;}};
  }
  return{AXES,COLORS,toView,layout,triangles,forceArrow,create,glowController};
});
