(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingMovableSurfaces=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 const KEY='movable_surfaces.items',MAX_SURFACES=100;
 const KINDS=['aileron','flap','slat','elevator','rudder','tab','other'];
 const FIELDS=['name','kind','edge','eta_start','eta_end','hinge_start','hinge_end','deflection','color'];
 const HELP=[
  'Define each movable surface on the generated lifting-surface loft. Eta is the fraction of semi-span: 0 is the root and 1 is the tip. Start eta must be smaller than End eta. Several adjacent surfaces can share an endpoint; their footprints must not overlap.',
  'A trailing-edge surface extends from its hinge to x/c = 1; a leading-edge surface extends from x/c = 0 to its hinge. Hinge x/c is measured from the local refined leading edge and interpolates linearly between the two span limits. For example, hinge x/c = 0.75 leaves a trailing-edge surface occupying the aft 25% of chord.',
  'The straight 3D hinge axis joins the inboard and outboard hinge points on the loft midcamber. The preview rigidly rotates the trimmed upper and lower loft about that axis. Positive deflection is a right-handed rotation from the inboard toward the outboard hinge point: on a horizontal surface, a positive angle lowers the trailing edge and raises the leading edge. Twist or a curved loft can leave a gap along an intermediate cut; this preview does not design seals or hinge fittings.',
  'The plan drawing shows the neutral footprint, with dashed hinge cuts. The colored 3D preview shows the specified deflection in the undeformed geometry. Definitions, colors and angles are saved in the Study and TOML. Add optional shells, ribs and attachments in Structure / Movable surfaces to include a surface in the FE model. Surfaces without enabled structures remain geometry previews. VLM still uses the original common aerodynamic loft.'
 ];
 function normalize(value){
  if(!Array.isArray(value)||value.length>MAX_SURFACES)throw Error('Use a table of at most '+MAX_SURFACES+' movable surfaces.');
  const names=new Set(),rows=value.map((r,i)=>{
   if(!r||typeof r!=='object'||Array.isArray(r)||Object.keys(r).sort().join('|')!==[...FIELDS].sort().join('|'))throw Error('Movable surface '+(i+1)+' has missing or unknown fields.');
   const name=typeof r.name==='string'?r.name.trim():'';
   if(!name||[...name].length>80||/[\x00-\x1f\x7f-\x9f]/.test(name))throw Error('Each surface needs a name of 1 to 80 characters without control characters.');
   if(names.has(name.toLowerCase()))throw Error('Movable surface names must be unique: '+name);names.add(name.toLowerCase());
   if(!KINDS.includes(r.kind))throw Error(name+': choose a surface type.');
   if(!['leading','trailing'].includes(r.edge))throw Error(name+': choose a leading or trailing edge.');
   for(const k of ['eta_start','eta_end','hinge_start','hinge_end','deflection'])if(typeof r[k]!=='number'||!Number.isFinite(r[k]))throw Error(name+': '+k+' must be a finite number.');
   if(!(r.eta_start>=0&&r.eta_end<=1&&r.eta_end-r.eta_start>=1e-6))throw Error(name+': require 0 ≤ Start eta < End eta ≤ 1, separated by at least 0.000001.');
   if(!(r.hinge_start>0&&r.hinge_start<1&&r.hinge_end>0&&r.hinge_end<1))throw Error(name+': hinge x/c must be strictly between 0 and 1.');
   if(Math.abs(r.deflection)>90)throw Error(name+': deflection must be between −90 and 90 degrees.');
   if(typeof r.color!=='string'||!/^#[0-9a-f]{6}$/i.test(r.color))throw Error(name+': choose a six-digit hex color.');
   return {...r,name,color:r.color.toLowerCase()};
  });
  const hinge=(s,eta)=>s.hinge_start+(s.hinge_end-s.hinge_start)*(eta-s.eta_start)/(s.eta_end-s.eta_start);
  for(let i=0;i<rows.length;i++)for(let j=i+1;j<rows.length;j++){
   const a=rows[i],b=rows[j],lo=Math.max(a.eta_start,b.eta_start),hi=Math.min(a.eta_end,b.eta_end);if(hi<=lo)continue;
   if(a.edge===b.edge)throw Error(a.name+' and '+b.name+' overlap on the same edge.');
   const [front,rear]=a.edge==='leading'?[a,b]:[b,a];
   if([lo,hi].some(eta=>hinge(front,eta)>=hinge(rear,eta)))throw Error(a.name+' and '+b.name+' have overlapping chordwise footprints.');
  }
  return rows;
 }
 function nextSurface(rows){
  let name='Surface 1',serial=1;while(rows.some(r=>r.name.trim().toLowerCase()===name.toLowerCase()))name='Surface '+(++serial);
  let edge='trailing',a=.2,b=.7;
  if(rows.length){let found=false;for(const choice of ['trailing','leading']){let cursor=0;for(const s of [...rows.filter(r=>r.edge===choice),{eta_start:1,eta_end:1}].sort((a,b)=>a.eta_start-b.eta_start)){if(s.eta_start-cursor>=.01){edge=choice;a=cursor;b=s.eta_start;found=true;break;}cursor=Math.max(cursor,s.eta_end);}if(found)break;}if(!found)return null;}
  return{name,kind:edge==='leading'?'slat':'flap',edge,eta_start:a,eta_end:b,hinge_start:edge==='leading'?.15:.75,hinge_end:edge==='leading'?.15:.75,deflection:0,color:['#29b6d1','#f5a742','#b388ff','#ee72ac'][rows.length%4]};
 }
 function createDisplay({BABYLON:B,scene,parent,data,visible=true}){
  const meshes=[],vector=p=>new B.Vector3(p[1],p[2],p[0]);
  for(const s of data?.surfaces||[]){
   const positions=[];for(let i=0;i<s.xyz.length;i+=3)positions.push(s.xyz[i+1],s.xyz[i+2],s.xyz[i]);
   const mesh=new B.Mesh('movable-surface-'+s.definition.name,scene),vd=new B.VertexData();vd.positions=positions;vd.indices=s.triangles;vd.normals=[];B.VertexData.ComputeNormals(positions,vd.indices,vd.normals);vd.applyToMesh(mesh);
   const mat=new B.StandardMaterial(mesh.name+'-material',scene),color=B.Color3.FromHexString(s.definition.color);mat.diffuseColor=color.scale(.96);mat.emissiveColor=color.scale(.045);mat.specularColor=new B.Color3(.065,.065,.065);mat.specularPower=48;mat.maxSimultaneousLights=6;mat.backFaceCulling=false;mat.twoSidedLighting=true;mat.zOffset=-2;mesh.material=mat;
   const hinge=B.MeshBuilder.CreateLines(mesh.name+'-hinge',{points:s.hinge.map(vector)},scene);hinge.color=new B.Color3(.14,.18,.24);hinge.renderingGroupId=1;
   meshes.push(mesh,hinge);
  }
  for(const mesh of meshes){mesh.parent=parent;mesh.isPickable=false;mesh.metadata={wingViewHelper:true,movableSurfacePreview:true};mesh.setEnabled(visible);}
  return{meshes,setVisible(v){for(const m of meshes)m.setEnabled(v);},dispose(){for(const m of meshes)m.dispose(false,true);}};
 }
 function install(host,{onEdit,onHelp,readValues,requestPreview,onPreview,isLocked=()=>false}={}){
  const doc=host.ownerDocument,stored=doc.getElementById('p-'+KEY);if(!stored)return null;
  const make=(tag,cls,text)=>{const e=doc.createElement(tag);if(cls)e.className=cls;if(text!==undefined)e.textContent=text;return e;};
  const intro=make('p','group-note','Define leading- and trailing-edge movable surfaces. Add their optional load-carrying shells and hinge attachments in Structure / Movable surfaces. VLM retains the original common loft.');
  const help=make('button','mini','?');help.type='button';help.title='Span, hinge interpolation, deflection sign, preview and analysis scope';help.setAttribute('aria-label','Help: movable surfaces');help.onclick=()=>onHelp?.({title:'Movable surfaces',paragraphs:HELP});intro.append(' ',help);
  const preview=make('div','movable-preview'),toolbar=make('div','movable-actions'),showLabel=make('label','layer'),show=make('input'),svg=doc.createElementNS('http://www.w3.org/2000/svg','svg');show.type='checkbox';show.checked=show.defaultChecked=true;show.id='show-movable-preview';show.dataset.parameterLockExempt='true';showLabel.append(show,make('span','','Preview in 3D · undeformed geometry'));toolbar.append(showLabel);svg.id='movable-plan-view';svg.setAttribute('viewBox','0 0 900 430');svg.setAttribute('aria-label','Movable surfaces neutral plan view');svg.setAttribute('role','img');preview.append(toolbar,svg);
  const status=make('p','pick-note'),error=make('p','loft-error'),list=make('div','movable-list'),actions=make('div','movable-actions'),add=make('button','mini primary','+ Add movable surface');add.type='button';add.id='movable-add';error.setAttribute('role','alert');error.hidden=true;status.id='movable-status';status.setAttribute('role','status');actions.append(add);host.append(intro,preview,status,error,list,actions);
  const viewport=globalThis.WingSVGViewport?.install(svg,{key:'movable-surfaces-plan',host:preview,toolbarHost:toolbar,exportName:'movable-surfaces.svg'});
  let rows=[],timer=null,revision=0,destroyed=false,cache=null,parseError='',requestKey=null;
  function draft(){return rows.map(({inputs})=>Object.fromEntries(FIELDS.map(k=>[k,['eta_start','eta_end','hinge_start','hinge_end','deflection'].includes(k)?inputs[k].value.trim()===''?null:Number(inputs[k].value):inputs[k].value])));}
  function validate(){let message=parseError;try{if(!message)normalize(draft());}catch(e){message=e.message;}host.dataset.invalidMessage=message;error.textContent=message;error.hidden=!message;return message;}
  function draw(data){
   svg.replaceChildren();if(!data?.outline?.length){viewport?.refresh();return;}const pts=data.outline,xs=pts.map(p=>p[1]),ys=pts.map(p=>p[0]),xmin=Math.min(...xs),ymin=Math.min(...ys),w=Math.max(...xs)-xmin,h=Math.max(...ys)-ymin,scale=Math.min(800/(w||1),325/(h||1));
   const map=p=>[50+(p[1]-xmin)*scale,45+(p[0]-ymin)*scale];
   const node=(tag,attrs,text)=>{const e=doc.createElementNS(svg.namespaceURI,tag);for(const[k,v]of Object.entries(attrs))e.setAttribute(k,v);if(text!==undefined)e.textContent=text;svg.append(e);return e;};
   node('polygon',{points:pts.map(p=>map(p).join(',')).join(' '),fill:'#e5edf4',stroke:'#637b90','stroke-width':1.7});
   for(const s of data.surfaces){node('polygon',{points:s.outline.map(p=>map(p).join(',')).join(' '),fill:s.definition.color,'fill-opacity':.6,stroke:s.definition.color,'stroke-width':2});node('polyline',{points:s.hinge_curve.map(p=>map(p).join(',')).join(' '),fill:'none',stroke:'#263e50','stroke-width':2,'stroke-dasharray':'7 4'});const mid=map(s.hinge_curve[Math.floor(s.hinge_curve.length/2)]);node('text',{x:mid[0],y:mid[1]-9,fill:'#132e44','font-size':15,'text-anchor':'middle','paint-order':'stroke',stroke:'#fff','stroke-width':4,'stroke-linejoin':'round'},s.definition.name);}
   node('text',{x:50,y:410,fill:'#304a60','font-size':14},'Neutral footprints · dashed hinge cuts · span → · x aft ↓');
   viewport?.setMetric({origin:{x:50-xmin*scale,y:45-ymin*scale},x:{x:scale,y:0},y:{x:0,y:scale},unit:'m',horizontalLabel:'Δy',verticalLabel:'Δx',gridSpacing:1});viewport?.refresh();
  }
  function controls(){const locked=isLocked();for(const row of rows){for(const input of Object.values(row.inputs))input.disabled=locked;row.remove.disabled=locked;}add.disabled=locked||rows.length>=MAX_SURFACES;}
  function clearPreview(){cache=null;requestKey=null;draw(null);onPreview?.(null,false);}
  async function updatePreview(){
   clearTimeout(timer);const id=++revision;if(destroyed)return;
   if(validate()){clearPreview();status.textContent='Correct the definition to preview the movable surfaces.';return;}
   if(!rows.length){clearPreview();status.textContent='No movable surfaces defined. Add a surface to set its span, hinge and deflection.';return;}
   let params;try{params={...readValues(),[KEY]:normalize(draft())};}catch(e){clearPreview();status.textContent=e.message;return;}
   const key=JSON.stringify(params);if(key===requestKey&&cache){onPreview?.(cache,show.checked);return;}
   // Clear old geometry immediately: an invalid or pending edit must never show
   // a previous surface as if it represented the current definition.
   clearPreview();status.textContent='Preparing movable-surface geometry…';
   try{const data=await requestPreview(params);if(destroyed||id!==revision)return;cache=data;requestKey=key;draw(data);onPreview?.(data,show.checked);status.textContent=rows.length+' movable surface'+(rows.length===1?'':'s')+' · plan shows neutral footprints; 3D shows preview deflection. Geometry preview only; enabled structures are controlled in Structure → Movable surfaces.';}
   catch(e){if(destroyed||id!==revision)return;clearPreview();status.textContent='Geometry preview failed: '+e.message;}
  }
  function refresh(){if(destroyed)return;controls();clearTimeout(timer);++revision;timer=setTimeout(updatePreview,250);}
  function sync(){parseError='';stored.value=JSON.stringify(draft());validate();clearPreview();refresh();onEdit?.(KEY);}
  function addRow(value){
   const box=make('fieldset','movable-surface'),legend=make('legend','',value.name),grid=make('div','movable-grid'),inputs={};
   const specs=[['name','Name','text','Unique surface name, saved with this definition.'],['kind','Type',KINDS,'Descriptive type. It does not choose an analysis boundary condition.'],['edge','Edge',['trailing','leading'],'Trailing: hinge to trailing edge. Leading: leading edge to hinge.'],['eta_start','Start eta','number','Inboard fraction of semi-span: 0 = root, 1 = tip.'],['eta_end','End eta','number','Outboard fraction of semi-span; greater than Start eta.'],['hinge_start','Inboard hinge x/c','number','Hinge position from the refined local leading edge, divided by local chord.'],['hinge_end','Outboard hinge x/c','number','Hinge x/c at End eta. Interpolates linearly from the inboard value.'],['deflection','Preview deflection (deg)','number',HELP[2]],['color','Color','color','Color of the neutral footprint and deflected 3D preview.']];
   for(const[k,label,kind,title]of specs){const wrap=make('label','',label),input=make(Array.isArray(kind)?'select':'input');if(Array.isArray(kind))for(const v of kind){const o=make('option','',v[0].toUpperCase()+v.slice(1));o.value=v;input.append(o);}else input.type=kind;input.value=value[k]??'';input.title=title;input.setAttribute('aria-label',label);input.dataset.movableField=k;if(kind==='number'){input.step=k==='deflection'?'1':'0.1';input.min=k==='deflection'?'-90':'0';input.max=k==='deflection'?'90':'1';}if(k==='name')input.maxLength=80;wrap.append(input);grid.append(wrap);inputs[k]=input;input.addEventListener('input',()=>{if(!isLocked()){legend.textContent=inputs.name.value||'Unnamed surface';sync();}});}
   const remove=make('button','mini ghost','Remove surface');remove.type='button';remove.onclick=()=>{if(isLocked())return;rows=rows.filter(r=>r.box!==box);box.remove();sync();};box.append(legend,grid,remove);list.append(box);rows.push({box,inputs,remove});
  }
  add.onclick=()=>{if(isLocked()||validate())return;const next=nextSurface(normalize(draft()));if(!next){error.textContent='Both edges are fully occupied. Shorten or remove a surface before adding another.';error.hidden=false;return;}addRow(next);sync();rows.at(-1).inputs.name.focus();};
  show.onchange=()=>onPreview?.(cache,show.checked);
  const lockChange=()=>controls();host.addEventListener('parameterlockchange',lockChange);
  try{const initial=normalize(JSON.parse(stored.value||'[]'));for(const row of initial)addRow(row);}catch(e){parseError='Cannot read saved movable surfaces: '+e.message;}
  validate();refresh();
  return{readDrafts:()=>({[KEY]:draft()}),assertValidDraft(){const message=validate();if(message)throw Error(message);},refresh,redraw3D(){onPreview?.(cache,show.checked);},destroy(){destroyed=true;++revision;clearTimeout(timer);viewport?.destroy();host.removeEventListener('parameterlockchange',lockChange);onPreview?.(null,false);}};
 }
 return{KEY,KINDS,FIELDS,MAX_SURFACES,HELP,normalize,nextSurface,createDisplay,install};
});
